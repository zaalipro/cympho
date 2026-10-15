# Production Operations & Deployment Guide

This guide covers production deployment, systemd service management, database migrations, resource budgeting, incident response, and runtime operational controls for Cympho.

---

## 1. Operating Posture & Runtime Modes

Cympho provides four global runtime modes to control agent dispatch and provider spend:

| Mode | Trigger | Behavior |
|---|---|---|
| **Normal** | Default / `POST /runtime-control/resume` | Full autonomous dispatch across all issue priorities. |
| **Low Power** | `POST /runtime-control/low-power` | Restricts automatic dispatcher selection to `critical` and `high` priority issues only. Routine background loops slow down. |
| **Pause** | `POST /runtime-control/pause` | Halts automatic checkout and dispatch. Pending wakes remain safely queued in PostgreSQL. |
| **Emergency Stop** | `POST /runtime-control/stop` | Immediately stops active orchestrator processes, cancels running database rows, signals registered adapter workers to terminate, and releases issue checkouts. |

### 1.1 Issue-Level Pause
Operators can freeze an individual runaway issue without pausing the whole agent or company:
- Toggle **Pause** on the issue detail page (`/issues/:id`).
- Sets `monitor_state["issue_runtime"]["paused"] = true`.
- The dispatcher immediately skips the issue and rejects wake events until resumed.

---

## 2. Production Deployment & Systemd Service

### 2.1 File System Layout
In a standard production deployment (`deploy.sh` layout):
```text
/opt/cympho/
├── current -> /opt/cympho/releases/20261015120000   # Active release symlink
├── releases/                                       # Immutable timestamped releases
├── data/
│   ├── uploads/                                    # Persistent user attachment storage
│   └── import-transfers/                           # Resumable company import spool
└── db.env                                          # Restricted database environment file
/etc/cympho.env                                     # Production application environment file
/etc/systemd/system/cympho.service                  # Systemd service unit
```

### 2.2 Systemd Unit Configuration
`/etc/systemd/system/cympho.service`:
```ini
[Unit]
Description=Cympho Autonomous Company OS
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=exec
User=cympho
Group=cympho
WorkingDirectory=/opt/cympho/current
EnvironmentFile=/etc/cympho.env
ExecStart=/opt/cympho/current/bin/cympho start
ExecStop=/opt/cympho/current/bin/cympho stop
Restart=always
RestartSec=5
LimitNOFILE=65536
TimeoutStartSec=60
TimeoutStopSec=30

# Hardened security sandbox
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

### 2.3 Managing the Service
```bash
# Reload unit definitions
sudo systemctl daemon-reload

# Start, stop, or restart service
sudo systemctl start cympho
sudo systemctl restart cympho
sudo systemctl stop cympho

# Inspect service status
sudo systemctl status cympho

# Stream service logs
sudo journalctl -u cympho -f
```

---

## 3. Production Environment & Secrets

Never commit real credentials to repository configuration or environment files. In staging or recovery, verify system behavior in review mode before enabling autonomous background execution.

Production enforces **fail-closed secret validation**. `config/runtime.exs` will abort application boot if any of the following required variables are missing:

| Variable | Description | Requirement |
|---|---|---|
| `DATABASE_URL` | PostgreSQL connection string (`ecto://user:pass@127.0.0.1:5432/cympho_prod`) | Required |
| `SECRET_KEY_BASE` | Phoenix secret key base (min 64 bytes) | Required |
| `CYMPHO_ENCRYPTION_KEY` | AES encryption key for company secrets (min 32 bytes) | Required (fail-closed) |
| `CYMPHO_USER_JWT_SECRET` | Secret for signing user authentication JWTs | Required (fail-closed) |
| `CYMPHO_AGENT_JWT_SECRET` | Secret for signing agent heartbeat JWTs | Required (fail-closed) |
| `APP_HOST` | Production domain name (`cympho.llmotions.com`) | Required |
| `LIVE_VIEW_SALT` | Signing salt for LiveView sessions | Required |
| `POOL_SIZE` | Database connection pool size (default: 25) | Optional (integer) |
| `CYMPHO_IMPORT_SPOOL_DIR`| Persistent directory for resumable imports (`/opt/cympho/data/import-transfers`) | Required in prod |
| `CYMPHO_UPLOADS_DIR` | Persistent directory for file attachments (when not using S3) | Optional |
| `SENTRY_DSN` | Sentry exception reporting endpoint | Optional |

Generate secrets using Mix:
```bash
mix phx.gen.secret
```

---

## 4. Production Database Migrations

In production releases (where `mix` is not installed on the target host), migrations are executed via the compiled release entry point:

```bash
# Run pending migrations
/opt/cympho/current/bin/cympho eval "Cympho.Release.migrate"

# Roll back to a specific migration version if needed
/opt/cympho/current/bin/cympho eval "Cympho.Release.rollback(Cympho.Repo, 20261007000001)"
```

> **Connection Safety**: `Cympho.Release.migrate` automatically clamps its migration pool size to `2`. This ensures migrations running during deployments do not exhaust PostgreSQL's `max_connections` or starve the active application.

---

## 5. Reverse Proxy & SSL Configuration

Cympho runs under Bandit HTTP server binding loopback port `4000` (or `4329`). A reverse proxy (Nginx or Caddy) terminates HTTPS on port 443 with Let's Encrypt certificates.

