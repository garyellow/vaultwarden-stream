#!/bin/sh
# backup.sh — Periodic snapshot backup to S3
# Sourced by primary.sh

set -eu

create_backup() {
  timestamp=$(date -u +%Y%m%d-%H%M%S)
  backup_dir="/tmp/vw-backup-${timestamp}"
  backup_name="vaultwarden-${timestamp}.tar.gz"
  base="$(remote_base)"

  echo "[backup] starting snapshot backup..." >&2
  mkdir -p "$backup_dir"

  # Create database snapshot using sqlite3 .backup command
  # This uses shared locks and is safe to run while Litestream is replicating
  echo "[backup] creating database snapshot..." >&2
  if ! sqlite3 "$LITESTREAM_DB_PATH" ".backup '${backup_dir}/db.sqlite3'"; then
    echo "[backup] ERROR: database backup failed" >&2
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
  echo "[backup] creating archive ${backup_name}..." >&2
  if ! tar -czf "/tmp/${backup_name}" -C "$backup_dir" .; then
    echo "[backup] ERROR: archive creation failed" >&2
    rm -rf "$backup_dir" "/tmp/${backup_name}"
    return 1
  fi
  rm -rf "$backup_dir"

  # Upload to S3
  echo "[backup] uploading to S3..." >&2
  if ! rclone_safe copy "/tmp/${backup_name}" "${base}/backups/"; then
    echo "[backup] ERROR: upload to S3 failed" >&2
    rm -f "/tmp/${backup_name}"
    return 1
  fi
  rm -f "/tmp/${backup_name}"
  echo "[backup] successfully uploaded ${backup_name}" >&2

  # Cleanup old backups
  retention_days="${BACKUP_RETENTION_DAYS:-30}"
  if [ "$retention_days" -gt 0 ] 2>/dev/null; then
    rclone_safe delete "${base}/backups/" --min-age "${retention_days}d" 2>/dev/null || true
    echo "[backup] cleaned up backups older than ${retention_days} days" >&2
  fi

  return 0
}
