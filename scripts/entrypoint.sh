#!/bin/sh
set -eu

require_var() {
  eval "val=\${$1:-}"
  if [ -z "$val" ]; then
    echo "[entrypoint] ERROR: missing required env var: $1" >&2
    exit 1
  fi
}

# Validate required S3 credentials
require_var S3_BUCKET
require_var S3_ENDPOINT
require_var S3_PROVIDER
require_var S3_ACCESS_KEY_ID
require_var S3_SECRET_ACCESS_KEY

: "${S3_REGION:=auto}"
: "${S3_PREFIX:=vaultwarden}"
: "${S3_ACL:=private}"
: "${PRIMARY_SYNC_INTERVAL:=300}"
: "${SECONDARY_SYNC_INTERVAL:=3600}"
: "${DEPLOYMENT_MODE:=persistent}"

# Clean up S3_PREFIX by removing leading/trailing slashes and fixing double slashes
# This ensures paths like "vaultwarden" and "/vaultwarden/" are normalized to "vaultwarden"
S3_PREFIX=$(echo "$S3_PREFIX" | sed -e 's#^/*##' -e 's#/*$##' -e 's#//*#/#g')
: "${LITESTREAM_REPLICA_PATH:=${S3_PREFIX}/db.sqlite3}"
export S3_REGION S3_ACL S3_PREFIX LITESTREAM_REPLICA_PATH
export PRIMARY_SYNC_INTERVAL SECONDARY_SYNC_INTERVAL DEPLOYMENT_MODE

case "$PRIMARY_SYNC_INTERVAL" in
  *[!0-9]*)
    echo "[entrypoint] ERROR: PRIMARY_SYNC_INTERVAL must be an integer number of seconds" >&2
    exit 1
    ;;
esac

case "$SECONDARY_SYNC_INTERVAL" in
  *[!0-9]*)
    echo "[entrypoint] ERROR: SECONDARY_SYNC_INTERVAL must be an integer number of seconds" >&2
    exit 1
    ;;
esac

case "$DEPLOYMENT_MODE" in
  persistent|serverless) ;;
  *)
    echo "[entrypoint] ERROR: DEPLOYMENT_MODE must be persistent or serverless (got: $DEPLOYMENT_MODE)" >&2
    exit 1
    ;;
esac

# Validate RCLONE_REMOTE_NAME (used in shell variable expansion, must be safe)
remote="${RCLONE_REMOTE_NAME:-S3}"
case "$remote" in
  *[!A-Za-z0-9_]*)
    echo "[entrypoint] ERROR: RCLONE_REMOTE_NAME must contain only letters, digits, and underscores" >&2
    exit 1
    ;;
esac

# Configure rclone to use S3 credentials
# This creates a virtual rclone remote without needing a config file
export "RCLONE_CONFIG_${remote}_TYPE=s3"
export "RCLONE_CONFIG_${remote}_PROVIDER=${S3_PROVIDER}"
export "RCLONE_CONFIG_${remote}_ACCESS_KEY_ID=${S3_ACCESS_KEY_ID}"
export "RCLONE_CONFIG_${remote}_SECRET_ACCESS_KEY=${S3_SECRET_ACCESS_KEY}"
export "RCLONE_CONFIG_${remote}_ENDPOINT=${S3_ENDPOINT}"
export "RCLONE_CONFIG_${remote}_REGION=${S3_REGION}"
export "RCLONE_CONFIG_${remote}_ACL=${S3_ACL}"

# Generate Litestream configuration from template
# Substitutes environment variables like $S3_BUCKET, $S3_PREFIX, etc.
envsubst < /app/litestream.yml.tpl > /etc/litestream.yml

# Validate extra backup remotes (if backup is enabled)
if [ "${BACKUP_ENABLED:-false}" = "true" ] && [ -n "${BACKUP_EXTRA_REMOTES:-}" ]; then
  echo "[entrypoint] validating extra backup remotes..." >&2
  echo "$BACKUP_EXTRA_REMOTES" | tr ',' '\n' | while IFS= read -r remote_path; do
    remote_path=$(echo "$remote_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$remote_path" ] && continue
    remote="${remote_path%%:*}"
    if ! rclone config show "$remote" >/dev/null 2>&1; then
      echo "[entrypoint] WARNING: remote '$remote' is not configured" >&2
      echo "[entrypoint]   Make sure to set RCLONE_CONFIG_${remote}_TYPE and other required variables" >&2
    else
      echo "[entrypoint]   ✓ remote '$remote' configured" >&2
    fi
  done
fi

# Launch based on NODE_ROLE
role="${NODE_ROLE:-primary}"
case "$role" in
  primary)
    if [ "$DEPLOYMENT_MODE" = "serverless" ]; then
      echo "[entrypoint] NOTE: primary on serverless — set max-instances=1 to prevent concurrent writers" >&2
    fi
    echo "[entrypoint] launching primary (vaultwarden + litestream + rclone upload)..." >&2
    echo "[entrypoint] S3: ${S3_PROVIDER} ${S3_BUCKET}/${S3_PREFIX}" >&2
    echo "[entrypoint] sync interval: ${PRIMARY_SYNC_INTERVAL}s" >&2
    [ "${BACKUP_ENABLED:-false}" = "true" ] && echo "[entrypoint] backup interval: ${BACKUP_INTERVAL:-86400}s" >&2
    exec /app/primary.sh
    ;;
  secondary)
    if [ "$DEPLOYMENT_MODE" = "serverless" ]; then
      echo "[entrypoint] launching secondary (serverless — restore once, no periodic refresh)..." >&2
    else
      echo "[entrypoint] launching secondary (persistent — periodic refresh every ${SECONDARY_SYNC_INTERVAL}s)..." >&2
    fi
    echo "[entrypoint] S3: ${S3_PROVIDER} ${S3_BUCKET}/${S3_PREFIX}" >&2
    exec /app/secondary.sh
    ;;
  *)
    echo "[entrypoint] ERROR: NODE_ROLE must be primary or secondary (got: $role)" >&2
    exit 1
    ;;
esac
