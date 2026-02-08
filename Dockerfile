# Stage 1: Get Litestream binary from official image
FROM litestream/litestream:latest AS litestream

# Stage 2: Build final image
FROM vaultwarden/server:latest

# OCI standard labels for better container metadata
LABEL org.opencontainers.image.title="Vaultwarden Stream"
LABEL org.opencontainers.image.description="Vaultwarden with automated S3 backup via Litestream and rclone"
LABEL org.opencontainers.image.url="https://github.com/garyellow/vaultwarden-stream"
LABEL org.opencontainers.image.source="https://github.com/garyellow/vaultwarden-stream"
LABEL org.opencontainers.image.licenses="MIT"

# Copy Litestream binary
COPY --from=litestream /usr/local/bin/litestream /usr/local/bin/litestream

# Install dependencies: envsubst, rclone, sqlite3
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        gettext-base \
        rclone \
        sqlite3 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Copy configuration and scripts
COPY config/litestream.yml.tpl /app/litestream.yml.tpl
COPY --chmod=0755 scripts/ /app/

# Default environment variables
ENV NODE_ROLE=primary \
    DEPLOYMENT_MODE=persistent \
    PRIMARY_SYNC_INTERVAL=300 \
    SECONDARY_SYNC_INTERVAL=3600 \
    LITESTREAM_DB_PATH=/data/db.sqlite3 \
    LITESTREAM_SYNC_INTERVAL=1s \
    LITESTREAM_SNAPSHOT_INTERVAL=30m \
    LITESTREAM_RETENTION=24h \
    LITESTREAM_SHUTDOWN_TIMEOUT=30 \
    BACKUP_SHUTDOWN_TIMEOUT=60 \
    RCLONE_REMOTE_NAME=S3 \
    S3_PREFIX=vaultwarden \
    S3_REGION=auto \
    S3_ACL=private \
    S3_NO_CHECK_BUCKET=true \
    HEALTHCHECK_SYNC_MAX_AGE=600 \
    BACKUP_ENABLED=false \
    BACKUP_INTERVAL=86400 \
    BACKUP_RETENTION_DAYS=30 \
    BACKUP_MIN_KEEP=3 \
    BACKUP_EXTRA_REMOTES=

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD /app/healthcheck.sh

ENTRYPOINT ["/app/entrypoint.sh"]
