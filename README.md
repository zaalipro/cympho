# Cympho

**An autonomous company OS for AI agents.**

Cympho turns business objectives into coordinated company execution. A CEO agent prioritizes and routes requests, Product and Design shape the briefs, the CTO decomposes technical initiatives into executable tasks, and engineer agents produce inspectable changes with delivery notes, runs, work products, PR evidence, and review trails.

When a single agent is not enough, **swarm mode** fans out a parent issue into temporary non-engineering worker packets, routes synthesis through the CTO, blocks the CEO parent until synthesis is ready, and streams the entire decision tree live to the issue log.

---

## Product Tour

### Command Center
<p align="center">
  <img src="./screens/readme-2026-06-17-dashboard.png" alt="Cympho dashboard showing owner action plan, runtime capacity, CEO command lane, and company navigation" width="100%">
</p>

### Kanban Board
<p align="center">
  <img src="./screens/readme-2026-06-17-board.png" alt="Cympho Kanban board showing review mode, flow health, focus queue, and status columns" width="100%">
</p>

### Swarm Issue Log
<p align="center">
  <img src="./screens/readme-2026-06-17-swarm-issue.png" alt="Cympho issue detail page showing swarm orchestration, live swarm log, worker packets, CTO gate, and CEO handoff" width="100%">
</p>

### Swarm Composer
<p align="center">
  <img src="./screens/readme-2026-06-17-new-issue-swarm.png" alt="Cympho new issue swarm composer with temporary worker count, harness, model, reasoning effort choices, and proxy management link" width="100%">
</p>

### Operations Console
<p align="center">
  <img src="./screens/readme-2026-06-17-operations.png" alt="Cympho Operations page showing runtime mode, launch checklist, dispatch commands, and required runtime environment flags" width="100%">
</p>

### Agents & Role Coverage
<p align="center">
  <img src="./screens/readme-2026-06-17-agents.png" alt="Cympho Agents page showing role coverage, staffing gaps, agent counts, and remote-hire actions" width="100%">
</p>

---

## Core Capabilities

- **Swarm Mode & Live Swarm Logs**: Automatically create one-time temporary worker agents, assign independent non-engineering lenses, route synthesis through the CTO gate, block the CEO parent until the synthesis is verified, and stream real-time events to the issue page.
- **Operations Console & Runtime Controls**: Monitor agent capacity, adapter health, prompt readiness, blocked work, and execution risk. Global runtime controls (**Normal**, **Low Power**, **Pause**, **Emergency Stop**, and **Resume**) allow operators to throttle after-hours work or freeze runaways.
- **Issue-Level Pause/Resume**: Freeze an individual runaway issue without pausing the whole agent or company. Paused issues stop active runtime, block checkout/dispatch, and log audit events.
- **Instruction Studio**: Inspect agent instructions before execution, detect weak prompts, tune role playbooks, and preview contract coverage for CEO, CTO, Product, Design, and Engineering roles.
- **Owner-Readable Issue Digest**: Synthesizes comments, runs, work products, child issues, and PR state into an actionable brief answering: *what happened, who did it, what evidence exists, and what decision is next?*
- **Human Review Gates & Rework Loop**: The review queue (`/reviews`) and attention inbox (`/inbox`) enforce mandatory reason forms for change requests, record human reviewers separately from agent reviewers, and return issues to rework with feedback protected in the next prompt.
- **Execution Workspaces & Runtime Previews**: Isolate repository checkouts in Git worktrees or remote SSH sandboxes with cryptographic host-key pinning, manage runtime services, and view preview proxy endpoints.
- **Rent Remote Agents from Agrenting**: Connect an Agrenting API key, browse marketplace agents, and hire remote specialist agents with unique DIDs as local Cympho proxy operators.
- **Reversible Decisions & Governance**: Board approvals with voting, execution policy escalation rules, immutable governance audit logs, and reversible decision events.
- **Cryptographic Tool-Call Traces**: SHA-256 hash-chained audit logging (`/tool-call-traces`) recording every tool invocation with automatic credential redaction and tamper detection.
- **Resource Admission & Concurrency**: The orchestrator manages concurrency boundaries distinguishing total runs, local CLI processes (such as Claude Code or Codex execution), and lightweight gateway work to safeguard host memory.

---

## Model Context Protocol (MCP) Server

