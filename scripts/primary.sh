#!/bin/sh
set -eu

. /app/sync-attachments.sh

SYNC_PID=""
LITESTREAM_PID=""

cleanup() {
  echo "[primary] shutdown signal received, cleaning up..." >&2
  if [ -n "$SYNC_PID" ] && kill -0 "$SYNC_PID" 2>/dev/null; then
    kill "$SYNC_PID" 2>/dev/null || true
    wait "$SYNC_PID" 2>/dev/null || true
  fi

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
sync_attachments_upload || echo "[primary] WARNING: final upload failed" >&2
write_sync_status "shutdown"
exit "$EXIT_CODE"
