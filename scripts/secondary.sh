#!/bin/sh
set -eu

. /app/sync.sh
. /app/tailscale.sh

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

  if [ -n "$VW_PID" ] && kill -0 "$VW_PID" 2>/dev/null; then
    kill "$VW_PID" 2>/dev/null || true
  fi

  ( tailscale_stop ) &
  _ts_pid=$!

  if [ -n "$VW_PID" ]; then
    wait "$VW_PID" 2>/dev/null || true
    VW_PID=""
  fi

  _t=20
  while [ "$_t" -gt 0 ] && kill -0 "$_ts_pid" 2>/dev/null; do
    sleep 1; _t=$((_t - 1))
  done
  if kill -0 "$_ts_pid" 2>/dev/null; then
    echo "[secondary] WARNING: tailscale shutdown timeout" >&2
    kill "$_ts_pid" 2>/dev/null || true
  fi
  wait "$_ts_pid" 2>/dev/null || true

  write_sync_status "shutdown"
  exit 0
}

trap cleanup TERM INT

mkdir -p /data/attachments /data/sends


rm -f "$LITESTREAM_DB_PATH" "$LITESTREAM_DB_PATH-shm" "$LITESTREAM_DB_PATH-wal"
rm -rf "$LITESTREAM_DB_PATH-litestream"

echo "[secondary] restoring from S3 (parallel: database + files)..." >&2

(
  if ! litestream restore -if-replica-exists -config /etc/litestream.yml "$LITESTREAM_DB_PATH"; then
    echo "[secondary] ERROR: database restore failed (check S3 connectivity)" >&2
    exit 1
  fi
  echo "[secondary] INFO: database restored" >&2
) &
_startup_db_pid=$!

(
  if ! sync_download; then
    echo "[secondary] ERROR: file download failed (check S3 connectivity)" >&2
    exit 1
  fi
  echo "[secondary] INFO: files downloaded" >&2
) &
_startup_files_pid=$!

_startup_failed=0
wait "$_startup_db_pid" || _startup_failed=1
wait "$_startup_files_pid" || _startup_failed=1

if [ "$_startup_failed" -eq 1 ]; then
  echo "[secondary] ERROR: startup restore/download failed" >&2
  exit 1
fi

write_sync_status "ok"


if [ "$DEPLOYMENT_MODE" = "serverless" ]; then
  echo "[secondary] starting vaultwarden (serverless DR — no periodic refresh)" >&2
else
  echo "[secondary] starting vaultwarden (persistent DR — refresh every ${SECONDARY_SYNC_INTERVAL}s)" >&2
fi
start_vaultwarden

heartbeat_counter=0
seconds_since_refresh=0
while [ -z "$STOP_REQUESTED" ]; do
  sleep 1
  heartbeat_counter=$((heartbeat_counter + 1))

  if [ -n "$VW_PID" ] && ! kill -0 "$VW_PID" 2>/dev/null; then
    wait "$VW_PID" 2>/dev/null || true
    if [ -z "$STOP_REQUESTED" ]; then
      echo "[secondary] WARNING: vaultwarden exited unexpectedly, restarting..." >&2
      start_vaultwarden
    fi
  fi

  if [ "$heartbeat_counter" -ge 60 ]; then
    heartbeat_counter=0
    write_sync_status "ok"
  fi

  if [ "$DEPLOYMENT_MODE" != "serverless" ]; then
    seconds_since_refresh=$((seconds_since_refresh + 1))
    if [ "$seconds_since_refresh" -ge "$SECONDARY_SYNC_INTERVAL" ]; then
      seconds_since_refresh=0
      refresh_ok=true

      _refresh_tmp_db="/tmp/db-refresh.sqlite3"
      rm -f "$_refresh_tmp_db" "${_refresh_tmp_db}-shm" "${_refresh_tmp_db}-wal"

      (
        if ! sync_download; then
          echo "[secondary] WARNING: file download failed" >&2
          exit 1
        fi
      ) &
      _refresh_files_pid=$!

      (
        if ! litestream restore -if-replica-exists -config /etc/litestream.yml \
            -o "$_refresh_tmp_db" "$LITESTREAM_DB_PATH"; then
          exit 1
        fi
      ) &
      _refresh_db_pid=$!

      if ! wait "$_refresh_files_pid"; then
        refresh_ok=false
      fi

      _db_downloaded=true
      if ! wait "$_refresh_db_pid"; then
        echo "[secondary] WARNING: database download failed, keeping current copy" >&2
        rm -f "$_refresh_tmp_db"
        _db_downloaded=false
        refresh_ok=false
      fi

      if [ "$_db_downloaded" = true ] && [ -f "$_refresh_tmp_db" ]; then
        stop_vaultwarden
        rm -f "$LITESTREAM_DB_PATH" "$LITESTREAM_DB_PATH-shm" "$LITESTREAM_DB_PATH-wal"
        mv "$_refresh_tmp_db" "$LITESTREAM_DB_PATH"
        start_vaultwarden
      fi

      if [ "$refresh_ok" = true ]; then
        write_sync_status "ok"
        echo "[secondary] INFO: refresh completed" >&2
      else
        write_sync_status "error"
        echo "[secondary] WARNING: refresh failed" >&2
        send_notification "sync_error" "/fail"
      fi
    fi
  fi
done
