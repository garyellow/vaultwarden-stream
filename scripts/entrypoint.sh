#!/bin/sh
set -eu

# ── Utility ───────────────────────────────────────────────────────────────

require_var() {
  eval "val=\${$1:-}"
  if [ -z "$val" ]; then
    echo "[entrypoint] ERROR: missing required env var: $1" >&2
    exit 1
  fi
}

validate_integer() {
  case "$2" in
    *[!0-9]*|"")
      echo "[entrypoint] ERROR: $1 must be a non-negative integer (got: $2)" >&2
      exit 1
      ;;
  esac
}

validate_boolean() {
  case "$2" in
    true|false) ;;
    *)
      echo "[entrypoint] ERROR: $1 must be true or false (got: $2)" >&2
      exit 1
      ;;
  esac
}

# Validate Litestream duration format (e.g., 1s, 30m, 24h)
validate_duration() {
  case "$2" in
    *[0-9]s|*[0-9]m|*[0-9]h)
      # Extract numeric part and validate
      _vd_num=$(echo "$2" | sed 's/[a-z]*$//')
      case "$_vd_num" in
        *[!0-9]*|"")
          echo "[entrypoint] ERROR: $1 has invalid duration format (got: $2)" >&2
          echo "[entrypoint]   Expected: <number><unit> (e.g., 1s, 30m, 24h)" >&2
          exit 1
          ;;
      esac
      ;;
    *)
      echo "[entrypoint] ERROR: $1 must be a duration with unit (1s, 30m, 24h, etc., got: $2)" >&2
      exit 1
      ;;
  esac
}

# Validate enum value
validate_enum() {
  _ve_var="$1"
  _ve_val="$2"
  shift 2
  for _ve_allowed in "$@"; do
    [ "$_ve_val" = "$_ve_allowed" ] && return 0
  done
  _ve_list=$(printf "%s" "$*" | sed 's/ /, /g')
  echo "[entrypoint] ERROR: $_ve_var must be one of: $_ve_list (got: $_ve_val)" >&2
  exit 1
}

# ── S3 validation ─────────────────────────────────────────────────────────

require_var S3_PROVIDER
require_var S3_BUCKET
require_var S3_ENDPOINT
require_var S3_ACCESS_KEY_ID
require_var S3_SECRET_ACCESS_KEY

# Normalize S3_PREFIX (strip leading/trailing/duplicate slashes)
S3_PREFIX=$(echo "$S3_PREFIX" | sed -e 's#^/*##' -e 's#/*$##' -e 's#//*#/#g')

# Validate S3 configuration
validate_boolean S3_NO_CHECK_BUCKET "$S3_NO_CHECK_BUCKET"
validate_enum S3_ACL "$S3_ACL" private public-read public-read-write authenticated-read bucket-owner-read bucket-owner-full-control

export S3_PREFIX S3_REGION S3_ACL S3_NO_CHECK_BUCKET

# ── Deployment validation ─────────────────────────────────────────────────

case "$NODE_ROLE" in
  primary|secondary) ;;
  *)
    echo "[entrypoint] ERROR: NODE_ROLE must be primary or secondary (got: $NODE_ROLE)" >&2
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

validate_integer PRIMARY_SYNC_INTERVAL "$PRIMARY_SYNC_INTERVAL"
validate_integer SECONDARY_SYNC_INTERVAL "$SECONDARY_SYNC_INTERVAL"

export NODE_ROLE DEPLOYMENT_MODE PRIMARY_SYNC_INTERVAL SECONDARY_SYNC_INTERVAL

# ── Litestream configuration ──────────────────────────────────────────────

# Compute LITESTREAM_REPLICA_PATH from S3_PREFIX (if not already set)
if [ -n "${S3_PREFIX}" ]; then
  : "${LITESTREAM_REPLICA_PATH:=${S3_PREFIX}/db.sqlite3}"
else
  : "${LITESTREAM_REPLICA_PATH:=db.sqlite3}"
fi

# Validate Litestream durations
validate_duration LITESTREAM_SYNC_INTERVAL "$LITESTREAM_SYNC_INTERVAL"
validate_duration LITESTREAM_SNAPSHOT_INTERVAL "$LITESTREAM_SNAPSHOT_INTERVAL"
validate_duration LITESTREAM_RETENTION "$LITESTREAM_RETENTION"

