FROM alpine:latest AS fetcher
RUN apk add --no-cache ca-certificates wget tar && \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64) arch="amd64" ;; \
      aarch64) arch="arm64" ;; \
    esac; \
    version="$(wget -qO- https://api.github.com/repos/benbjohnson/litestream/releases/latest | \
      grep -m1 '"tag_name"' | sed -E 's/.*"v?([^\"]+)".*/\1/')"; \
    test -n "$version"; \
    wget -q "https://github.com/benbjohnson/litestream/releases/download/v${version}/litestream-v${version}-linux-${arch}.tar.gz" -O /tmp/litestream.tar.gz && \
    tar -xzf /tmp/litestream.tar.gz -C /tmp && \
    mv /tmp/litestream /litestream

FROM vaultwarden/server:latest-alpine

# Install runtime dependencies
RUN apk add --no-cache ca-certificates curl gettext rclone sqlite tzdata

# Copy binary and scripts
COPY --from=fetcher /litestream /usr/bin/litestream
COPY --chmod=0755 scripts/ /app/
COPY config/litestream.yml.tpl /app/litestream.yml.tpl

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
    HEALTHCHECK_SYNC_MAX_AGE=600

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD /app/healthcheck.sh

ENTRYPOINT ["/app/entrypoint.sh"]
