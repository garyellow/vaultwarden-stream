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

  # ── Step 1: Stop sync loop (immediate) ──
  if [ -n "$SYNC_PID" ] && kill -0 "$SYNC_PID" 2>/dev/null; then
    kill "$SYNC_PID" 2>/dev/null || true
    wait "$SYNC_PID" 2>/dev/null || true
  fi

  # ── Steps 2, 3, 5: Launch in parallel ──
  _sd_backup_pid=""
  _sd_litestream_pid=""
  _sd_tailscale_pid=""

  # Step 2: Wait for in-progress snapshot backup (background)
  if [ -n "$BACKUP_PID" ] && kill -0 "$BACKUP_PID" 2>/dev/null; then
    (
      _t="$BACKUP_SHUTDOWN_TIMEOUT"
      echo "[primary] waiting for snapshot backup (timeout ${_t}s)..." >&2
      while [ "$_t" -gt 0 ] && kill -0 "$BACKUP_PID" 2>/dev/null; do
        sleep 1; _t=$((_t - 1))
      done
      if kill -0 "$BACKUP_PID" 2>/dev/null; then
        echo "[primary] WARNING: snapshot backup timeout, forcing kill" >&2
        kill "$BACKUP_PID" 2>/dev/null || true
      fi
    ) &
    _sd_backup_pid=$!
  fi

  # Step 3: Stop Litestream — flush WAL to S3 (background)
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

  # Step 5: Stop Tailscale (background — has internal timeouts)
  ( tailscale_stop ) &
  _sd_tailscale_pid=$!

  # ── Wait for Step 3: Litestream must stop before sync upload ──
  # Litestream stops Vaultwarden first, then flushes WAL. Once done,
  # no more file writes occur — safe to sync current files.
  if [ -n "$_sd_litestream_pid" ]; then
    wait "$_sd_litestream_pid" 2>/dev/null || true
  fi
  if [ -n "$LITESTREAM_PID" ]; then
    wait "$LITESTREAM_PID" 2>/dev/null || true
  fi

  # ── Step 4: Sync upload (quick mode — skip icon_cache) ──
  echo "[primary] syncing files to S3..." >&2
  ( sync_upload quick ) &
  _sd_upload_pid=$!; _t="$FINAL_UPLOAD_TIMEOUT"
  while [ "$_t" -gt 0 ] && kill -0 "$_sd_upload_pid" 2>/dev/null; do
    sleep 1; _t=$((_t - 1))
  done
  if kill -0 "$_sd_upload_pid" 2>/dev/null; then
    echo "[primary] WARNING: sync upload timeout, forcing kill" >&2
    kill "$_sd_upload_pid" 2>/dev/null || true
  fi
  wait "$_sd_upload_pid" 2>/dev/null || echo "[primary] WARNING: sync upload failed" >&2

  # ── Collect remaining parallel tasks (Steps 2, 5) ──
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

# ── Startup ──────────────────────────────────────────────────────

mkdir -p /data/attachments /data/sends

# Restore database from S3
rm -f "$LITESTREAM_DB_PATH" "$LITESTREAM_DB_PATH-shm" "$LITESTREAM_DB_PATH-wal"
rm -rf "$LITESTREAM_DB_PATH-litestream"

echo "[primary] restoring database from S3..." >&2
if ! litestream restore -if-replica-exists -config /etc/litestream.yml "$LITESTREAM_DB_PATH"; then
  echo "[primary] ERROR: database restore failed (check S3 connectivity)" >&2
  exit 1
fi

echo "[primary] downloading files from S3..." >&2
if ! sync_download; then
  echo "[primary] ERROR: initial download failed (check S3 connectivity)" >&2
  exit 1
fi
write_sync_status "ok"

# Startup backup (if enabled)
if [ "${BACKUP_ENABLED:-false}" = "true" ] && [ "${BACKUP_ON_STARTUP:-false}" = "true" ]; then
  echo "[primary] running startup backup..." >&2
  if create_backup; then
    echo "[primary] startup backup completed" >&2
  else
    echo "[primary] WARNING: startup backup failed" >&2
  fi
fi

# ── Background loops ────────────────────────────────────────────

# Sync loop
echo "[primary] starting sync loop (interval=${PRIMARY_SYNC_INTERVAL}s)" >&2
(
  while true; do
    sleep "$PRIMARY_SYNC_INTERVAL"
    if sync_upload; then
      write_sync_status "ok"
      echo "[primary] sync completed" >&2
    else
      write_sync_status "error"
      echo "[primary] WARNING: sync failed" >&2
      send_notification "sync_error" "/fail"
    fi
  done
) &
SYNC_PID=$!

# Backup loop (if enabled)
if [ "${BACKUP_ENABLED:-false}" = "true" ]; then
  echo "[primary] backup schedule: ${BACKUP_CRON}" >&2
  (
    last_run=""
    while true; do
      sleep 30
      if cron_matches_now "$BACKUP_CRON"; then
        mark=$(date +%Y%m%d%H%M)
        if [ "$mark" != "$last_run" ]; then
          last_run="$mark"
          echo "[primary] backup triggered (${BACKUP_CRON})" >&2
          if ! create_backup; then
            echo "[primary] WARNING: backup failed" >&2
          fi
        fi
      fi
    done
  ) &
  BACKUP_PID=$!
fi

# ── Launch Vaultwarden ──────────────────────────────────────────

echo "[primary] starting vaultwarden..." >&2
litestream replicate -config /etc/litestream.yml -exec "/vaultwarden" &
LITESTREAM_PID=$!
EXIT_CODE=0
wait "$LITESTREAM_PID" || EXIT_CODE=$?
LITESTREAM_PID=""

echo "[primary] litestream exited (code ${EXIT_CODE}), shutting down..." >&2
shutdown_all
exit "$EXIT_CODE"