# Validate Litestream boolean flags
validate_boolean LITESTREAM_FORCE_PATH_STYLE "$LITESTREAM_FORCE_PATH_STYLE"
validate_boolean LITESTREAM_SKIP_VERIFY "$LITESTREAM_SKIP_VERIFY"

# Validate Litestream timeouts
validate_integer LITESTREAM_SHUTDOWN_TIMEOUT "$LITESTREAM_SHUTDOWN_TIMEOUT"
validate_integer HEALTHCHECK_MAX_SYNC_AGE "$HEALTHCHECK_MAX_SYNC_AGE"

export LITESTREAM_DB_PATH LITESTREAM_SYNC_INTERVAL LITESTREAM_SNAPSHOT_INTERVAL
export LITESTREAM_RETENTION LITESTREAM_REPLICA_PATH LITESTREAM_VALIDATION_INTERVAL
export LITESTREAM_SHUTDOWN_TIMEOUT LITESTREAM_FORCE_PATH_STYLE LITESTREAM_SKIP_VERIFY
export HEALTHCHECK_MAX_SYNC_AGE

# ── rclone configuration ─────────────────────────────────────────────────

case "$RCLONE_REMOTE_NAME" in
  *[!A-Za-z0-9_]*)
    echo "[entrypoint] ERROR: RCLONE_REMOTE_NAME must contain only letters, digits, and underscores" >&2
    exit 1
    ;;
esac
export RCLONE_REMOTE_NAME

export "RCLONE_CONFIG_${RCLONE_REMOTE_NAME}_TYPE=s3"
export "RCLONE_CONFIG_${RCLONE_REMOTE_NAME}_PROVIDER=${S3_PROVIDER}"
export "RCLONE_CONFIG_${RCLONE_REMOTE_NAME}_ACCESS_KEY_ID=${S3_ACCESS_KEY_ID}"
export "RCLONE_CONFIG_${RCLONE_REMOTE_NAME}_SECRET_ACCESS_KEY=${S3_SECRET_ACCESS_KEY}"
export "RCLONE_CONFIG_${RCLONE_REMOTE_NAME}_ENDPOINT=${S3_ENDPOINT}"
export "RCLONE_CONFIG_${RCLONE_REMOTE_NAME}_REGION=${S3_REGION}"
export "RCLONE_CONFIG_${RCLONE_REMOTE_NAME}_ACL=${S3_ACL}"
export "RCLONE_CONFIG_${RCLONE_REMOTE_NAME}_NO_CHECK_BUCKET=${S3_NO_CHECK_BUCKET}"

# ── Litestream config generation ──────────────────────────────────────────

envsubst < /app/litestream.yml.tpl > /etc/litestream.yml

# Drop empty optional fields to keep YAML valid.
# (Litestream disables validation by default; leaving an empty value can break parsing.)
tmp_litestream_yml="/tmp/litestream.yml.$$"
grep -v '^[[:space:]]*validation-interval:[[:space:]]*$' /etc/litestream.yml > "$tmp_litestream_yml"
mv "$tmp_litestream_yml" /etc/litestream.yml

# ── Sync validation ───────────────────────────────────────────────────────

for flag in SYNC_INCLUDE_ATTACHMENTS SYNC_INCLUDE_SENDS SYNC_INCLUDE_CONFIG SYNC_INCLUDE_ICON_CACHE; do
  eval "val=\${${flag}}"
  validate_boolean "$flag" "$val"
  export "$flag=$val"
done

validate_integer SYNC_SHUTDOWN_TIMEOUT "$SYNC_SHUTDOWN_TIMEOUT"
export SYNC_SHUTDOWN_TIMEOUT

# ── Backup validation ─────────────────────────────────────────────────────

validate_boolean BACKUP_ENABLED "$BACKUP_ENABLED"