### 5.1 Nginx Reverse Proxy Configuration
```nginx
server {
    server_name cympho.llmotions.com;
    listen 80;
    return 301 https://$host$request_uri;
}

server {
    server_name cympho.llmotions.com;
    listen 443 ssl http2;

    ssl_certificate /etc/letsencrypt/live/cympho.llmotions.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/cympho.llmotions.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

### 5.2 Untrusted Runtime Previews & Production DNS
In production, production previews are disabled. Production DNS ownership requires only `cympho.llmotions.com`. Existing-install migration is reconciled to main-only by `deploy.sh`, which automatically removes legacy `PREVIEW_HOST` settings and aligns web certificates with single-origin production hosting. Untrusted preview content is never routed through `cympho.llmotions.com` to prevent cross-site scripting and cookie leakage across tenant boundaries.

---

## 6. Resource Profiles & Memory Safety

Cympho uses named resource profiles to enforce multi-tiered concurrency boundaries:
1. **Total Concurrent Runs**: Overall ceiling for agent executions across all adapters.
2. **Local Process Concurrency**: Bounded by `CYMPHO_MAX_LOCAL_AGENT_RUNS` to limit simultaneous execution of local CLI adapters (Claude Code, Cursor, Codex).
3. **Memory Admission Threshold**: Bounded by `CYMPHO_LOCAL_AGENT_MEMORY_RESERVE_MB` (default: 512 MB). This gate evaluates available host/cgroup memory before launching an agent process. Note that this is not a per-process memory reservation; it is a system-level admission threshold. Setting `CYMPHO_LOCAL_AGENT_MEMORY_RESERVE_MB=0` selects a disabled memory gate.
4. **Host Cgroup Compatibility**: On environments that are not cgroup-aware, memory inspection falls back to `/proc/meminfo`.
5. **Operating System Dependencies**: Package dependencies for external CLIs and tooling follow the Debian/Ubuntu `apt` path.
6. **Unified Architecture**: Agent dispatch and supervision run directly within the BEAM supervision tree and are not a separately running Cympho service.

---

## 7. Prompt Input Budget & Context Protection

Input prompts default to **100,000 UTF-8 bytes** (configurable via `CYMPHO_PROMPT_INPUT_BUDGET_BYTES` or per-agent `input_budget_bytes`).

### Context Trimming Hierarchy
When prompt size exceeds budget, optional sections are trimmed in strict order:
1. Historical completed sub-issue summaries
2. Older comment history
3. File attachments (replaced with omission notice)

### Protected Content
The following sections are **never trimmed**:
- Current task description (`## Current task - do this now`)
- Action contract and tool definitions
- The latest human review reason and change request notes

If the protected content alone exceeds the input budget, the run halts with a clear error comment before executing the adapter, avoiding wasteful token burn.

---

## 8. Database Backups & Disaster Recovery

### 8.1 Database Backup (`pg_dump`)
Run scheduled nightly backups using PostgreSQL's custom compressed archive format:
```bash
pg_dump -Fc -h 127.0.0.1 -U cympho cympho_prod > /var/backups/cympho_$(date +%Y%m%d_%H%M%S).dump
```

### 8.2 Database Restore (`pg_restore`)
Before restoring:
1. Stop the Cympho service: `sudo systemctl stop cympho`.
2. Restore database:
   ```bash
   pg_restore --clean --if-exists -h 127.0.0.1 -U cympho -d cympho_prod /var/backups/cympho_backup.dump
   ```
3. Run release migration check:
   ```bash
   /opt/cympho/current/bin/cympho eval "Cympho.Release.migrate"
   ```
4. Start service in Review Mode first to inspect state before enabling background agents:
   ```bash
   sudo systemctl start cympho
   ```

### 8.3 Company Blueprint Exports
For portable, database-independent tenant backups, export individual company packages (`/companies/:id/export`). Note that package exports intentionally omit secret keys; restore credentials separately via the in-app secret store.

---

## 9. Incident Response Playbook

When an operational anomaly or runaway agent is detected:
1. **Emergency Stop**: Click **Stop** on the Operations Console (`/operations`) or issue `POST /runtime-control/stop`.
2. **Inspect Run Logs**: Review the issue's runtime ledger and recent tool-call traces at `/tool-call-traces`.
3. **Inspect BEAM Metrics**: Open `/beam` to check process mailboxes, ETS table growth, and memory distribution.
4. **Credential Revocation**: If an agent leaked credentials or misbehaved, revoke affected API keys immediately in **Settings -> Secrets**.
5. **Resume in Low Power**: Address the root cause, verify adapter configuration, and resume in **Low Power Mode** before returning to full power.

---

## 10. Operations Guide Index

- [Quickstart Guide](QUICKSTART.md): Local development, seeding, and review mode.
- [MCP API Reference](MCP_API_REFERENCE.md): Model Context Protocol server tools and schemas.
- [REST API Reference](REST_API.md): Comprehensive JSON API endpoint reference.
- [Scheduled Routines & Webhooks](ROUTINE_WEBHOOKS.md): Quantum cron and signed HMAC webhooks.
- [Remote Environments & Marketplace Agents](REMOTE_ENVIRONMENTS.md): Agrenting marketplace and SSH sandboxes.
- [Portable Packages](PORTABLE_PACKAGES.md): Company blueprints and resumable transfers.
- [Observability & Diagnostics](OBSERVABILITY.md): Sentry, `/beam`, tool traces, and OTLP.
- [Mobile QA Guide](MOBILE_QA.md): Mobile layout mechanics and viewport validation.
- [Resource Benchmarks](benchmarks.md): Idle agent fleet benchmarks and capacity limits.
