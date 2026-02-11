# Stage 1: Litestream — SQLite replication engine
FROM litestream/litestream:latest AS litestream

# Stage 2: Tailscale — mesh VPN binaries
FROM tailscale/tailscale:latest AS tailscale

# Stage 3: Final image
FROM vaultwarden/server:latest

# OCI standard labels
LABEL org.opencontainers.image.title="Vaultwarden Stream"
LABEL org.opencontainers.image.description="Vaultwarden with S3 replication (Litestream), file sync (rclone), optional snapshots and Tailscale VPN"
LABEL org.opencontainers.image.url="https://github.com/garyellow/vaultwarden-stream"
LABEL org.opencontainers.image.source="https://github.com/garyellow/vaultwarden-stream"
LABEL org.opencontainers.image.licenses="MIT"

# Copy Litestream binary
COPY --from=litestream /usr/local/bin/litestream /usr/local/bin/litestream

# Copy Tailscale binaries (only started if TAILSCALE_ENABLED=true)
COPY --from=tailscale /usr/local/bin/tailscale /usr/local/bin/tailscale
COPY --from=tailscale /usr/local/bin/tailscaled /usr/local/bin/tailscaled

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        gettext-base \
        openssl \
        rclone \
        sqlite3 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Copy configuration template and scripts
COPY config/litestream.yml.tpl /app/litestream.yml.tpl
COPY --chmod=0755 scripts/ /app/

# Default environment variables (see .env.example for full docs)

# ── S3 Storage ───────────────────────────────────────────────────────────────
ENV S3_PREFIX=vaultwarden \
    S3_REGION=auto \
    S3_ACL=private \
    S3_NO_CHECK_BUCKET=true

# ── Deployment ───────────────────────────────────────────────────────────────
ENV NODE_ROLE=primary \
    DEPLOYMENT_MODE=persistent \
    PRIMARY_SYNC_INTERVAL=300 \
    SECONDARY_SYNC_INTERVAL=3600 \
    RCLONE_REMOTE_NAME=S3 \
    HEALTHCHECK_MAX_SYNC_AGE=600

# ── Litestream (Database Replication) ────────────────────────────────────────
ENV LITESTREAM_DB_PATH=/data/db.sqlite3 \
    LITESTREAM_SYNC_INTERVAL=1s \
    LITESTREAM_SNAPSHOT_INTERVAL=30m \
    LITESTREAM_RETENTION=24h \
    LITESTREAM_VALIDATION_INTERVAL= \
    LITESTREAM_SHUTDOWN_TIMEOUT=30 \
    LITESTREAM_FORCE_PATH_STYLE=false \
    LITESTREAM_SKIP_VERIFY=false

# ── Sync (File Replication) ──────────────────────────────────────────────────
ENV SYNC_INCLUDE_ATTACHMENTS=true \
    SYNC_INCLUDE_SENDS=true \
    SYNC_INCLUDE_CONFIG=true \
    SYNC_INCLUDE_ICON_CACHE=false \
    SYNC_SHUTDOWN_TIMEOUT=60

# ── Backup ───────────────────────────────────────────────────────────────────
ENV BACKUP_ENABLED=false \
    BACKUP_CRON="0 0 * * *" \
    BACKUP_FORMAT=tar.gz \
    BACKUP_RETENTION_DAYS=30 \
    BACKUP_MIN_KEEP=3 \
    BACKUP_INCLUDE_ATTACHMENTS=true \
    BACKUP_INCLUDE_SENDS=true \
    BACKUP_INCLUDE_CONFIG=true \
    BACKUP_INCLUDE_ICON_CACHE=false \
    BACKUP_ON_STARTUP=false \
    BACKUP_SHUTDOWN_TIMEOUT=180 \
    BACKUP_REMOTES=

# ── Notifications ────────────────────────────────────────────────────────────
ENV NOTIFICATION_URL= \
    NOTIFICATION_EVENTS= \
    NOTIFICATION_TIMEOUT=10

# ── Tailscale ────────────────────────────────────────────────────────────────
ENV TAILSCALE_ENABLED=false \
    TAILSCALE_HOSTNAME=vaultwarden \
    TAILSCALE_SERVE_PORT=80 \
    TAILSCALE_SERVE_MODE=https \
    TAILSCALE_FUNNEL=false

# ── Volatile Storage ─────────────────────────────────────────────────────────
ENV I_REALLY_WANT_VOLATILE_STORAGE=true

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD /app/healthcheck.sh

ENTRYPOINT ["/app/entrypoint.sh"]
