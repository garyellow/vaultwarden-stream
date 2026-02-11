#!/bin/sh
# Snapshot backup — scheduled archives with format selection and optional encryption

set -eu

# Source shared helpers (rclone_safe, CORE_FILES, notifications)
. /app/sync.sh

# ── Backup management ─────────────────────────────────────────────

# Clean up old backups while maintaining minimum count
cleanup_backups() {
  target="$1"
  retention_days="$BACKUP_RETENTION_DAYS"
  min_keep="$BACKUP_MIN_KEEP"

  [ "$retention_days" -gt 0 ] 2>/dev/null || return 0
  [ "$min_keep" -gt 0 ] 2>/dev/null || return 0

  all_backups=$(rclone_safe lsf "$target" 2>/dev/null | \
    grep -E "^vaultwarden-[0-9]{8}-[0-9]{6}\.(tar\.gz|tar\.gz\.enc|tar)$" | sort -r || true)

  [ -z "$all_backups" ] && return 0

  old_files=$(rclone_safe lsf "$target" --min-age "${retention_days}d" 2>/dev/null | \
    grep -E "^vaultwarden-[0-9]{8}-[0-9]{6}\.(tar\.gz|tar\.gz\.enc|tar)$" || true)

  [ -z "$old_files" ] && return 0

  total=$(printf '%s\n' "$all_backups" | wc -l | tr -d ' ')
  old_count=$(printf '%s\n' "$old_files" | wc -l | tr -d ' ')
  recent=$((total - old_count))

  deleted=0

  if [ "$recent" -ge "$min_keep" ]; then
    for file in $old_files; do
      rclone_safe deletefile "${target}${file}" && deleted=$((deleted + 1)) || true
    done
  else
    # Keep newest old backups to reach minimum count
    need_from_old=$((min_keep - recent))
    old_sorted=$(printf '%s\n' "$old_files" | sort -r)
    protected=$(printf '%s\n' "$old_sorted" | head -n "$need_from_old")

    for file in $old_sorted; do
      if printf '%s\n' "$protected" | grep -qxF "$file"; then
        continue
      fi
      rclone_safe deletefile "${target}${file}" && deleted=$((deleted + 1)) || true
    done
  fi

  remaining_count=$((total - deleted))
  echo "[backup] cleanup ${target}: deleted ${deleted}, remaining ${remaining_count}" >&2
}

# Upload a backup file to all configured remotes
upload_backup() {
  local_file="$1"
  [ -n "${BACKUP_REMOTES:-}" ] || return 1

  _ub_pids=""
  _ub_count=0

  remaining="$BACKUP_REMOTES"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      *,*) dest="${remaining%%,*}"; remaining="${remaining#*,}" ;;
      *)   dest="$remaining"; remaining="" ;;
    esac
    dest=$(echo "$dest" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$dest" ] && continue

    (
      if rclone_safe copy "$local_file" "${dest}/"; then
        echo "[backup] uploaded to ${dest}" >&2
        exit 0
      else
        echo "[backup] WARNING: upload to ${dest} failed" >&2
        exit 1
      fi
    ) &
    _ub_pids="$_ub_pids $!"
    _ub_count=$((_ub_count + 1))
  done

  success=0
  for pid in $_ub_pids; do
    if wait "$pid"; then
      success=1
    fi
  done

  if [ "$success" -eq 1 ]; then
    echo "[backup] successfully uploaded to at least 1 of ${_ub_count} remote(s)" >&2
    return 0
  fi

  echo "[backup] ERROR: all ${_ub_count} upload(s) failed" >&2
  return 1
}

# Clean up old backups on all configured remotes
cleanup_all_remotes() {
  [ -n "${BACKUP_REMOTES:-}" ] || return 0

  _car_pids=""
  remaining="$BACKUP_REMOTES"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      *,*) dest="${remaining%%,*}"; remaining="${remaining#*,}" ;;
      *)   dest="$remaining"; remaining="" ;;
    esac
    dest=$(echo "$dest" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$dest" ] && continue

    ( cleanup_backups "${dest}/" ) &
    _car_pids="$_car_pids $!"
  done

  for pid in $_car_pids; do
    wait "$pid" || true
  done
}

cron_field_match() {
  field="$1"
  value="$2"

  [ "$field" = "*" ] && return 0

  remainder="$field"
  while [ -n "$remainder" ]; do
    case "$remainder" in
      *,*) part="${remainder%%,*}"; remainder="${remainder#*,}" ;;
      *)   part="$remainder"; remainder="" ;;
    esac

    case "$part" in
      \*\/[0-9]*)
        step="${part#\*/}"
        [ "$step" -gt 0 ] 2>/dev/null || continue
        [ "$((value % step))" -eq 0 ] && return 0
        ;;
      [0-9]*-[0-9]*\/[0-9]*)
        range="${part%/*}"; step="${part##*/}"
        [ "$step" -gt 0 ] 2>/dev/null || continue
        start="${range%-*}"; end="${range#*-}"
        [ "$value" -ge "$start" ] && [ "$value" -le "$end" ] && \
          [ "$(( (value - start) % step ))" -eq 0 ] && return 0
        ;;
      [0-9]*-[0-9]*)
        start="${part%-*}"; end="${part#*-}"
        [ "$value" -ge "$start" ] && [ "$value" -le "$end" ] && return 0
        ;;
      *)
        [ "$value" -eq "$part" ] 2>/dev/null && return 0
        ;;
    esac
  done

  return 1
}