if [ "$BACKUP_ENABLED" = "true" ]; then
  cron_field_count=$(echo "$BACKUP_CRON" | awk '{print NF}')
  if [ "$cron_field_count" -ne 5 ]; then
    echo "[entrypoint] ERROR: BACKUP_CRON must be a 5-field cron expression (got ${cron_field_count} fields): ${BACKUP_CRON}" >&2
    exit 1
  fi
  export BACKUP_CRON

  # Validate BACKUP_INCLUDE_* flags
  for flag in BACKUP_INCLUDE_ATTACHMENTS BACKUP_INCLUDE_SENDS BACKUP_INCLUDE_CONFIG BACKUP_INCLUDE_ICON_CACHE; do
    eval "val=\${${flag}}"
    validate_boolean "$flag" "$val"
    export "$flag=$val"
  done

  validate_integer BACKUP_RETENTION_DAYS "$BACKUP_RETENTION_DAYS"
  validate_integer BACKUP_MIN_KEEP "$BACKUP_MIN_KEEP"
  validate_integer BACKUP_SHUTDOWN_TIMEOUT "$BACKUP_SHUTDOWN_TIMEOUT"
  export BACKUP_RETENTION_DAYS BACKUP_MIN_KEEP BACKUP_SHUTDOWN_TIMEOUT

  # Validate backup format
  case "$BACKUP_FORMAT" in
    tar.gz|tar) ;;
    *)
      echo "[entrypoint] ERROR: BACKUP_FORMAT must be tar.gz or tar (got: $BACKUP_FORMAT)" >&2
      exit 1
      ;;
  esac
  export BACKUP_FORMAT

  # Validate BACKUP_ON_STARTUP
  validate_boolean BACKUP_ON_STARTUP "$BACKUP_ON_STARTUP"
  export BACKUP_ON_STARTUP

  # Validate encryption password (if set)
  if [ -n "${BACKUP_PASSWORD:-}" ]; then
    if [ "$BACKUP_FORMAT" = "tar" ]; then
      echo "[entrypoint] ERROR: BACKUP_PASSWORD requires BACKUP_FORMAT=tar.gz" >&2
      exit 1
    fi
    if ! command -v openssl >/dev/null 2>&1; then
      echo "[entrypoint] ERROR: encryption requires 'openssl'" >&2
      exit 1
    fi
    echo "[entrypoint] backup encryption: enabled" >&2
    export BACKUP_PASSWORD
  fi

  # Require at least one backup destination
  if [ -z "${BACKUP_REMOTES:-}" ]; then
    echo "[entrypoint] ERROR: BACKUP_ENABLED=true but BACKUP_REMOTES is not set" >&2
    echo "[entrypoint]   Example: BACKUP_REMOTES=S3:my-bucket/backups" >&2
    exit 1
  fi

  # Validate configured remotes (via env vars; may not exist in rclone config file)
  echo "[entrypoint] validating backup remotes..." >&2
  _remotes_remaining="$BACKUP_REMOTES"
  while [ -n "$_remotes_remaining" ]; do
    case "$_remotes_remaining" in
      *,*) remote_path="${_remotes_remaining%%,*}"; _remotes_remaining="${_remotes_remaining#*,}" ;;
      *)   remote_path="$_remotes_remaining"; _remotes_remaining="" ;;
    esac
    remote_path=$(echo "$remote_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$remote_path" ] && continue
    case "$remote_path" in
      *:*) ;;
      *)
        echo "[entrypoint] ERROR: invalid BACKUP_REMOTES entry (missing ':'): $remote_path" >&2
        exit 1
        ;;
    esac
    remote_name="${remote_path%%:*}"
    eval "remote_type=\${RCLONE_CONFIG_${remote_name}_TYPE:-}"
    if [ -z "$remote_type" ]; then
      echo "[entrypoint] WARNING: remote '$remote_name' is not configured via env vars" >&2
      echo "[entrypoint]   Set RCLONE_CONFIG_${remote_name}_TYPE and other required variables" >&2
    else
      echo "[entrypoint]   ✓ remote '$remote_name' configured (type=${remote_type})" >&2
    fi
  done
fi

# ── Notification validation ─────────────────────────────────────────

if [ -n "${NOTIFICATION_URL:-}" ]; then
  validate_integer NOTIFICATION_TIMEOUT "$NOTIFICATION_TIMEOUT"
  if [ -n "$NOTIFICATION_EVENTS" ]; then
    NOTIFICATION_EVENTS=$(echo "$NOTIFICATION_EVENTS" | tr -d '[:space:]')
  fi
  export NOTIFICATION_URL NOTIFICATION_EVENTS NOTIFICATION_TIMEOUT
  _events_display="all"
  if [ -n "$NOTIFICATION_EVENTS" ]; then
    _events_display="$NOTIFICATION_EVENTS"
  fi
  echo "[entrypoint] notifications: enabled (events: $_events_display)" >&2
fi

# ── rclone advanced ────────────────────────────────────────────

