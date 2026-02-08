# Vaultwarden Stream

Vaultwarden with automated S3 backup — integrates [Litestream](https://litestream.io/) for real-time database replication and [rclone](https://rclone.org/) for file sync. Supports any S3-compatible storage (Cloudflare R2, AWS S3, MinIO, Backblaze B2, etc.).

## Features

- 🔄 **Real-time database backup** — Litestream continuously replicates SQLite to S3
- 📦 **Stateless deployment** — All data restored from S3 on startup
- 🌐 **Serverless ready** — Scale-to-zero capable on Cloud Run, Fly.io, etc.
- 🔐 **Session preservation** — RSA keys synced across restarts
- 🛡️ **Disaster recovery** — Deploy secondary read-only standby on different platform
- ☁️ **S3-compatible** — Works with any S3-compatible storage provider

## Architecture

```
┌─────────────────────────────────────────────────┐
│  PRIMARY Container                              │
│                                                 │
│  ┌───────────┐    ┌────────────┐                │
│  │Vaultwarden│───▶│ db.sqlite3 │                │
│  └───────────┘    └─────┬──────┘                │
│                         │ WAL replication       │
│                   ┌─────▼──────┐                │
│                   │ Litestream │─────────┐      │
│                   └────────────┘         │      │
│                                          │      │
│  ┌─────────────────────┐                 │      │
│  │ rclone (upload ↑)   │──────────┐      │      │
│  │ attachments/sends/  │          │      │      │
│  │ rsa_key/config.json │          │      │      │
│  └─────────────────────┘          │      │      │
└───────────────────────────────────┼──────┼──────┘
                                    │      │
                             ┌──────▼──────▼──────┐
                             │  S3-Compatible     │
                             │  Object Storage    │
                             └──────┬──────┬──────┘
                                    │      │
┌───────────────────────────────────┼──────┼──────┐
│  SECONDARY Container (DR)         │      │      │
│                                   │      │      │
│  ┌─────────────────────┐          │      │      │
│  │ rclone (download ↓) │◀─────────┘      │      │
│  └─────────┬───────────┘                 │      │
│            │                             │      │
│  ┌─────────▼──┐    ┌────────────┐        │      │
│  │Vaultwarden │───▶│ db.sqlite3 │◀───────┘      │
│  │ (standby)  │    │ (snapshot) │  restore      │
│  └────────────┘    └────────────┘  on startup   │
└─────────────────────────────────────────────────┘
```

### Modes

| Mode | Description |
|------|-------------|
| **primary** | Main instance with real-time backup to S3. Use for production. |
| **secondary** | Read-only standby that pulls from S3. Use for disaster recovery on a different platform. |

### What Gets Backed Up

| Component | Backup Method |
|-----------|---------------|
| Database (`db.sqlite3`) | **Litestream** — real-time replication to S3 |
| Files (`attachments/`, `sends/`) | **rclone** — periodic sync to S3 (default: every 5 min) |
| Keys & Config | **rclone** — synced with files |

## Quick Start

### 1. Configure S3

Create a bucket in any S3-compatible provider and obtain credentials.

<details>
<summary><b>Cloudflare R2 Setup</b></summary>

1. Create R2 bucket: [Cloudflare Dashboard](https://dash.cloudflare.com/) → R2 → Create bucket
2. Generate API token: R2 → Manage R2 API Tokens → Create API Token
3. Note your Account ID (visible in R2 overview)

</details>

### 2. Deploy with Docker Compose

```bash
# Copy and edit config
cp .env.example .env
# Fill in: S3_BUCKET, S3_ENDPOINT, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY

# Start
docker compose up -d

# Check logs
docker compose logs -f
```

Access at `http://localhost:8080`

### 3. Deploy Secondary (Optional)

For disaster recovery, deploy a secondary instance on a different platform:

```bash
# In .env, set:
NODE_ROLE=secondary
DEPLOYMENT_MODE=serverless  # or persistent

docker compose up -d
```

## Configuration

### Required Environment Variables

```bash
S3_BUCKET=my-vaultwarden-backup
S3_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com
S3_PROVIDER=Cloudflare  # Cloudflare, AWS, Minio, etc.
S3_ACCESS_KEY_ID=your-key-id
S3_SECRET_ACCESS_KEY=your-secret-key
```

### Optional Settings

See [.env.example](.env.example) for all options. Key variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `NODE_ROLE` | `primary` | `primary` or `secondary` |
| `DEPLOYMENT_MODE` | `persistent` | `persistent` (long-running) or `serverless` (scale-to-zero) |
| `PRIMARY_SYNC_INTERVAL` | `300` | Seconds between file uploads (primary) |
| `SECONDARY_SYNC_INTERVAL` | `3600` | Seconds between refreshes (secondary persistent) |
| `S3_PREFIX` | `vaultwarden` | Path within bucket |

Full docs: [Vaultwarden Wiki](https://github.com/dani-garcia/vaultwarden/wiki) · [Litestream](https://litestream.io/reference/config/) · [rclone S3](https://rclone.org/s3/)

## Deployment Options

| NODE_ROLE | DEPLOYMENT_MODE | Scale to Zero | Notes |
|-----------|----------------|:------------:|-------|
| `primary` | `persistent` | ❌ | Long-running container. Recommended for most deployments. |
| `primary` | `serverless` | ✅ | **Set `max-instances=1`** to prevent concurrent writers. |
| `secondary` | `persistent` | ❌ | Refreshes from S3 every `SECONDARY_SYNC_INTERVAL`. |
| `secondary` | `serverless` | ✅ | Each cold start pulls latest from S3. |

### Serverless Primary

Primary instances can scale to zero safely:
- Litestream flushes all pending changes to S3 on shutdown (SIGTERM)
- rclone performs final file upload
- Zero data loss on graceful shutdown

**Requirements:**
- Set `max-instances=1` (SQLite single-writer constraint)
- Ensure `stop_grace_period: 30s` for graceful shutdown

## Health Check

Built-in health check monitors:
- HTTP `/alive` endpoint
- Litestream process (primary only)
- Sync freshness

Status available at `/tmp/sync-status.json`

## Disaster Recovery

**Scenario: Primary platform outage**

1. Point clients to secondary instance
2. Login sessions preserved (RSA keys synced)
3. All data up-to-date (persistent: within `SECONDARY_SYNC_INTERVAL`, serverless: latest on cold start)

**Warning:** Don't run two primary instances. SQLite only allows one writer.

## Data Safety

**Backup frequency:**
- Database: Real-time (Litestream syncs every 1s)
- Files: Every `PRIMARY_SYNC_INTERVAL` (default: 5 min)

**Data loss scenarios:**
- ✅ Graceful shutdown (scale-to-zero, restart): **Zero data loss**
- ⚠️ Catastrophic crash (SIGKILL, power loss): Up to 1s of database changes may be lost

**Protection:**
- Enable S3 bucket versioning
- Deleted files backed up to `_trash/` directory
- Set S3 lifecycle rules to auto-expire trash after N days

## Troubleshooting

```bash
# Check logs
docker logs vaultwarden

# View sync status
docker exec vaultwarden cat /tmp/sync-status.json

# Test S3 connectivity
docker exec vaultwarden rclone lsd S3:your-bucket

# Run health check
docker exec vaultwarden /app/healthcheck.sh
```

## Build from Source

```bash
docker build -t vaultwarden-stream:local .

# Multi-platform
docker buildx build --platform linux/amd64,linux/arm64 -t vaultwarden-stream:local .
```

## License

This project is MIT licensed. See [LICENSE](LICENSE) for details.

### Third-Party Software

This Docker image integrates the following open source projects:

- **[Vaultwarden](https://github.com/dani-garcia/vaultwarden)** — AGPL-3.0 License
- **[Litestream](https://github.com/benbjohnson/litestream)** — Apache License 2.0
- **[rclone](https://github.com/rclone/rclone)** — MIT License

Full license texts: [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md)