cron_matches_now() {
  set -f; set -- $1; set +f
  _cm="$1" _ch="$2" _cd="$3" _cM="$4" _cw="$5"

  set -- $(date '+%M %H %d %m %w')
  # Strip leading zeros to prevent octal interpretation in arithmetic
  m=${1#0}; h=${2#0}; d=${3#0}; M=${4#0}; w=$5

  cron_field_match "$_cm" "$m" || return 1
  cron_field_match "$_ch" "$h" || return 1
  cron_field_match "$_cd" "$d" || return 1
  cron_field_match "$_cM" "$M" || return 1
  cron_field_match "$_cw" "$w" || return 1
  return 0
}

create_backup() {
  timestamp=$(date -u +%Y%m%d-%H%M%S)
  backup_dir="/tmp/vw-backup-${timestamp}"

  format="$BACKUP_FORMAT"
  password="${BACKUP_PASSWORD:-}"

  case "$format" in
    tar.gz)
      if [ -n "$password" ]; then ext="tar.gz.enc"; else ext="tar.gz"; fi
      ;;
    tar) ext="tar" ;;
    *)
      echo "[backup] ERROR: unsupported format: ${format}" >&2
      send_notification "backup_failure" "/fail"
      return 1
      ;;
  esac

  backup_name="vaultwarden-${timestamp}.${ext}"
  mkdir -p "$backup_dir"

  # Verify database file exists and is accessible
  if [ ! -f "$LITESTREAM_DB_PATH" ]; then
    echo "[backup] ERROR: database file not found: $LITESTREAM_DB_PATH" >&2
    rm -rf "$backup_dir"
    send_notification "backup_failure" "/fail"
    return 1
  fi

  if ! sqlite3 "$LITESTREAM_DB_PATH" ".backup '${backup_dir}/db.sqlite3'"; then
    echo "[backup] ERROR: database snapshot failed" >&2
    rm -rf "$backup_dir"
    send_notification "backup_failure" "/fail"
    return 1
  fi

  _cb_attach_pid=""
  _cb_sends_pid=""
  _cb_icon_pid=""

  # Attachments
  if [ "$BACKUP_INCLUDE_ATTACHMENTS" = "true" ]; then
    (
      if [ -d /data/attachments ] && [ "$(ls -A /data/attachments 2>/dev/null)" ]; then
        cp -a /data/attachments "$backup_dir/"
      fi
    ) &
    _cb_attach_pid=$!
  fi

  # Sends
  if [ "$BACKUP_INCLUDE_SENDS" = "true" ]; then
    (
      if [ -d /data/sends ] && [ "$(ls -A /data/sends 2>/dev/null)" ]; then
        cp -a /data/sends "$backup_dir/"
      fi
    ) &
    _cb_sends_pid=$!
  fi

  # Icon cache
  if [ "$BACKUP_INCLUDE_ICON_CACHE" = "true" ]; then
    (
      if [ -d /data/icon_cache ] && [ "$(ls -A /data/icon_cache 2>/dev/null)" ]; then
        cp -a /data/icon_cache "$backup_dir/"
      fi
    ) &
    _cb_icon_pid=$!
  fi

  # RSA keys and config
  if [ "$BACKUP_INCLUDE_CONFIG" = "true" ]; then
    for file in $CORE_FILES; do
      [ -f "/data/$file" ] && cp -a "/data/$file" "$backup_dir/"
    done
  fi

  if [ -n "$_cb_attach_pid" ]; then
    wait "$_cb_attach_pid" || true
  fi
  if [ -n "$_cb_sends_pid" ]; then
    wait "$_cb_sends_pid" || true
  fi
  if [ -n "$_cb_icon_pid" ]; then
    wait "$_cb_icon_pid" || true
  fi

  archive_ok=false
  case "$format" in
    tar.gz)
      if [ -n "$password" ]; then
        temp_archive="/tmp/vw-temp-${timestamp}.tar.gz"
        if tar -czf "$temp_archive" -C "$backup_dir" .; then
          if openssl enc -aes-256-cbc -pbkdf2 -pass env:BACKUP_PASSWORD \
              -in "$temp_archive" -out "/tmp/${backup_name}"; then
            archive_ok=true
          else
            echo "[backup] ERROR: encryption failed" >&2
          fi
        fi
        rm -f "$temp_archive"
      else
        if tar -czf "/tmp/${backup_name}" -C "$backup_dir" .; then
          archive_ok=true
        fi
      fi
      ;;
    tar)
      if tar -cf "/tmp/${backup_name}" -C "$backup_dir" .; then
        archive_ok=true
      fi
      ;;
  esac

  rm -rf "$backup_dir"

  if [ "$archive_ok" != "true" ]; then
    echo "[backup] ERROR: archive creation failed" >&2
    rm -f "/tmp/${backup_name}"
    send_notification "backup_failure" "/fail"
    return 1
  fi

  echo "[backup] created ${backup_name}" >&2

  if ! upload_backup "/tmp/${backup_name}"; then
    echo "[backup] ERROR: all uploads failed" >&2
    rm -f "/tmp/${backup_name}"
    send_notification "backup_failure" "/fail"
    return 1
  fi

  rm -f "/tmp/${backup_name}"

  cleanup_all_remotes

  # Send success notification
  send_notification "backup_success" ""

  return 0
}
