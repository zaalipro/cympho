# Quickstart Guide

This guide walks you through setting up and running Cympho locally in **review mode**, allowing you to explore the product, configure agents, test prompt contracts, and review workflows without launching background agents or spending provider credits.

---

## 1. Prerequisites

Verify you have the required versions installed (pinned in `.tool-versions`):
- **Elixir**: `1.19.5-otp-28`
- **Erlang/OTP**: `28.4.3`
- **PostgreSQL**: Version 14+ running on `localhost:5432`
- **Git** and a standard shell (macOS `zsh` or Linux `bash`)

Use `asdf`, `mise`, or your system package manager to install the runtime. Native execution only: Docker is not required for local development.

---

## 2. Installation & Setup

Clone the repository and run the setup sequence:

```bash
git clone https://github.com/zaalipro/cympho.git
cd cympho

# 1. Install Hex/Rebar dependencies, create dev database, run migrations, seed demo data
mix setup

# 2. Download pinned Tailwind CSS and esbuild binaries
mix assets.setup

# 3. Build CSS and JavaScript bundles
mix assets.build

# 4. Run non-destructive system health check
mix cympho.doctor

# 5. Start Phoenix development server
mix phx.server
```

Open [http://localhost:4329](http://localhost:4329) in your browser.

> **Note on Ports**: Development defaults to port `4329` (configured in `config/dev.exs`). To run on standard port 4000 instead, pass `PORT=4000 mix phx.server`.

---

## 3. Instant Dev Sign-In

For rapid local exploration, use the development owner shortcut:
```text
http://localhost:4329/dev/login
```
This automatically authenticates you as the company owner without needing to type credentials.

### Seeded Credentials
If logging in via the standard `/login` screen:
- **Email**: `owner@cympho.local`
- **Password**: `password1234`

---

## 4. Understanding Review Mode

By default, Cympho boots in **Review Mode** with automatic orchestration disabled. In this mode:
- The full web UI, kanban board, issue composer, instruction studio, and settings hub are completely active.
- Background autonomous agent dispatchers and heartbeat timers are **dormant**.
- You can inspect issues, test prompts, and create projects without risk of unexpected API token spend.
- Local execution limits are governed by a named resource profile to prevent host memory pressure during agent execution.

### Enabling Controlled Autonomy
When you are ready to let agents execute work:

1. Configure your adapter credentials (e.g. Anthropic API key, Claude Code CLI, or Agrenting) in **Settings -> Integrations** or the company secret store.
2. Launch Phoenix with the orchestrator enabled:
   ```bash
   CYMPHO_ORCHESTRATOR_ENABLED=1 mix phx.server
   ```

To run autonomy against a single focused issue for debugging:
```bash
CYMPHO_ORCHESTRATOR_ENABLED=1 \
CYMPHO_DISPATCH_ONLY_ISSUE_ID=your-issue-uuid-here \
mix phx.server
```

---

## 5. Testing the MCP Server

Cympho includes a built-in Model Context Protocol server. Test it locally:

1. Check node health:
   ```bash
   curl -fsS http://localhost:4329/api/health
   ```
2. For complete MCP tool schemas, inputs, and integration with Claude Code or Cursor, see the [MCP API Reference](MCP_API_REFERENCE.md).

---

## 6. Verification Commands

Run the local quality and test gates:

```bash
# Verify code formatting
mix format --check-formatted

# Compile with zero warnings
MIX_ENV=test mix compile --warnings-as-errors

# Run ExUnit test suite (auto-creates and migrates cympho_test)
mix test

# Run docs link checker
mix test test/cympho/docs_link_validation_test.exs

# Verify script syntax
bash -n deploy.sh install.sh bin/cymphoctl
```

### Test Database Credentials
By default, tests connect to:
- **Database**: `cympho_test`
- **Host**: `localhost:5432`
- **Credentials**: `paperclip` / `paperclip` (or your local Postgres user)

Override with `TEST_DB_HOST`, `TEST_DB_NAME`, `TEST_DB_USER`, and `TEST_DB_PASSWORD`.

---

## 7. Common Troubleshooting

- **Database Connection Refused**: Ensure PostgreSQL is running locally (`brew services start postgresql@16` or `sudo systemctl start postgresql`).
- **Port 4329 in Use**: Another instance is running. Stop it or pass `PORT=4330 mix phx.server`.
- **Assets Not Loading**: Re-run `mix assets.setup && mix assets.build`.
- **Prompt Input Budget Exceeded**: If an agent fails with prompt budget errors, check the issue failure comment. The default input budget is 100,000 UTF-8 bytes. Adjust in agent settings or set `CYMPHO_PROMPT_INPUT_BUDGET_BYTES`.

---

## 8. Next Steps & Guide Index

- [Operations & Production Guide](OPERATIONS.md): Deployment, systemd, database backups, and runtime recovery.
- [MCP API Reference](MCP_API_REFERENCE.md): Model Context Protocol tools, schemas, and endpoints.
- [REST API Reference](REST_API.md): Full reference for all JSON endpoints.
- [Scheduled Routines & Webhooks](ROUTINE_WEBHOOKS.md): Cron automations and signed HMAC webhooks.
- [Remote Environments & Marketplace Agents](REMOTE_ENVIRONMENTS.md): Agrenting agents and SSH sandboxes.
- [Portable Company Packages](PORTABLE_PACKAGES.md): Company backups, blueprint exports, and resumable import transfers.
- [Observability & Diagnostics](OBSERVABILITY.md): Sentry, `/beam` LiveDashboard, tool traces, and OTLP.
- [Mobile QA Guide](MOBILE_QA.md): Mobile responsive testing and viewport geometry.
- [Resource Benchmarks](benchmarks.md): Idle fleet performance and concurrency metrics.