if [ -n "${RCLONE_FLAGS:-}" ]; then
  echo "[entrypoint] rclone: custom flags enabled: ${RCLONE_FLAGS}" >&2
  export RCLONE_FLAGS
fi

# ── Tailscale validation ─────────────────────────────────────────────────

validate_boolean TAILSCALE_ENABLED "$TAILSCALE_ENABLED"

if [ "$TAILSCALE_ENABLED" = "true" ]; then
  # Validate all Tailscale configuration when enabled
  validate_boolean TAILSCALE_FUNNEL "$TAILSCALE_FUNNEL"
  validate_integer TAILSCALE_SERVE_PORT "$TAILSCALE_SERVE_PORT"
  validate_enum TAILSCALE_SERVE_MODE "$TAILSCALE_SERVE_MODE" https tls-terminated-tcp

  if ! command -v tailscale >/dev/null 2>&1; then
    echo "[entrypoint] ERROR: TAILSCALE_ENABLED=true but tailscale binary not found" >&2
    exit 1
  fi

  if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
    echo "[entrypoint] ERROR: TAILSCALE_ENABLED=true requires TAILSCALE_AUTHKEY for unattended startup" >&2
    exit 1
  fi

  if [ -n "${TAILSCALE_TAGS:-}" ]; then
    # Strip spaces around commas and validate each tag starts with "tag:"
    TAILSCALE_TAGS=$(echo "$TAILSCALE_TAGS" | tr -d '[:space:]')
    _tags_remaining="$TAILSCALE_TAGS"
    while [ -n "$_tags_remaining" ]; do
      case "$_tags_remaining" in
        *,*) _tag="${_tags_remaining%%,*}"; _tags_remaining="${_tags_remaining#*,}" ;;
        *)   _tag="$_tags_remaining"; _tags_remaining="" ;;
      esac
      case "$_tag" in
        tag:*) ;;
        *)
          echo "[entrypoint] ERROR: TAILSCALE_TAGS entries must start with 'tag:' (got: $_tag)" >&2
          exit 1
          ;;
      esac
    done
    export TAILSCALE_TAGS
  fi
fi

# ── Start Tailscale (if enabled) ──────────────────────────────────────────

. /app/tailscale.sh
tailscale_start

# ── Dispatch to role script ──────────────────────────────────────────────

case "$NODE_ROLE" in
  primary)
    if [ "$DEPLOYMENT_MODE" = "serverless" ]; then
      echo "[entrypoint] NOTE: primary on serverless — ensure max-instances=1 to prevent concurrent writers" >&2
    fi
    echo "[entrypoint] launching primary (vaultwarden + litestream + rclone)" >&2
    echo "[entrypoint] S3: ${S3_PROVIDER} ${S3_BUCKET}/${S3_PREFIX}" >&2
    echo "[entrypoint] file sync interval: ${PRIMARY_SYNC_INTERVAL}s" >&2
    if [ "$BACKUP_ENABLED" = "true" ]; then
      echo "[entrypoint] backup: ${BACKUP_CRON} ($BACKUP_FORMAT)" >&2
      [ "$BACKUP_ON_STARTUP" = "true" ] && echo "[entrypoint]   - startup backup: enabled" >&2
      [ -n "${NOTIFICATION_URL:-}" ] && echo "[entrypoint]   - notifications: enabled" >&2
    fi
    if [ -n "${NOTIFICATION_URL:-}" ] && [ "$BACKUP_ENABLED" = "false" ]; then
      if [ -n "${NOTIFICATION_EVENTS:-}" ]; then
        echo "[entrypoint] notifications: sync events only" >&2
      else
        echo "[entrypoint] notifications: all events" >&2
      fi
    fi
    [ "$TAILSCALE_ENABLED" = "true" ] && echo "[entrypoint] tailscale: enabled" >&2
    exec /app/primary.sh
    ;;
  secondary)
    if [ "$DEPLOYMENT_MODE" = "serverless" ]; then
      echo "[entrypoint] launching secondary (serverless — restore once, no periodic refresh)" >&2
    else
      echo "[entrypoint] launching secondary (persistent — refresh every ${SECONDARY_SYNC_INTERVAL}s)" >&2
    fi
    echo "[entrypoint] S3: ${S3_PROVIDER} ${S3_BUCKET}/${S3_PREFIX}" >&2
    [ "$TAILSCALE_ENABLED" = "true" ] && echo "[entrypoint] tailscale: enabled" >&2
    exec /app/secondary.sh
    ;;
esac
