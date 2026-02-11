# Environment Variables

All configuration is via environment variables. See [.env.example](.env.example) for inline documentation.

For Vaultwarden-specific options, refer to the [Vaultwarden Wiki](https://github.com/dani-garcia/vaultwarden/wiki).

## S3 Storage

Required. Used by Litestream (database replication) and rclone (tar-based file sync).

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

### S3 Object Structure

Files are packed into uncompressed tar archives before upload (reducing API calls from N to 4):

```
<bucket>/<S3_PREFIX>/
├── db.sqlite3/                              # Litestream WAL + snapshots (managed automatically)
├── attachments.tar                          # Vault attachments
├── sends.tar                                # Vault sends
├── config.tar                               # RSA keys + config.json
└── icon_cache.tar                           # Favicon cache (regenerable)

# Optional scheduled backups (requires BACKUP_ENABLED=true + BACKUP_REMOTES configuration)
<custom-backup-path>/
└── vaultwarden-YYYYMMDD-HHMMSS.tar.gz      # Snapshot backup (tar.gz, tar, or tar.gz.enc)
    └── db.sqlite3                           # Database snapshot
    └── attachments/                         # Vault attachments (configurable)
    └── sends/                               # Vault sends (configurable)
    └── config files                         # RSA keys + config.json (configurable)
    └── icon_cache/                          # Favicon cache (optional, configurable)
```

**Notes:**
- **Sync files**: Only uploaded when content changes (md5 hash comparison)
- **Backup destination**: Determined by `BACKUP_REMOTES` (e.g., `S3:my-bucket/backups`)
- **Backup filename**: `vaultwarden-YYYYMMDD-HHMMSS.[tar.gz|tar|tar.gz.enc]`
- **Storage location**: User-specified path in `BACKUP_REMOTES`, can be on S3 or other remotes

## Deployment

| Variable | Default | Description |
|----------|---------|-------------|
| `NODE_ROLE` | `primary` | `primary` (read/write) or `secondary` (read-only DR) |
| `DEPLOYMENT_MODE` | `persistent` | `persistent` (always-on) or `serverless` (scale-to-zero) |
| `PRIMARY_SYNC_INTERVAL` | `300` | File sync interval in seconds (primary) |
| `SECONDARY_SYNC_INTERVAL` | `3600` | Data refresh interval in seconds (secondary) |
| `FINAL_UPLOAD_TIMEOUT` | `60` | Seconds to wait for sync upload during shutdown |
| `RCLONE_REMOTE_NAME` | `S3` | rclone remote name |
| `HEALTHCHECK_MAX_SYNC_AGE` | `600` | Max seconds since last sync before unhealthy |

### Deployment Modes

| Mode | Description | Best For |
|------|-------------|----------|
| `primary` + `persistent` | Always-on main instance | **Recommended for most users** |
| `primary` + `serverless` | Scales to zero when idle | Low-traffic deployments |
| `secondary` + `persistent` | Always-on read-only DR standby | High availability |
| `secondary` + `serverless` | On-demand read-only DR standby | Cost-optimized DR |

### Serverless Deployments

For scale-to-zero platforms, set `DEPLOYMENT_MODE=serverless`.

**Requirements:**
- `max-instances: 1` (SQLite requires single writer)
- `stop_grace_period: 120s`
- `ENABLE_WEBSOCKET=false` (allows scale-to-zero)
- `BACKUP_ENABLED=false` (cron prevents scale-to-zero)

**Note:** This image sets `I_REALLY_WANT_VOLATILE_STORAGE=true` by default (a Vaultwarden safety flag). Since all data is replicated to S3 via Litestream and rclone, volatile local storage is acceptable in serverless deployments.

## Litestream (Database Replication)

Continuous SQLite replication to S3 via write-ahead log (WAL) streaming.

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
| `BACKUP_SHUTDOWN_TIMEOUT` | `180` | Seconds to wait for in-progress backup |

### Graceful Shutdown Budget

Steps 2, 3, 5 run in parallel. Step 4 waits for Step 3 completion.

**Performance optimizations implemented:**
- **Startup:** Database restore + file download run in parallel (2× faster cold start)
- **Sync upload:** Parallelizes attachments, sends, and config (3× faster)
- **Sync download:** Parallelizes all tar extractions (4× faster)
- **Backup file copy:** Parallelizes attachments, sends, and icon_cache (3× faster)
- **Backup upload:** Parallelizes multiple remotes (N× faster)
- **Backup cleanup:** Parallelizes all remotes (N× faster)
- **Secondary refresh:** Database restore + file download run in parallel (2× faster)

| Step | Env Var | Default | Typical | Notes |
|------|---------|---------|---------|-------|
| 1. Stop sync loop | — | <1s | <1s | Immediate |
| 2. Wait snapshot backup | `BACKUP_SHUTDOWN_TIMEOUT` | 180s | 0–60s | Only if backup in progress, **parallelized copies** |
| 3. Flush Litestream WAL | `LITESTREAM_SHUTDOWN_TIMEOUT` | 30s | 2–10s | Sequential: stop app → flush WAL |
| 4. Sync upload | `FINAL_UPLOAD_TIMEOUT` | 60s | 5–20s | **Parallelized** (was 5–30s) |
| 5. Stop Tailscale | — | 15s | 2–5s | Has internal timeouts |

**Worst case:** `max(180, 30+60, 15)` = **180s**

**Total timeout** (`stop_grace_period` in docker-compose.yml) should be at least 60s more than worst case. Default **300s (5 minutes)** provides ample buffer and clean round number.

If you need to increase timeout values further, adjust `stop_grace_period` accordingly:
```
stop_grace_period ≥ max(BACKUP_SHUTDOWN_TIMEOUT,
                        LITESTREAM_SHUTDOWN_TIMEOUT + FINAL_UPLOAD_TIMEOUT) + 60s buffer

Recommended: Use round numbers (300s = 5min, 600s = 10min) for easier management.
```

### Usage Examples

**Single destination:**
```bash
BACKUP_ENABLED=true
BACKUP_REMOTES=S3:my-bucket/backups
```

**Multiple destinations:**

Upload to multiple remotes using rclone ([rclone docs](https://rclone.org/docs/#configure-remotes-with-environment-variables)):

```bash
# Configure Google Drive remote via environment variables
RCLONE_CONFIG_GDRIVE_TYPE=drive
RCLONE_CONFIG_GDRIVE_TOKEN={"access_token":"...", "refresh_token":"..."}

# Upload to both S3 and Google Drive
BACKUP_REMOTES=S3:my-bucket/vw-backups, GDRIVE:vw-backup
```

**Run backup on startup:**

Execute immediately on container start (in addition to scheduled backups):

```bash
BACKUP_ENABLED=true
BACKUP_ON_STARTUP=true
BACKUP_REMOTES=S3:my-bucket/vw-backups
```

### Restore Procedure

To restore from a backup archive:

```bash
# Compressed (tar.gz)
tar -xzf vaultwarden-20260211-120000.tar.gz -C /data

# Uncompressed (tar)
tar -xf vaultwarden-20260211-120000.tar -C /data

# Encrypted (tar.gz.enc) — prompts for password
openssl enc -d -aes-256-cbc -pbkdf2 -in vaultwarden-20260211-120000.tar.gz.enc | tar -xz -C /data
```

## Notifications (Optional)

HTTP ping endpoints for monitoring backup and sync operations via external monitoring services.

| Variable | Default | Description |
|----------|---------|-------------|
| `NOTIFICATION_URL` | — | Base HTTP(S) URL for notifications |
| `NOTIFICATION_EVENTS` | — | Events to notify (comma-separated)<br>Leave empty to notify on all events |
| `NOTIFICATION_TIMEOUT` | `10` | HTTP request timeout in seconds |

### Protocol

Uses standard HTTP GET requests:

**Success:**
```bash
GET $NOTIFICATION_URL
```

**Failure:**
```bash
GET $NOTIFICATION_URL/fail
```

### Supported Events

| Event | When | Endpoint |
|-------|------|----------|
| `backup_success` | Scheduled backup completed | `$NOTIFICATION_URL` |
| `backup_failure` | Scheduled backup failed | `$NOTIFICATION_URL/fail` |
| `sync_error` | File sync failed (upload/download) | `$NOTIFICATION_URL/fail` |

### Usage

**Basic configuration:**
```bash
NOTIFICATION_URL=https://your-monitoring-service.com/ping/YOUR_ID
```

**Filter specific events:**
```bash
NOTIFICATION_URL=https://your-monitoring-service.com/ping/YOUR_ID
NOTIFICATION_EVENTS=backup_success,backup_failure
```

**Note:** Notifications are best-effort only and never block backup/sync operations.

## Advanced Options

Additional configuration for rclone operations.

> **Documentation:** [Rclone Docs](https://rclone.org/docs/)

| Variable | Default | Description |
|----------|---------|-------------|
| `RCLONE_FLAGS` | — | Additional rclone flags for all operations<br>Example: `--transfers 16 --checkers 32` |

## Tailscale (Optional)

Mesh VPN for private access. Compatible with Tailscale cloud and self-hosted Headscale.

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

**Basic private network:**
```bash
TAILSCALE_ENABLED=true
TAILSCALE_AUTHKEY=tskey-client-xxxxx
TAILSCALE_TAGS=tag:container
```
Access via private tailnet only.

**With HTTPS (Tailscale Serve):**
```bash
TAILSCALE_ENABLED=true
TAILSCALE_AUTHKEY=tskey-client-xxxxx
TAILSCALE_SERVE_PORT=80
```
Accessible at: `https://vaultwarden.<tailnet>.ts.net` (automatic TLS).

**Public internet (Tailscale Funnel):**
```bash
TAILSCALE_ENABLED=true
TAILSCALE_AUTHKEY=tskey-client-xxxxx
TAILSCALE_SERVE_PORT=80
TAILSCALE_FUNNEL=true
```
Requires ACL policy allowing Funnel.

**Self-hosted (Headscale):**
```bash
TAILSCALE_ENABLED=true
TAILSCALE_AUTHKEY=your-headscale-key
TAILSCALE_LOGIN_SERVER=https://headscale.example.com
```

**Note:** Containers execute `tailscale logout` on shutdown to ensure consistent DNS URLs across restarts.
