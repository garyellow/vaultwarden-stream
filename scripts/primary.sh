#!/bin/sh
set -eu

. /app/sync.sh
. /app/backup.sh

SYNC_PID=""
BACKUP_PID=""
LITESTREAM_PID=""

cleanup() {
  echo "[primary] shutdown signal received, cleaning up..." >&2

  # Stop sync loop
  if [ -n "$SYNC_PID" ] && kill -0 "$SYNC_PID" 2>/dev/null; then
    kill "$SYNC_PID" 2>/dev/null || true
    wait "$SYNC_PID" 2>/dev/null || true
  fi

  # Wait for current backup to complete (with 60 second timeout)
  # This prevents incomplete backup archives from being uploaded to S3
  if [ -n "$BACKUP_PID" ] && kill -0 "$BACKUP_PID" 2>/dev/null; then
    echo "[primary] waiting for backup to complete (timeout 60s)..." >&2
    timeout=60
    while [ $timeout -gt 0 ] && kill -0 "$BACKUP_PID" 2>/dev/null; do
      sleep 1
      timeout=$((timeout - 1))
    done
    if kill -0 "$BACKUP_PID" 2>/dev/null; then
      echo "[primary] WARNING: backup timeout, forcing shutdown" >&2
      kill "$BACKUP_PID" 2>/dev/null || true
    fi
    wait "$BACKUP_PID" 2>/dev/null || true
  fi

  # Stop Litestream
  if [ -n "$LITESTREAM_PID" ] && kill -0 "$LITESTREAM_PID" 2>/dev/null; then
    kill "$LITESTREAM_PID" 2>/dev/null || true
    wait "$LITESTREAM_PID" 2>/dev/null || true
  fi

  echo "[primary] performing final upload before exit..." >&2
  sync_attachments_upload || echo "[primary] WARNING: final upload failed" >&2
  write_sync_status "shutdown"
  exit 0
}

trap cleanup TERM INT

mkdir -p /data/attachments /data/sends

# Restore from S3
echo "[primary] cleaning local database files..." >&2
rm -f "$LITESTREAM_DB_PATH" "$LITESTREAM_DB_PATH-shm" "$LITESTREAM_DB_PATH-wal"
rm -rf "$LITESTREAM_DB_PATH-litestream"

echo "[primary] restoring database from S3..." >&2
if ! litestream restore -if-replica-exists -config /etc/litestream.yml "$LITESTREAM_DB_PATH"; then
  echo "[primary] ERROR: database restore failed (check S3 connectivity)" >&2
  exit 1
fi

echo "[primary] downloading attachments and keys from S3..." >&2
if ! sync_attachments_download; then
  echo "[primary] ERROR: initial download failed (check S3 connectivity)" >&2
  exit 1
fi
write_sync_status "ok"

# Start background upload loop
(
  while true; do
    sleep "$PRIMARY_SYNC_INTERVAL"
    if sync_attachments_upload; then
      write_sync_status "ok"
    else
      write_sync_status "error"
      echo "[primary] WARNING: periodic upload failed" >&2
    fi
  done
) &
SYNC_PID=$!

# Start background backup loop (if enabled)
if [ "${BACKUP_ENABLED:-false}" = "true" ]; then
  echo "[primary] backup enabled (interval=${BACKUP_INTERVAL:-86400}s, retention=${BACKUP_RETENTION_DAYS:-30}d, min_keep=${BACKUP_MIN_KEEP:-3})" >&2
  [ -n "${BACKUP_EXTRA_REMOTES:-}" ] && echo "[primary] extra backup remotes: ${BACKUP_EXTRA_REMOTES}" >&2
  (
    # Run first backup immediately on startup, then continue with periodic schedule
    if create_backup; then
      echo "[primary] initial backup completed" >&2
    else
      echo "[primary] WARNING: initial backup failed" >&2
    fi
    while true; do
      sleep "${BACKUP_INTERVAL:-86400}"
      if create_backup; then
        echo "[primary] backup completed" >&2
      else
        echo "[primary] WARNING: backup failed" >&2
      fi
    done
  ) &
  BACKUP_PID=$!
fi

# Launch Vaultwarden
echo "[primary] starting vaultwarden..." >&2
litestream replicate -config /etc/litestream.yml -exec "/vaultwarden" &
LITESTREAM_PID=$!
wait "$LITESTREAM_PID"
EXIT_CODE=$?

echo "[primary] litestream exited with code ${EXIT_CODE}, cleaning up..." >&2
if [ -n "$SYNC_PID" ] && kill -0 "$SYNC_PID" 2>/dev/null; then
  kill "$SYNC_PID" 2>/dev/null || true
  wait "$SYNC_PID" 2>/dev/null || true
fi
# Wait up to 10 seconds for backup to complete during normal exit
if [ -n "$BACKUP_PID" ] && kill -0 "$BACKUP_PID" 2>/dev/null; then
  timeout=10
  while [ $timeout -gt 0 ] && kill -0 "$BACKUP_PID" 2>/dev/null; do
    sleep 1
    timeout=$((timeout - 1))
  done
  kill "$BACKUP_PID" 2>/dev/null || true
  wait "$BACKUP_PID" 2>/dev/null || true
fi
sync_attachments_upload || echo "[primary] WARNING: final upload failed" >&2
write_sync_status "shutdown"
exit "$EXIT_CODE"
