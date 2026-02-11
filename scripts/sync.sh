#!/bin/sh
# TAR-based file sync — pack directories into tar archives, upload/download via rclone

set -eu

SYNC_STATUS_FILE="/tmp/sync-status.json"
CORE_FILES="rsa_key.pem rsa_key.pub.pem rsa_key.der rsa_key.pub.der config.json"

# ── Notification helper ─────────────────────────────────────────────

# Send notification if URL is configured and event is enabled
# Usage: send_notification <event_name> [url_suffix]
send_notification() {
  _sn_event="$1"
  _sn_suffix="${2:-}"

  [ -z "${NOTIFICATION_URL:-}" ] && return 0

  # If specific events are configured, check this event is in the list
  if [ -n "${NOTIFICATION_EVENTS:-}" ]; then
    _sn_list=$(echo "${NOTIFICATION_EVENTS}" | tr -d '[:space:]')
    echo ",${_sn_list}," | grep -q ",${_sn_event}," || return 0
  fi

  _sn_url="${NOTIFICATION_URL}${_sn_suffix}"
  _sn_timeout="$NOTIFICATION_TIMEOUT"

  # Best-effort: notification failure must never affect process lifecycle
  curl -fsS -m "$_sn_timeout" "$_sn_url" >/dev/null 2>&1 || \
    echo "[notification] WARNING: failed to send ${_sn_event} notification" >&2
  return 0
}

# ── rclone helpers ────────────────────────────────────────────────

remote_base() {
  echo "${RCLONE_REMOTE_NAME}:${S3_BUCKET}/${S3_PREFIX}"
}

rclone_safe() {
  # shellcheck disable=SC2086  # intentional word splitting for multiple flags
  rclone ${RCLONE_FLAGS:-} "$@"
}

# ── Status tracking ────────────────────────────────────────────────

write_sync_status() {
  _ws_status="$1"
  _ws_ts=$(date +%s)
  _ws_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  _ws_role="${NODE_ROLE:-primary}"
  cat > "$SYNC_STATUS_FILE" <<EOF
{"status":"${_ws_status}","role":"${_ws_role}","timestamp":${_ws_ts},"datetime":"${_ws_iso}"}
EOF
}

# ── TAR pack / unpack ─────────────────────────────────────────────

# Pack directory to tar and upload to S3 (skips if unchanged)
pack_and_upload() {
  _pu_dir="$1"
  _pu_tar="$2"
  _pu_base="$(remote_base)"
  _pu_tmp="/tmp/${_pu_tar}"
  _pu_hash_file="/tmp/.sync-hash-${_pu_tar}"

  if ! tar -cf "$_pu_tmp" -C "$_pu_dir" .; then
    echo "[sync] ERROR: failed to create ${_pu_tar}" >&2
    rm -f "$_pu_tmp"
    return 1
  fi

  # Skip upload if tar content is unchanged since last successful upload
  _pu_cur_hash=$(md5sum "$_pu_tmp" | cut -d' ' -f1)
  if [ -f "$_pu_hash_file" ] && [ "$(cat "$_pu_hash_file")" = "$_pu_cur_hash" ]; then
    rm -f "$_pu_tmp"
    return 0
  fi

  if ! rclone_safe copyto "$_pu_tmp" "${_pu_base}/${_pu_tar}"; then
    echo "[sync] ERROR: failed to upload ${_pu_tar}" >&2
    rm -f "$_pu_tmp"
    return 1
  fi

  echo "$_pu_cur_hash" > "$_pu_hash_file"
  rm -f "$_pu_tmp"
  return 0
}

