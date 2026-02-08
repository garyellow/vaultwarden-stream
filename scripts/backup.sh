#!/bin/sh
# backup.sh — Periodic snapshot backup to S3 (and optional extra remotes)
# Sourced by primary.sh

set -eu

# Clean up old backups on a given remote path.
# Deletes files older than BACKUP_RETENTION_DAYS, but ensures at least
# BACKUP_MIN_KEEP total backups remain. Recent backups (within retention
# period) count toward the minimum, so if enough recent backups exist,
# all old backups are removed.
cleanup_backups() {
  target="$1"
  retention_days="${BACKUP_RETENTION_DAYS:-30}"
  min_keep="${BACKUP_MIN_KEEP:-3}"

  [ "$retention_days" -gt 0 ] 2>/dev/null || return 0
  [ "$min_keep" -gt 0 ] 2>/dev/null || return 0

  # List all backup files (newest first by filename timestamp)
  all_backups=$(rclone_safe lsf "$target" 2>/dev/null | \
    grep "^vaultwarden-.*\.tar\.gz$" | sort -r || true)

  [ -z "$all_backups" ] && return 0

  # List files older than retention period
  old_files=$(rclone_safe lsf "$target" --min-age "${retention_days}d" 2>/dev/null | \
    grep "^vaultwarden-.*\.tar\.gz$" || true)

  [ -z "$old_files" ] && return 0

  total=$(printf '%s\n' "$all_backups" | wc -l | tr -d ' ')
  old_count=$(printf '%s\n' "$old_files" | wc -l | tr -d ' ')
  recent=$((total - old_count))

  deleted=0

  if [ "$recent" -ge "$min_keep" ]; then
    # Enough recent backups exist — safe to delete ALL old backups
    for file in $old_files; do
      rclone_safe deletefile "${target}${file}" && deleted=$((deleted + 1)) || true
    done
  else
    # Not enough recent backups — keep newest old ones as safety net
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

  remaining=$((total - deleted))
  echo "[backup] cleanup ${target}: deleted ${deleted}, remaining ${remaining}" >&2
}

# Upload a local file to all extra remotes (best-effort, failures are warnings)
upload_to_extra_remotes() {
  local_file="$1"

  [ -n "${BACKUP_EXTRA_REMOTES:-}" ] || return 0

  echo "$BACKUP_EXTRA_REMOTES" | tr ',' '\n' | while IFS= read -r dest; do
    dest=$(echo "$dest" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$dest" ] && continue
    if rclone_safe copy "$local_file" "${dest}/backups/" 2>&1; then
      echo "[backup] uploaded to ${dest}" >&2
    else
      echo "[backup] WARNING: upload to ${dest} failed" >&2
    fi
  done
}

# Clean up old backups on all extra remotes
cleanup_extra_remotes() {
  [ -n "${BACKUP_EXTRA_REMOTES:-}" ] || return 0

  echo "$BACKUP_EXTRA_REMOTES" | tr ',' '\n' | while IFS= read -r dest; do
    dest=$(echo "$dest" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$dest" ] && continue
    cleanup_backups "${dest}/backups/"
  done
}

create_backup() {
  timestamp=$(date -u +%Y%m%d-%H%M%S)
  backup_dir="/tmp/vw-backup-${timestamp}"
  backup_name="vaultwarden-${timestamp}.tar.gz"
  base="$(remote_base)"

  mkdir -p "$backup_dir"

  # Create database snapshot using sqlite3 .backup command
  # This uses shared locks and is safe to run while Litestream is replicating
  if ! sqlite3 "$LITESTREAM_DB_PATH" ".backup '${backup_dir}/db.sqlite3'" 2>&1; then
    echo "[backup] ERROR: database snapshot failed" >&2
    rm -rf "$backup_dir"
    return 1
  fi

  # Copy attachments and sends
  if [ -d /data/attachments ] && [ "$(ls -A /data/attachments 2>/dev/null)" ]; then
    cp -a /data/attachments "$backup_dir/"
  fi
  if [ -d /data/sends ] && [ "$(ls -A /data/sends 2>/dev/null)" ]; then
    cp -a /data/sends "$backup_dir/"
  fi

  # Copy RSA keys and config
  for file in rsa_key.pem rsa_key.pub.pem config.json; do
    [ -f "/data/$file" ] && cp -a "/data/$file" "$backup_dir/"
  done

  # Create archive
  if ! tar -czf "/tmp/${backup_name}" -C "$backup_dir" . 2>&1; then
    echo "[backup] ERROR: archive creation failed" >&2
    rm -rf "$backup_dir" "/tmp/${backup_name}"
    return 1
  fi
  rm -rf "$backup_dir"

  # Upload to primary S3
  if ! rclone_safe copy "/tmp/${backup_name}" "${base}/backups/" 2>&1; then
    echo "[backup] ERROR: upload failed" >&2
    rm -f "/tmp/${backup_name}"
    return 1
  fi
  echo "[backup] created ${backup_name}" >&2

  # Upload to extra remotes (best-effort)
  upload_to_extra_remotes "/tmp/${backup_name}"

  rm -f "/tmp/${backup_name}"

  # Cleanup old backups
  cleanup_backups "${base}/backups/"
  cleanup_extra_remotes

  return 0
}
