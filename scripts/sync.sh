#!/bin/sh
set -eu

SYNC_STATUS_FILE="/tmp/sync-status.json"

# ── Notification helper ─────────────────────────────────────────────

# Send notification if URL is configured and event is enabled
# Usage: send_notification <event_name> [url_suffix]
send_notification() {
  event="$1"
  suffix="${2:-}"

  [ -z "${NOTIFICATION_URL:-}" ] && return 0

  # If specific events are configured, check this event is in the list
  if [ -n "${NOTIFICATION_EVENTS:-}" ]; then
    events=$(echo "${NOTIFICATION_EVENTS}" | tr -d '[:space:]')
    echo ",${events}," | grep -q ",${event}," || return 0
  fi

  url="${NOTIFICATION_URL}${suffix}"
  timeout="${NOTIFICATION_TIMEOUT:-10}"

  # Best-effort: notification failure must never affect process lifecycle
  curl -fsS -m "$timeout" "$url" >/dev/null 2>&1 || \
    echo "[notification] WARNING: failed to send ${event} notification" >&2
  return 0
}

# ── Status tracking ────────────────────────────────────────────────

remote_base() {
  echo "${RCLONE_REMOTE_NAME}:${S3_BUCKET}/${S3_PREFIX}"
}

rclone_safe() {
  # shellcheck disable=SC2086  # intentional word splitting for multiple flags
  rclone ${RCLONE_FLAGS:-} "$@"
}

remote_path_exists() {
  rclone_safe lsf --max-depth 1 "$1" >/dev/null 2>&1
}

write_sync_status() {
  status="$1"
  ts=$(date +%s)
  iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  role="${NODE_ROLE:-primary}"
  cat > "$SYNC_STATUS_FILE" <<EOF
{"status":"${status}","role":"${role}","timestamp":${ts},"datetime":"${iso}"}
EOF
}

CORE_FILES="rsa_key.pem rsa_key.pub.pem rsa_key.der rsa_key.pub.der config.json"

# ── Core files ──────────────────────────────────────────────────

# Upload core files from local directory to remote
upload_core_files() {
  dst="$1"
  for file in $CORE_FILES; do
    if [ -f "/data/${file}" ]; then
      if ! rclone_safe copy "/data/${file}" "${dst}/" 2>/dev/null; then
        echo "[sync] WARNING: failed to upload ${file}" >&2
        return 1
      fi
    fi
  done
  return 0
}

# Download core files from remote to local directory
download_core_files() {
  src="$1"
  for file in $CORE_FILES; do
    if rclone_safe lsf "${src}/${file}" >/dev/null 2>&1; then
      if ! rclone_safe copy "${src}/${file}" "/data/" 2>/dev/null; then
        echo "[sync] WARNING: failed to download ${file}" >&2
        return 1
      fi
    fi
  done
  return 0
}

# Upload files to S3 with safety checks
sync_attachments_upload() {
  base="$(remote_base)"

  if ! rclone_safe lsf --max-depth 1 "${base}" >/dev/null 2>&1; then
    echo "[upload] ERROR: S3 unreachable" >&2
    return 1
  fi

  suffix=".deleted.$(date -u +%Y%m%dT%H%M%SZ)"
  trash_base="${base}/_trash"

  local_attachments_count=$(find /data/attachments -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "${local_attachments_count}" -eq 0 ]; then
    remote_attachments_count=$(rclone_safe lsf --files-only --recursive "${base}/attachments" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${remote_attachments_count}" -gt 0 ]; then
      echo "[upload] ERROR: local attachments empty but remote has data, refusing sync" >&2
      return 1
    fi
  fi

  local_sends_count=$(find /data/sends -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "${local_sends_count}" -eq 0 ]; then
    remote_sends_count=$(rclone_safe lsf --files-only --recursive "${base}/sends" 2>/dev/null | wc -l | tr -d ' ')
    if [ "${remote_sends_count}" -gt 0 ]; then
      echo "[upload] ERROR: local sends empty but remote has data, refusing sync" >&2
      return 1
    fi
  fi

  if ! rclone_safe sync /data/attachments "${base}/attachments" --backup-dir "${trash_base}/attachments" --suffix "${suffix}" 2>&1; then
    echo "[upload] ERROR: attachments sync failed" >&2
    return 1
  fi

  if ! rclone_safe sync /data/sends "${base}/sends" --backup-dir "${trash_base}/sends" --suffix "${suffix}" 2>&1; then
    echo "[upload] ERROR: sends sync failed" >&2
    return 1
  fi

  if ! upload_core_files "${base}"; then
    return 1
  fi

  # Upload icon cache if it exists and is not empty
  # Safety check: refuse to sync if local is empty but remote has data
  if [ -d /data/icon_cache ]; then
    local_icon_cache_count=$(find /data/icon_cache -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "${local_icon_cache_count}" -eq 0 ]; then
      remote_icon_cache_count=$(rclone_safe lsf --files-only --recursive "${base}/icon_cache" 2>/dev/null | wc -l | tr -d ' ')
      if [ "${remote_icon_cache_count}" -gt 0 ]; then
        echo "[upload] WARNING: local icon_cache empty but remote has data, skipping sync" >&2
        # Icon cache is regenerable, so we don't fail the entire sync
      fi
    elif ! rclone_safe sync /data/icon_cache "${base}/icon_cache" --backup-dir "${trash_base}/icon_cache" --suffix "${suffix}" 2>&1; then
      echo "[upload] ERROR: icon_cache sync failed" >&2
      return 1
    fi
  fi
}

# Download files from S3
# Syncs all files from S3 to local directories, mirroring S3 state exactly
sync_attachments_download() {
  base="$(remote_base)"
  if ! remote_path_exists "${base}"; then
    echo "[download] ERROR: S3 unreachable" >&2
    return 1
  fi

  if remote_path_exists "${base}/attachments"; then
    if ! rclone_safe sync "${base}/attachments" /data/attachments 2>&1; then
      echo "[download] ERROR: attachments sync failed" >&2
      return 1
    fi
  fi

  if remote_path_exists "${base}/sends"; then
    if ! rclone_safe sync "${base}/sends" /data/sends 2>&1; then
      echo "[download] ERROR: sends sync failed" >&2
      return 1
    fi
  fi

  if ! download_core_files "${base}"; then
    return 1
  fi

  # Download icon cache if it exists on remote
  if remote_path_exists "${base}/icon_cache"; then
    if ! rclone_safe sync "${base}/icon_cache" /data/icon_cache 2>&1; then
      echo "[download] ERROR: icon_cache sync failed" >&2
      return 1
    fi
  fi
}
