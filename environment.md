# Environment Variables

All configuration is via environment variables. See [.env.example](.env.example) for inline documentation.

For Vaultwarden-specific options, refer to the [Vaultwarden Wiki](https://github.com/dani-garcia/vaultwarden/wiki).

## S3 Storage

Used by Litestream (database replication) and rclone (file sync). All fields are required unless noted.

| Variable | Default | Description |
|----------|---------|-------------|
| `S3_PROVIDER` | — | S3 provider ([rclone list](https://rclone.org/s3/#s3-provider)) |
| `S3_BUCKET` | — | Bucket name |
| `S3_ENDPOINT` | — | S3 endpoint URL |
| `S3_ACCESS_KEY_ID` | — | Access key |
| `S3_SECRET_ACCESS_KEY` | — | Secret key |
| `S3_PREFIX` | `vaultwarden` | Path prefix inside the bucket |
| `S3_REGION` | `auto` | S3 region |
| `S3_ACL` | `private` | Object ACL |
| `S3_NO_CHECK_BUCKET` | `true` | Skip bucket existence check |

## Deployment

| Variable | Default | Description |
|----------|---------|-------------|
| `NODE_ROLE` | `primary` | `primary` (read/write) or `secondary` (read-only DR) |
| `DEPLOYMENT_MODE` | `persistent` | `persistent` (always-on) or `serverless` (scale-to-zero) |
| `PRIMARY_SYNC_INTERVAL` | `300` | File upload interval in seconds (primary only) |
| `SECONDARY_SYNC_INTERVAL` | `3600` | Data refresh interval in seconds (secondary only) |
| `RCLONE_REMOTE_NAME` | `S3` | rclone remote name |
| `HEALTHCHECK_MAX_SYNC_AGE` | `600` | Max seconds since last sync before unhealthy |

### Deployment Modes

| Mode | Description | Best For |
|------|-------------|----------|
| `primary` + `persistent` | Always-on main instance | **Recommended for most users** |
| `primary` + `serverless` | Scales to zero when idle | Low-traffic deployments |
| `secondary` + `persistent` | Always-on read-only DR standby | High availability |
| `secondary` + `serverless` | On-demand read-only DR standby | Cost-optimized DR |

### Serverless

For scale-to-zero platforms, set `DEPLOYMENT_MODE=serverless`. Requirements:
- `max-instances: 1` (SQLite requires single writer)
- `stop_grace_period: 120s`
- `ENABLE_WEBSOCKET=false` (allows scale-to-zero)
- `BACKUP_ENABLED=false` (cron prevents scale-to-zero)

## Litestream (Database Replication)

> **Documentation:** [Litestream Configuration Reference](https://litestream.io/reference/config/)

| Variable | Default | Description |
|----------|---------|-------------|
| `LITESTREAM_SYNC_INTERVAL` | `1s` | WAL replication interval (data loss window) |
| `LITESTREAM_SNAPSHOT_INTERVAL` | `30m` | Full snapshot creation interval |
| `LITESTREAM_RETENTION` | `24h` | Snapshot/WAL retention period |
| `LITESTREAM_VALIDATION_INTERVAL` | — | Automatic replica validation (non-functional in v0.5.x) |
| `LITESTREAM_DB_PATH` | `/data/db.sqlite3` | Local database file path |
| `LITESTREAM_REPLICA_PATH` | `<S3_PREFIX>/db.sqlite3` | S3 replica path (auto-derived) |
| `LITESTREAM_SHUTDOWN_TIMEOUT` | `30` | Seconds to flush WAL before forced shutdown |
| `LITESTREAM_FORCE_PATH_STYLE` | `false` | Path-style S3 URLs (required for MinIO, Ceph) |
| `LITESTREAM_SKIP_VERIFY` | `false` | Skip TLS certificate verification |

## Backup (Optional)

Scheduled tar archives with retention and multi-destination support.

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_ENABLED` | `false` | Enable scheduled backups |
| `BACKUP_CRON` | `0 0 * * *` | Cron schedule ([editor](https://crontab.guru/)) |
| `BACKUP_FORMAT` | `tar.gz` | `tar.gz` (compressed, supports encryption) or `tar` (uncompressed, faster) |
| `BACKUP_PASSWORD` | — | Encryption password (requires `tar.gz` format) |
| `BACKUP_REMOTES` | — | Remote destinations, comma-separated |
| `BACKUP_RETENTION_DAYS` | `30` | Delete backups older than N days |
| `BACKUP_MIN_KEEP` | `3` | Always keep at least N recent backups |
| `BACKUP_INCLUDE_ATTACHMENTS` | `true` | Include attachments |
| `BACKUP_INCLUDE_SENDS` | `true` | Include sends |
| `BACKUP_INCLUDE_CONFIG` | `true` | Include RSA keys and config.json |
| `BACKUP_INCLUDE_ICON_CACHE` | `false` | Include icon cache (icons can be re-fetched) |
| `BACKUP_ON_STARTUP` | `false` | Run backup immediately on startup |
| `BACKUP_SHUTDOWN_TIMEOUT` | `60` | Seconds to wait for in-progress backup |

### Multi-Destination

Replicate to additional remotes ([rclone docs](https://rclone.org/docs/#configure-remotes-with-environment-variables)):

```bash
RCLONE_CONFIG_GDRIVE_TYPE=drive
RCLONE_CONFIG_GDRIVE_TOKEN={"access_token":"...", "refresh_token":"..."}
BACKUP_REMOTES=S3:my-bucket/vw-backups, GDRIVE:vw-backup
```

### Backup on Startup

Run backup immediately on container start:

```bash
BACKUP_ENABLED=true
BACKUP_ON_STARTUP=true
BACKUP_REMOTES=S3:my-bucket/vw-backups
```

### Restore from Backup

```bash
# tar.gz (compressed)
tar -xzf vaultwarden-*.tar.gz -C /data

# tar (uncompressed)
tar -xf vaultwarden-*.tar -C /data

# Encrypted (will prompt for password)
openssl enc -d -aes-256-cbc -pbkdf2 -in vaultwarden-*.tar.gz.enc | tar -xz -C /data
```

## Notifications (Optional)

HTTP ping notifications for monitoring backup and sync operations.

| Variable | Default | Description |
|----------|---------|-------------|
| `NOTIFICATION_URL` | — | HTTP ping URL for monitoring events |
| `NOTIFICATION_EVENTS` | — | Events to notify (comma-separated)<br>Leave empty to notify on all events |
| `NOTIFICATION_TIMEOUT` | `10` | curl timeout in seconds for notification requests |

**Notification endpoints:**
- **Success**: `GET $NOTIFICATION_URL` (backup_success)
- **Failure**: `GET $NOTIFICATION_URL/fail` (backup_failure, sync_error)

**Supported events:**
- `backup_success` — Scheduled backup completed successfully
- `backup_failure` — Scheduled backup failed
- `sync_error` — File sync operation failed (primary upload or secondary download)

## Advanced

> **rclone documentation:** [Rclone Docs](https://rclone.org/docs/)

| Variable | Default | Description |
|----------|---------|-------------|
| `RCLONE_FLAGS` | — | Additional rclone flags for all operations<br>Example: `--transfers 16 --checkers 32` |

## Tailscale (Optional)

> **Documentation:** [Tailscale CLI Reference](https://tailscale.com/kb/1080/cli)

| Variable | Default | Description |
|----------|---------|-------------|
| `TAILSCALE_ENABLED` | `false` | Enable Tailscale mesh VPN |
| `TAILSCALE_AUTHKEY` | — | Auth key or OAuth client secret for node registration |
| `TAILSCALE_HOSTNAME` | `vaultwarden` | Node hostname on the tailnet |
| `TAILSCALE_LOGIN_SERVER` | — | Custom control server URL (for [Headscale](https://github.com/juanfont/headscale)) |
| `TAILSCALE_TAGS` | — | ACL tags, comma-separated (e.g. `tag:container`) |
| `TAILSCALE_SERVE_PORT` | `80` | Local port to expose via Tailscale Serve |
| `TAILSCALE_SERVE_MODE` | `https` | Serve protocol (`https`, `tls-terminated-tcp`) |
| `TAILSCALE_FUNNEL` | `false` | Expose to the **public internet** via Tailscale Funnel |
| `TAILSCALE_EXTRA_ARGS` | — | Additional `tailscale up` flags |

### Usage Examples

```bash
# Basic — private tailnet access (ephemeral by default with OAuth keys)
TAILSCALE_ENABLED=true
TAILSCALE_AUTHKEY=tskey-client-xxxxx
TAILSCALE_TAGS=tag:container

# HTTPS via Serve (auto TLS)
TAILSCALE_SERVE_PORT=80
# -> https://vaultwarden.<tailnet>.ts.net

# Public via Funnel (requires ACL policy)
TAILSCALE_FUNNEL=true

# Self-hosted with Headscale
TAILSCALE_LOGIN_SERVER=https://headscale.example.com
```

OAuth client secrets (`tskey-client-*`) are ephemeral by default — removed on container stop.