Cympho implements a native [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server at `/api/mcp`, enabling external AI models, IDE extensions, and CLI tools (such as Claude Code or Cursor) to interact with Cympho directly.

### MCP Endpoints
- `GET /api/mcp/tools`: List all available tools (static + granted dynamic plugin tools).
- `POST /api/mcp/call`: Execute a named tool with arguments.

### Built-In Static Tools
1. `list_issues`: Query and filter issues by status, priority, role, assignee, project, or search term.
2. `get_issue`: Get detailed issue attributes and recent comments.
3. `list_issue_comments`: Retrieve paginated comments in chronological order.
4. `create_issue_comment`: Post an agent comment on an issue (governed by role or permissions).
5. `create_issue`: Create a new task or issue in a project (governed by role or permissions).
6. `list_projects`: List all company projects and prefixes.
7. `list_agents`: List company agents, status, and assigned roles.
8. `get_kanban_state`: Summarize issues per kanban column with counts.
9. `search`: Cross-entity search across issues, projects, and agents.

### Security, Scoping & Tracing
- **Company Scoping**: Tool calls are strictly scoped to the authenticated agent's `company_id`. Callers cannot pass or override company parameters.
- **Authentication**: Supports `Authorization: Bearer <agent_jwt>` (heartbeats) and `X-API-Key: <key>` (external harnesses).
- **Rate Limiting**: Mutation bursts return HTTP 429 (`%{"error" => "rate_limited", "success" => false}`).
- **Dynamic Plugin Registry**: Plugins register tools dynamically via `Cympho.Mcp.ToolRegistry`, gated by fail-closed permissions (`Cympho.Mcp.ToolGrants`).
- **Cryptographic Tracing**: Every call is SHA-256 hash-chained in `Cympho.ToolCallTraces`.

For complete input schemas, return contracts, and client examples, see the [MCP API Reference](docs/MCP_API_REFERENCE.md).

---

## REST API

Cympho provides a complete JSON REST API under `/api` for integrations, CI/CD webhooks, and automation:
- **Authentication**: User JWT generation (`POST /api/login`, `POST /api/register`).
- **Issues & Documents**: Issue CRUD, label management, versioned documents with unified diffs and rollback.
- **Deliverables**: Work products (patches, specifications, designs) attached to issues.
- **Projects & Goals**: Company strategic goals, launch checklist items, and project settings.
- **Routines & Webhooks**: Cron-scheduled routines and signed HMAC-SHA256 inbound webhooks (`POST /api/routine-triggers/:public_id/fire`).
- **Workspaces & Previews**: Git worktrees, runtime background services, and port leases.
- **Approvals**: Board and human approval requests and resolution.

For detailed endpoint contracts and payload schemas, see the [REST API Reference](docs/REST_API.md).

---

## Quickstart

### Prerequisites
Pinned in `.tool-versions`:
- **Elixir**: `1.19.5-otp-28`
- **Erlang/OTP**: `28.4.3`
- **PostgreSQL**: Version 14+ running on `localhost:5432`

### Local Setup
```bash
git clone https://github.com/zaalipro/cympho.git
cd cympho

# Install dependencies, setup database, and seed demo company
mix setup

# Install and build asset bundles
mix assets.setup
mix assets.build

# Verify system health
mix cympho.doctor

# Start development server
mix phx.server
```

Open [http://localhost:4329](http://localhost:4329). Cympho development defaults to port **4329** (`config/dev.exs`). Set `PORT=4000` if you prefer the standard Phoenix port.

### Instant Dev Sign-In
Use the development owner shortcut for zero-friction local login:
```text
http://localhost:4329/dev/login
```

Seeded credentials:
- **Email**: `owner@cympho.local`
- **Password**: `password1234`

### Running Safely in Review Mode
Cympho boots in **Review Mode** by default. Background agent dispatchers and heartbeat timers remain dormant, allowing you to explore the UI, inspect playbooks, and configure projects without spending API tokens.

To enable autonomous background execution:
```bash
CYMPHO_ORCHESTRATOR_ENABLED=1 mix phx.server
```

To use a Claude-compatible CLI wrapper (e.g. `cz` or `cm`):
```bash
CYMPHO_CLAUDE_COMMAND=cz CYMPHO_ORCHESTRATOR_ENABLED=1 mix phx.server
```

For full setup instructions, see the [Quickstart Guide](docs/QUICKSTART.md).

---

## Architecture

Cympho is built on the Erlang/BEAM ecosystem using Elixir and Phoenix:
- **Bandit HTTP Server**: Modern, performant HTTP/1.1 and HTTP/2 server.
- **Phoenix LiveView**: Real-time, server-rendered reactive DOM diffs over WebSockets for all primary management interfaces.
- **Phoenix Channels**: High-frequency telemetry streams for agent heartbeats, run progress, live swarm logs, and activity events.
- **EventStore**: In-memory ETS replay buffer ensuring reconnecting clients seamlessly catch up on recent topic events.
- **OTP Supervision Tree**: Per-agent heartbeat supervision, dynamic task supervisors, orchestrator registries, and watchdog monitors.
- **Agent Adapters**: Pluggable backends supporting Claude Code CLI wrappers, OpenAI/Codex, Cursor CLI, OpenAI Chat, OpenClaw, Process CLI presets, HTTP, and Agrenting.
- **PostgreSQL & Ecto**: Multi-tenant relational persistence with optimistic concurrency locking (`lock_version`) on issues and state machines.

---

## Useful Commands

```bash
mix setup                         # Install deps, create DB, migrate, seed
mix ecto.reset                    # Reset dev database (destructive)
mix test                          # Run full ExUnit test suite
mix test test/path/to_test.exs    # Run a single test file
mix format                        # Format Elixir code and HEEx templates
mix compile --warnings-as-errors  # Compile with zero warnings
mix assets.setup                  # Install pinned Tailwind and esbuild binaries
mix assets.build                  # Build development assets
mix assets.deploy                 # Build production minified assets
mix cympho.doctor                 # Non-destructive system posture check
mix cympho.compare                # Local regression audit against baseline
PORT=4329 mix phx.server          # Start dev server on port 4329
```

---

## Programmatic Validation Gates

Before submitting contributions or deploying releases, verify all local gates pass:

```bash
# 1. Format check
mix format --check-formatted

# 2. Strict compilation
MIX_ENV=test mix compile --warnings-as-errors

# 3. ExUnit test suite
mix test

# 4. Automated documentation link and path validation
mix test test/cympho/docs_link_validation_test.exs

# 5. Shell script syntax verification
bash -n deploy.sh install.sh bin/cymphoctl
```

---

## Production Deployment & Security

Cympho deployments run as an immutable release under `systemd` behind a reverse proxy (Nginx or Caddy) handling TLS termination.

### Production Installation & Bootstrap Contract
To bootstrap a new production server, clone the repository first and run `./install.sh` interactively:

```bash
git clone https://github.com/zaalipro/cympho.git
cd cympho
./install.sh
```

- **Interactive Verification**: Always clone the repository before running `./install.sh`. Do not pipe it into a shell.
- **Hermetic Build**: The installer creates an exact Git archive snapshot for production compilation and configures the dedicated `cympho` system service user.
- **Persistent Data**: Persistent uploads/import data are stored in `/var/lib/cympho/data` outside the release tree.
- **Bootstrap Lifecycle**: The installer is **first-bootstrap-only**. If the installation process was interrupted before the managed systemd unit was published, rerun `./install.sh` to complete initial provisioning.
- **Maintenance & Updates**: Cympho has no managed in-place updater within the installer script; upgrades use a separate fixed-layout workflow (`deploy.sh`).

### Production DNS, Certificates & Existing-Install Migration
- **Previews Disabled**: In production, production previews are disabled.
- **DNS Ownership**: DNS ownership is solely for `cympho.llmotions.com`; operators can safely retire legacy preview DNS records.
- **Certificates**: The deployment pipeline reconciles the application certificate to main-only without revoking or deleting valid working certificates.
- **Environment Migration**: The deployment workflow automatically strips stale production `PREVIEW_HOST` entries while preserving `POOL_SIZE=5` for database connection health.

### Fail-Closed Secrets
In `:prod`, `config/runtime.exs` fails closed at boot if any required secret is missing:
```bash
SECRET_KEY_BASE=...
DATABASE_URL=ecto://user:pass@127.0.0.1:5432/cympho_prod
APP_HOST=cympho.llmotions.com
LIVE_VIEW_SALT=...
CYMPHO_ENCRYPTION_KEY=min-32-byte-secret-key-here
CYMPHO_USER_JWT_SECRET=min-32-byte-secret-key-here
CYMPHO_AGENT_JWT_SECRET=min-32-byte-secret-key-here
CYMPHO_IMPORT_SPOOL_DIR=/opt/cympho/data/import-transfers
```

### Production Migrations
Run database migrations from the compiled release without requiring Mix:
```bash
/opt/cympho/current/bin/cympho eval "Cympho.Release.migrate"
```

For complete deployment lock lifecycles, systemd configurations, and backup/restore procedures, see the [Operations Guide](docs/OPERATIONS.md).

---

## Cympho vs. Paperclip at a Glance

| Evaluation Dimension | Paperclip | Cympho | Summary Assessment |
|---|---|---|---|
| **Platform Maturity & Community** | Larger public footprint, broader prebuilt catalog, mature public website. | Younger platform, focused on developer-operator control and BEAM concurrency. | **Paperclip** leads in ecosystem scale; **Cympho** focuses on live operations. |
| **Swarm Orchestration** | Standard linear task routing across agents. | Admin-configured swarms with non-engineering worker packets, CTO synthesis gates, and CEO handoffs. | **Cympho** provides a purpose-built CTO-mediated swarm workflow. |
| **Issue Evidence & Memory** | Task logs, comments, and conversation histories. | Automated issue briefs synthesizing runs, deliverables, PR state, review gates, and blocker chains. | **Cympho** emphasizes owner-readable delivery evidence. |
| **Live Operations Control** | Process stop/kill commands. | BEAM OTP supervision, EventStore replay, Operations console, Low Power mode, and issue-scoped freeze. | **Cympho** offers granular local runtime controls. |
| **Idle Fleet Efficiency** | Polling timer heartbeats on idle agents. | Delegated event-driven dispatch: 0 idle DB queries, 0 timers, and minimal idle RAM footprint. | **Cympho** is verified timer-free while fleet is idle ([Benchmarks](docs/benchmarks.md)). |
| **External AI & Tool Control** | External tool gateways and app integrations. | Direct control-plane MCP server (`/api/mcp`) with 9 static tools, dynamic plugins, and SHA-256 traces. | Both provide robust tool interfaces; **Cympho** includes built-in cryptographic trace chaining. |

For detailed gap tracking and comparative audit notes, see [`paperclip_gap.md`](paperclip_gap.md) and [`docs/benchmarks.md`](docs/benchmarks.md).

---

## Documentation Index

- [Quickstart Guide](docs/QUICKSTART.md): Step-by-step local development setup and review mode.
- [Operations & Production Guide](docs/OPERATIONS.md): Systemd units, migrations, resource profiles, backups, and recovery.
- [Model Context Protocol (MCP) API Reference](docs/MCP_API_REFERENCE.md): Complete guide to Cympho's MCP server, 9 static tools, and dynamic registry.
- [REST API Reference](docs/REST_API.md): Full reference for all JSON endpoints (Issues, Documents, Workspaces, Goals, Routines).
- [Scheduled Routines & Webhooks](docs/ROUTINE_WEBHOOKS.md): Quantum cron syntax and replay-safe signed HMAC webhooks.
- [Remote Environments & Marketplace Agents](docs/REMOTE_ENVIRONMENTS.md): Agrenting marketplace agents and SSH execution sandboxes.
- [Portable Company Packages](docs/PORTABLE_PACKAGES.md): Company blueprints, selective export, and resumable import transfers.
- [Observability & Diagnostics](docs/OBSERVABILITY.md): Sentry, `/beam` LiveDashboard, tool traces, and OTLP export.
- [Mobile QA Guide](docs/MOBILE_QA.md): Mobile responsive architecture, drawer navigation, and viewport testing.
- [Performance & Resource Benchmarks](docs/benchmarks.md): Idle fleet benchmarks, delegated vs. direct mode, and concurrency metrics.
- [Paperclip Comparison & Gap Register](paperclip_gap.md): Feature matrix, historical audit findings, and exit criteria.
- [Architecture Review & Triage Record](docs/ARCHITECTURE_REVIEW.md): Historical milestone 1 architecture review and bounded simplifications.
- [Real-World Autonomy Smoke Transcript](docs/LLMOTIONS_REAL_WORLD_SMOKE.md): Transcript and verification record of initial live smoke testing.
- [UI Copy Simplification & Audit Log](docs/UI_COPY_AUDIT.md): Comprehensive before-and-after microcopy audit log and tone guidelines.
- [Agent Guidelines](AGENTS.md): Repository instructions and engineering conventions for AI coding agents.
- [Security Policy](SECURITY.md): Vulnerability reporting procedures and cryptographic controls.
- [Contributing Guide](CONTRIBUTING.md): Code style, testing requirements, and PR workflows.
- [Roadmap](ROADMAP.md): Project milestones, architecture goals, and future directions.
