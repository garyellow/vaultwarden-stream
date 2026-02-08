FROM vaultwarden/server:latest

# Install runtime dependencies and Litestream
# - gettext-base: envsubst for rendering litestream.yml template
# - rclone: S3-compatible file sync for attachments/sends
# - wget: used only during build to download Litestream (removed after)
# Note: ca-certificates and curl are already included in the base image
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        gettext-base \
        rclone \
        wget && \
    wget -qO- "https://github.com/benbjohnson/litestream/releases/latest/download/litestream-linux-$(dpkg --print-architecture).tar.gz" | \
        tar -xz -C /usr/local/bin && \
    apt-get purge -y wget && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

# Copy scripts and configuration
COPY --chmod=0755 scripts/ /app/
COPY config/litestream.yml.tpl /app/litestream.yml.tpl

# Default environment variables (all can be overridden at runtime via
# docker run -e, docker-compose environment:, or .env files)
ENV NODE_ROLE=primary \
    DEPLOYMENT_MODE=persistent \
    PRIMARY_SYNC_INTERVAL=300 \
    SECONDARY_SYNC_INTERVAL=3600 \
    LITESTREAM_DB_PATH=/data/db.sqlite3 \
    LITESTREAM_SYNC_INTERVAL=1s \
    LITESTREAM_SNAPSHOT_INTERVAL=30m \
    LITESTREAM_RETENTION=24h \
    RCLONE_REMOTE_NAME=S3 \
    S3_PREFIX=vaultwarden \
    S3_REGION=auto \
    S3_ACL=private \
    HEALTHCHECK_SYNC_MAX_AGE=600

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD /app/healthcheck.sh

ENTRYPOINT ["/app/entrypoint.sh"]
