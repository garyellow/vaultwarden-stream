#!/bin/sh
set -eu

SYNC_STATUS_FILE="/tmp/sync-status.json"

remote_base() {
  echo "${RCLONE_REMOTE_NAME}:${S3_BUCKET}/${S3_PREFIX}"
}

rclone_safe() {
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

# Sync Vaultwarden core files (RSA keys, config)
sync_core_files() {
  src="$1"
  dst="$2"
  for file in rsa_key.pem rsa_key.pub.pem config.json; do
    if [ -f "${src}/${file}" ]; then
      if ! rclone_safe copy "${src}/${file}" "${dst}/" 2>/dev/null; then
        echo "[sync] WARNING: failed to upload ${file}" >&2
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

  if ! sync_core_files "/data" "${base}"; then
    return 1
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

  if ! sync_core_files "${base}" "/data"; then
    return 1
  fi
}
