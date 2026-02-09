#!/bin/sh
set -eu

SYNC_STATUS_FILE="/tmp/sync-status.json"
MAX_SYNC_AGE="${HEALTHCHECK_SYNC_MAX_AGE:-600}"
ROLE="${NODE_ROLE:-primary}"

# Check if a process with given name is running
process_running() {
  process_name="$1"
  for pid_dir in /proc/[0-9]*; do
    if [ -f "$pid_dir/comm" ] && [ "$(cat "$pid_dir/comm" 2>/dev/null)" = "$process_name" ]; then
      return 0
    fi
  done
  return 1
}

# Check HTTP (both roles)
if ! curl -sf -o /dev/null "http://127.0.0.1:${ROCKET_PORT:-80}/alive"; then
  echo "UNHEALTHY: vaultwarden HTTP check failed" >&2
  exit 1
fi

# Check Litestream process (primary only)
if [ "$ROLE" = "primary" ]; then
  if ! process_running "litestream"; then
    echo "UNHEALTHY: litestream process not running" >&2
    exit 1
  fi
fi

# Check sync freshness (both roles)
if [ -f "$SYNC_STATUS_FILE" ]; then
  status=$(grep -o '"status":"[^"]*"' "$SYNC_STATUS_FILE" | head -1 | cut -d: -f2 | tr -d '"')
  if [ "$status" = "error" ]; then
    echo "UNHEALTHY: last sync status is error" >&2
    exit 1
  fi

  last_ts=$(grep -o '"timestamp":[0-9]*' "$SYNC_STATUS_FILE" | head -1 | cut -d: -f2)
  if [ -n "$last_ts" ]; then
    age=$(( $(date +%s) - last_ts ))
    if [ "$age" -gt "$MAX_SYNC_AGE" ]; then
      echo "UNHEALTHY: last sync was ${age}s ago (max ${MAX_SYNC_AGE}s)" >&2
      exit 1
    fi
  fi
fi

echo "OK"
exit 0
