#!/bin/sh
set -eu

. /app/sync.sh
. /app/backup.sh
. /app/tailscale.sh

SYNC_PID=""
BACKUP_PID=""
LITESTREAM_PID=""
SHUTDOWN_IN_PROGRESS=""

# ── Shutdown ─────────────────────────────────────────────────────

shutdown_all() {
  [ -n "$SHUTDOWN_IN_PROGRESS" ] && return 0
  SHUTDOWN_IN_PROGRESS=1

  if [ -n "$SYNC_PID" ] && kill -0 "$SYNC_PID" 2>/dev/null; then
    kill "$SYNC_PID" 2>/dev/null || true
    wait "$SYNC_PID" 2>/dev/null || true
  fi

  _sd_backup_pid=""
  _sd_litestream_pid=""
  _sd_tailscale_pid=""

  if [ -n "$BACKUP_PID" ] && kill -0 "$BACKUP_PID" 2>/dev/null; then
    # Signal backup loop to exit after current operation completes
    kill "$BACKUP_PID" 2>/dev/null || true
    (
      _t="$BACKUP_SHUTDOWN_TIMEOUT"
      echo "[primary] stopping backup loop (timeout ${_t}s)..." >&2
      while [ "$_t" -gt 0 ] && kill -0 "$BACKUP_PID" 2>/dev/null; do
        sleep 1; _t=$((_t - 1))
      done
      if kill -0 "$BACKUP_PID" 2>/dev/null; then
        echo "[primary] WARNING: snapshot backup timeout, forcing kill" >&2
        kill -9 "$BACKUP_PID" 2>/dev/null || true
      fi
    ) &
    _sd_backup_pid=$!
  fi

  if [ -n "$LITESTREAM_PID" ] && kill -0 "$LITESTREAM_PID" 2>/dev/null; then
    (
      _t="$LITESTREAM_SHUTDOWN_TIMEOUT"
      echo "[primary] stopping litestream (timeout ${_t}s)..." >&2
      kill "$LITESTREAM_PID" 2>/dev/null || true
      while [ "$_t" -gt 0 ] && kill -0 "$LITESTREAM_PID" 2>/dev/null; do
        sleep 1; _t=$((_t - 1))
      done
      if kill -0 "$LITESTREAM_PID" 2>/dev/null; then
        echo "[primary] WARNING: litestream timeout, forcing kill" >&2
        kill -9 "$LITESTREAM_PID" 2>/dev/null || true
      fi
    ) &
    _sd_litestream_pid=$!
  fi

  ( tailscale_stop ) &
  _sd_tailscale_pid=$!

  if [ -n "$_sd_litestream_pid" ]; then
    wait "$_sd_litestream_pid" 2>/dev/null || true
  fi
  if [ -n "$LITESTREAM_PID" ]; then
    wait "$LITESTREAM_PID" 2>/dev/null || true
  fi

  echo "[primary] syncing files to S3..." >&2
  ( sync_upload ) &
  _sd_upload_pid=$!; _t="$SYNC_SHUTDOWN_TIMEOUT"
  while [ "$_t" -gt 0 ] && kill -0 "$_sd_upload_pid" 2>/dev/null; do
    sleep 1; _t=$((_t - 1))
  done
  if kill -0 "$_sd_upload_pid" 2>/dev/null; then
    echo "[primary] WARNING: sync upload timeout, forcing kill" >&2
    kill "$_sd_upload_pid" 2>/dev/null || true
  fi
  wait "$_sd_upload_pid" 2>/dev/null || echo "[primary] WARNING: sync upload failed" >&2

  if [ -n "$_sd_backup_pid" ]; then
    wait "$_sd_backup_pid" 2>/dev/null || true
  fi
  if [ -n "$BACKUP_PID" ]; then
    wait "$BACKUP_PID" 2>/dev/null || true
  fi
  if [ -n "$_sd_tailscale_pid" ]; then
    if kill -0 "$_sd_tailscale_pid" 2>/dev/null; then
      echo "[primary] WARNING: tailscale still stopping, forcing kill" >&2
      kill "$_sd_tailscale_pid" 2>/dev/null || true
    fi
    wait "$_sd_tailscale_pid" 2>/dev/null || true
  fi

  write_sync_status "shutdown"
}