# Download tar from S3 and extract atomically
download_and_unpack() {
  _du_tar="$1"
  _du_dir="$2"
  _du_base="$(remote_base)"
  _du_tmp="/tmp/${_du_tar}"
  _du_stage="/data/.tmp-${_du_tar%.tar}"

  # Check if tar exists on remote (verify lsf output, not just exit code)
  _du_listed=$(rclone_safe lsf "${_du_base}/${_du_tar}" 2>/dev/null || true)
  if [ -z "$_du_listed" ]; then
    return 0
  fi

  if ! rclone_safe copyto "${_du_base}/${_du_tar}" "$_du_tmp"; then
    echo "[sync] ERROR: failed to download ${_du_tar}" >&2
    rm -f "$_du_tmp"
    return 1
  fi

  # Verify file was actually downloaded
  if [ ! -f "$_du_tmp" ]; then
    echo "[sync] ${_du_tar} not found on remote, skipping" >&2
    return 0
  fi

  # Extract to staging directory
  rm -rf "$_du_stage"
  mkdir -p "$_du_stage"

  if ! tar -xf "$_du_tmp" -C "$_du_stage"; then
    echo "[sync] ERROR: failed to extract ${_du_tar}" >&2
    rm -f "$_du_tmp"
    rm -rf "$_du_stage"
    return 1
  fi

  rm -f "$_du_tmp"

  # Atomic swap: rename old → .old, rename stage → target, remove .old
  _du_old="${_du_dir}.old"
  rm -rf "$_du_old"
  [ -d "$_du_dir" ] && mv "$_du_dir" "$_du_old"
  mv "$_du_stage" "$_du_dir"
  rm -rf "$_du_old"

  return 0
}

# ── Upload (primary) ─────────────────────────────────────────────

