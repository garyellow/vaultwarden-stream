#!/bin/sh
set -eu

. /app/sync.sh

VW_PID=""
STOP_REQUESTED=""

# ── Helpers ──────────────────────────────────────────────────────

stop_vaultwarden() {
  if [ -n "$VW_PID" ] && kill -0 "$VW_PID" 2>/dev/null; then
    kill "$VW_PID" 2>/dev/null || true
    wait "$VW_PID" 2>/dev/null || true
  fi
  VW_PID=""
}

start_vaultwarden() {
  /vaultwarden &
  VW_PID=$!
}

restore_database() {
  tmp_db="/tmp/db-refresh.sqlite3"
  rm -f "$tmp_db" "${tmp_db}-shm" "${tmp_db}-wal"

  if ! litestream restore -if-replica-exists -config /etc/litestream.yml -o "$tmp_db" "$LITESTREAM_DB_PATH"; then
    echo "[secondary] WARNING: database restore failed, keeping current copy" >&2
    rm -f "$tmp_db"
    return 1
  fi

  # Swap database atomically with minimal downtime
  stop_vaultwarden
  rm -f "$LITESTREAM_DB_PATH" "$LITESTREAM_DB_PATH-shm" "$LITESTREAM_DB_PATH-wal"
  mv "$tmp_db" "$LITESTREAM_DB_PATH"
  start_vaultwarden
  return 0
}

cleanup() {
  echo "[secondary] shutdown signal received, cleaning up..." >&2
  STOP_REQUESTED=1
  stop_vaultwarden
  write_sync_status "shutdown"
  exit 0
}

trap cleanup TERM INT

mkdir -p /data/attachments /data/sends

# ── Initial restore from S3 ─────────────────────────────────────
rm -f "$LITESTREAM_DB_PATH" "$LITESTREAM_DB_PATH-shm" "$LITESTREAM_DB_PATH-wal"
rm -rf "$LITESTREAM_DB_PATH-litestream"

echo "[secondary] restoring database from S3..." >&2
if ! litestream restore -if-replica-exists -config /etc/litestream.yml "$LITESTREAM_DB_PATH"; then
  echo "[secondary] ERROR: database restore failed (check S3 connectivity)" >&2
  exit 1
fi

echo "[secondary] downloading attachments and keys from S3..." >&2
if ! sync_attachments_download; then
  echo "[secondary] ERROR: initial download failed (check S3 connectivity)" >&2
  exit 1
fi
write_sync_status "ok"

# ── Start Vaultwarden ───────────────────────────────────────────
if [ "$DEPLOYMENT_MODE" = "serverless" ]; then
  echo "[secondary] starting vaultwarden (serverless DR — no periodic refresh)..." >&2
else
  echo "[secondary] starting vaultwarden (persistent DR — refresh every ${SECONDARY_SYNC_INTERVAL}s)..." >&2
fi
start_vaultwarden

# Main loop: Keep Vaultwarden running and refresh data periodically
#
# Persistent mode:
#   - Refreshes data from S3 every SECONDARY_SYNC_INTERVAL seconds
#   - Downloads attachments/keys while Vaultwarden is running (safe)
#   - Restores database to temp file, then swaps it (~2-3 seconds downtime)
#
# Serverless mode:
#   - No periodic refresh needed (data is restored fresh on every cold start)
#
# Both modes:
#   - Writes heartbeat status every 60 seconds for healthcheck
#   - Automatically restarts Vaultwarden if it exits unexpectedly

heartbeat_counter=0
seconds_since_refresh=0
while [ -z "$STOP_REQUESTED" ]; do
  sleep 1
  heartbeat_counter=$((heartbeat_counter + 1))

  # Supervised restart: if Vaultwarden exited unexpectedly, restart it
  if [ -n "$VW_PID" ] && ! kill -0 "$VW_PID" 2>/dev/null; then
    wait "$VW_PID" 2>/dev/null || true
    if [ -z "$STOP_REQUESTED" ]; then
      echo "[secondary] vaultwarden exited unexpectedly, restarting..." >&2
      start_vaultwarden
    fi
  fi

  # Write heartbeat every 60s so healthcheck stays green
  if [ "$heartbeat_counter" -ge 60 ]; then
    heartbeat_counter=0
    write_sync_status "ok"
  fi

  # Periodic refresh (persistent mode only)
  if [ "$DEPLOYMENT_MODE" != "serverless" ]; then
    seconds_since_refresh=$((seconds_since_refresh + 1))
    if [ "$seconds_since_refresh" -ge "$SECONDARY_SYNC_INTERVAL" ]; then
      seconds_since_refresh=0
      refresh_ok=true

      # Download attachments/keys (safe while VW is running)
      if ! sync_attachments_download; then
        echo "[secondary] WARNING: attachment download failed" >&2
        refresh_ok=false
      fi

      # Restore database + restart Vaultwarden
      if ! restore_database; then
        refresh_ok=false
      fi

      if [ "$refresh_ok" = true ]; then
        write_sync_status "ok"
        echo "[secondary] refresh completed" >&2
      else
        write_sync_status "error"
        echo "[secondary] WARNING: refresh failed" >&2
      fi
    fi
  fi
done