cleanup() {
  echo "[primary] shutdown signal received, cleaning up..." >&2
  shutdown_all
  exit 0
}

trap cleanup TERM INT

mkdir -p /data/attachments /data/sends

if [ -f "$LITESTREAM_DB_PATH" ]; then
  echo "[primary] local database exists, skipping startup restore/download" >&2
  write_sync_status "ok"
else
  rm -f "$LITESTREAM_DB_PATH" "$LITESTREAM_DB_PATH-shm" "$LITESTREAM_DB_PATH-wal"
  rm -rf "$LITESTREAM_DB_PATH-litestream"

  echo "[primary] local database missing, restoring from S3 (parallel: database + files)..." >&2

  (
    if ! litestream restore -if-replica-exists -config /etc/litestream.yml "$LITESTREAM_DB_PATH"; then
      echo "[primary] ERROR: database restore failed (check S3 connectivity)" >&2
      exit 1
    fi
    echo "[primary] INFO: database restored" >&2
  ) &
  _startup_db_pid=$!

  (
    if ! sync_download; then
      echo "[primary] ERROR: file download failed (check S3 connectivity)" >&2
      exit 1
    fi
    echo "[primary] INFO: files downloaded" >&2
  ) &
  _startup_files_pid=$!

  _startup_failed=0
  wait "$_startup_db_pid" || _startup_failed=1
  wait "$_startup_files_pid" || _startup_failed=1

  if [ "$_startup_failed" -eq 1 ]; then
    echo "[primary] ERROR: startup restore/download failed" >&2
    exit 1
  fi

  write_sync_status "ok"
fi

if [ "$BACKUP_ENABLED" = "true" ] && [ "$BACKUP_ON_STARTUP" = "true" ]; then
  echo "[primary] running startup backup..." >&2
  if create_backup; then
    echo "[primary] INFO: startup backup completed" >&2
  else
    echo "[primary] WARNING: startup backup failed" >&2
  fi
fi


echo "[primary] starting sync loop (interval=${PRIMARY_SYNC_INTERVAL}s)" >&2
(
  STOP_REQUESTED=""
  trap 'STOP_REQUESTED=1' TERM
  while [ -z "$STOP_REQUESTED" ]; do
    sleep "$PRIMARY_SYNC_INTERVAL" &
    wait $! 2>/dev/null || true
    [ -n "$STOP_REQUESTED" ] && break
    if sync_upload; then
      write_sync_status "ok"
      echo "[primary] INFO: sync completed" >&2
    else
      write_sync_status "error"
      echo "[primary] WARNING: sync failed" >&2
      send_notification "sync_error" "/fail"
    fi
  done
  echo "[primary] INFO: sync loop exited gracefully" >&2
) &
SYNC_PID=$!

if [ "$BACKUP_ENABLED" = "true" ]; then
  echo "[primary] backup schedule: ${BACKUP_CRON}" >&2
  (
    STOP_REQUESTED=""
    trap 'STOP_REQUESTED=1' TERM
    last_run=""
    while [ -z "$STOP_REQUESTED" ]; do
      sleep 30 &
      wait $! 2>/dev/null || true
      [ -n "$STOP_REQUESTED" ] && break
      if cron_matches_now "$BACKUP_CRON"; then
        mark=$(date +%Y%m%d%H%M)
        if [ "$mark" != "$last_run" ]; then
          last_run="$mark"
          echo "[primary] backup triggered (${BACKUP_CRON})" >&2
          if ! create_backup; then
            echo "[primary] WARNING: backup failed" >&2
          fi
          [ -n "$STOP_REQUESTED" ] && break
        fi
      fi
    done
    echo "[primary] INFO: backup loop exited gracefully" >&2
  ) &
  BACKUP_PID=$!
fi


echo "[primary] starting vaultwarden..." >&2
litestream replicate -config /etc/litestream.yml -exec "/vaultwarden" &
LITESTREAM_PID=$!
EXIT_CODE=0
wait "$LITESTREAM_PID" || EXIT_CODE=$?
LITESTREAM_PID=""

echo "[primary] litestream exited (code ${EXIT_CODE}), shutting down..." >&2
shutdown_all
exit "$EXIT_CODE"