# Upload data to S3 as tar archives (pass 'quick' to skip icon_cache)
sync_upload() {
  _su_quick="${1:-}"
  _su_base="$(remote_base)"

  # Verify S3 connectivity
  if ! rclone_safe lsf --max-depth 1 "${_su_base}" >/dev/null 2>&1; then
    echo "[sync] ERROR: S3 unreachable" >&2
    return 1
  fi

  # Parallel upload tasks
  _su_attach_pid=""
  _su_sends_pid=""
  _su_config_pid=""
  _su_icon_pid=""

  # ── Attachments (background) ──
  (
    _su_count=$(find /data/attachments -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$_su_count" -eq 0 ]; then
      if rclone_safe lsf "${_su_base}/attachments.tar" 2>/dev/null | grep -q .; then
        echo "[sync] ERROR: local attachments empty but remote has data, refusing upload" >&2
        exit 1
      fi
    else
      if ! pack_and_upload /data/attachments attachments.tar; then
        exit 1
      fi
    fi
  ) &
  _su_attach_pid=$!

  # Sends
  (
    _su_count=$(find /data/sends -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$_su_count" -eq 0 ]; then
      if rclone_safe lsf "${_su_base}/sends.tar" 2>/dev/null | grep -q .; then
        echo "[sync] ERROR: local sends empty but remote has data, refusing upload" >&2
        exit 1
      fi
    else
      if ! pack_and_upload /data/sends sends.tar; then
        exit 1
      fi
    fi
  ) &
  _su_sends_pid=$!

  # Config files
  (
    _su_config="/tmp/config-stage-$$"
    rm -rf "$_su_config"
    mkdir -p "$_su_config"
    _su_has=0
    for _su_file in $CORE_FILES; do
      if [ -f "/data/${_su_file}" ]; then
        cp -a "/data/${_su_file}" "$_su_config/"
        _su_has=1
      fi
    done
    if [ "$_su_has" -eq 1 ]; then
      if ! pack_and_upload "$_su_config" config.tar; then
        rm -rf "$_su_config"
        exit 1
      fi
    fi
    rm -rf "$_su_config"
  ) &
  _su_config_pid=$!

  # Icon cache (skip in quick mode)
  if [ "$_su_quick" != "quick" ] && [ -d /data/icon_cache ]; then
    (
      _su_count=$(find /data/icon_cache -type f 2>/dev/null | wc -l | tr -d ' ')
      if [ "$_su_count" -eq 0 ]; then
        if rclone_safe lsf "${_su_base}/icon_cache.tar" 2>/dev/null | grep -q .; then
          echo "[sync] WARNING: local icon_cache empty but remote has data, skipping" >&2
        fi
      else
        pack_and_upload /data/icon_cache icon_cache.tar || \
          echo "[sync] WARNING: icon_cache upload failed" >&2
      fi
    ) &
    _su_icon_pid=$!
  elif [ "$_su_quick" = "quick" ]; then
    echo "[sync] skipping icon_cache in quick mode" >&2
  fi

  # Wait for critical tasks
  _su_failed=0
  if [ -n "$_su_attach_pid" ]; then
    wait "$_su_attach_pid" || _su_failed=1
  fi
  if [ -n "$_su_sends_pid" ]; then
    wait "$_su_sends_pid" || _su_failed=1
  fi
  if [ -n "$_su_config_pid" ]; then
    wait "$_su_config_pid" || _su_failed=1
  fi

  # Wait for icon_cache
  if [ -n "$_su_icon_pid" ]; then
    wait "$_su_icon_pid" || true
  fi

  if [ "$_su_failed" -eq 1 ]; then
    echo "[sync] ERROR: one or more parallel uploads failed" >&2
    return 1
  fi

  return 0
}

# ── Download (startup + secondary refresh) ────────────────────────

sync_download() {
  _sd_base="$(remote_base)"

  # Verify S3 connectivity
  if ! rclone_safe lsf --max-depth 1 "${_sd_base}" >/dev/null 2>&1; then
    echo "[sync] ERROR: S3 unreachable" >&2
    return 1
  fi

  # Parallel download tasks
  _sd_attach_pid=""
  _sd_sends_pid=""
  _sd_config_pid=""
  _sd_icon_pid=""

  # Attachments
  (
    if ! download_and_unpack attachments.tar /data/attachments; then
      exit 1
    fi
  ) &
  _sd_attach_pid=$!

  # Sends
  (
    if ! download_and_unpack sends.tar /data/sends; then
      exit 1
    fi
  ) &
  _sd_sends_pid=$!

  # Config files
  (
    _sd_tmp="/tmp/config-download-$$.tar"
    _sd_listed=$(rclone_safe lsf "${_sd_base}/config.tar" 2>/dev/null || true)
    if [ -n "$_sd_listed" ]; then
      if ! rclone_safe copyto "${_sd_base}/config.tar" "$_sd_tmp"; then
        echo "[sync] ERROR: failed to download config.tar" >&2
        rm -f "$_sd_tmp"
        exit 1
      fi
      if [ ! -f "$_sd_tmp" ]; then
        echo "[sync] config.tar not found on remote, skipping" >&2
      elif ! tar -xf "$_sd_tmp" -C /data; then
        echo "[sync] ERROR: failed to extract config.tar" >&2
        rm -f "$_sd_tmp"
        exit 1
      fi
      rm -f "$_sd_tmp"
    fi
  ) &
  _sd_config_pid=$!

  # Icon cache (non-fatal)
  (
    if ! download_and_unpack icon_cache.tar /data/icon_cache; then
      echo "[sync] WARNING: icon_cache download failed" >&2
      exit 0
    fi
  ) &
  _sd_icon_pid=$!

  # Wait for critical tasks
  _sd_failed=0
  if [ -n "$_sd_attach_pid" ]; then
    wait "$_sd_attach_pid" || _sd_failed=1
  fi
  if [ -n "$_sd_sends_pid" ]; then
    wait "$_sd_sends_pid" || _sd_failed=1
  fi
  if [ -n "$_sd_config_pid" ]; then
    wait "$_sd_config_pid" || _sd_failed=1
  fi

  # Wait for icon_cache
  if [ -n "$_sd_icon_pid" ]; then
    wait "$_sd_icon_pid" || true
  fi

  if [ "$_sd_failed" -eq 1 ]; then
    echo "[sync] ERROR: one or more critical downloads failed" >&2
    return 1
  fi

  return 0
}
