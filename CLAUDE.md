# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Cympho is an AI agent orchestration platform built with Elixir/Phoenix. Agents (engineers, PMs, designers, CEOs, CTOs) work on issues within multi-tenant companies. The system manages agent lifecycles, heartbeats, execution policies, governance approvals, and real-time collaboration.

## Commands

```bash
mix setup                    # Install deps, create DB, migrate, seed
mix ecto.reset               # Drop + recreate DB with migrations and seeds
mix test                     # Run all tests (auto-creates/migrates test DB)
mix test test/path/to_test.exs  # Run a single test file
mix test test/path/to_test.exs:123  # Run single test at line 123
mix format                   # Format code
mix phx.server               # Start dev server (port 4000)
iex -S mix phx.server        # Start server with IEx shell
```

No credo or dialyzer is configured. Test DB credentials: `paperclip/paperclip@localhost/cympho_test`.

## Architecture

### OTP Supervision Tree

`Cympho.Application` starts a `one_for_one` supervisor with these key children:
- `Cympho.Repo` (Ecto), `Phoenix.PubSub`, `Task.Supervisor`
- Registries: `OrchestratorRegistry`, `AgentHeartbeat.Registry`, `PluginRegistry`
- `AgentHeartbeat.Supervisor` (dynamic supervisor)
- `AutoAssignmentReassigner` (GenServer) — reassigns issues when agents go offline
- `Orchestrator.Dispatcher` (GenServer) — dispatches agent runs
- `HeartbeatEngine.Watchdog` — timer-based watchdog for agent liveness
- `NotificationSupervisor`, `BoardApprovalActionExecutor`
- `Cympho.Scheduler` (Quantum cron jobs)
- `Adapters.Registry` + `AgentAdapters.HealthChecker`
- `Plugins.Registry` + `Plugins.Supervisor`
- `Skills.HotReloader`
- `EventStore`

### Core Domain Flow

1. **Issues** (`Cympho.Issues`) — managed via a state machine (`Issues.StateMachine`). Issues have `lock_version` for optimistic concurrency.
2. **Agents** (`Cympho.Agents`) — AI agent entities with roles, adapter types, API keys.
3. **Orchestrator** (`Cympho.Orchestrator`) — GenServer registered by `issue_id` that manages agent sessions for an issue. Creates comments, transitions issue state, publishes PubSub events.
4. **Agent Adapters** (`Cympho.AgentAdapters`) — behavior-based adapters for backends: `claude_code`, `codex`, `cursor`, `http`, `openclaw`, `process`.
5. **Heartbeat Engine** (`Cympho.HeartbeatEngine`) — tracks agent runs, wakeup queue, and watchdog timer.
6. **Agent Runner** (`Cympho.AgentRunner`) — executes agent tasks (has mock for testing).

### Multi-Tenancy

Company-based multi-tenancy. Most schemas have a `company_id` FK. `CymphoWeb.UserAuth` (LiveView on_mount) loads the current user, their companies, and current company into the socket.

### Authentication

- **Users**: Session cookies via `Cympho.Authentication` (Argon2 hashing)
- **Agents** (three methods via `CymphoWeb.Plugs.AgentAuth`): JWT (Bearer), API key (X-API-Key), legacy X-Agent-ID
- **Board**: `CymphoWeb.Plugs.BoardAuth` verifies board membership for governance mutations

### Web Layer

- **LiveViews** in `lib/cympho_web/live/` with `.heex` templates — primary UI
- **Controllers** in `lib/cympho_web/controllers/` — API JSON + HTML endpoints
- **Channels** in `lib/cympho_web/channels/` — Phoenix Channels (WebSocket) for activity, comments, issues, heartbeats, runs
- **Components** in `lib/cympho_web/components/` — reusable UI (badge, card, nav_rail, company_rail, company_switcher, interaction_card)

### Key Subsystems

- **Governance**: Board approvals with voting, execution policies, audit logs, principal permissions
- **Plugins**: Extensible plugin system with capability-gated host services (see `PLUGIN_SDK.md`)
- **Skills**: Skill manifests, loaders, hot-reloader, sandbox execution
- **Routines**: Scheduled routines with webhook triggers and run history
- **Workspaces**: Execution workspaces, environments, leases, probes, runtime services
- **Finances**: Budget enforcement, token usage tracking, billing
- **Notifications**: Multi-channel (email, Telegram, webhook) with supervisor and retry worker
- **MCP Server**: `Cympho.Mcp.Server` exposes tools for AI model consumption (list_issues, create_issue, etc.)

### Design System

Dark-mode-first UI inspired by Linear. See `DESIGN.md` for the full specification. Tailwind CSS with custom tokens (brand indigo `#5e6ad2`, canvas/panel/surface layers). Inter Variable font. Kanban drag-and-drop via SortableJS.

## Conventions

- All schemas use `:binary_id` (UUID) primary keys and `:utc_datetime` timestamps
- Phoenix Context pattern — each domain has a context module as its public API (e.g., `Cympho.Issues`, `Cympho.Agents`)
- Test support modules: `ConnCase`, `DataCase`, `ChannelCase`, `LiveCase`
- Test pool mode: `Ecto.Adapters.SQL.Sandbox` in manual mode
- Tool versions pinned in `.tool-versions`: Elixir 1.19.5-otp-28, Erlang 28.4.3
- Production config via env vars in `config/runtime.exs` (DATABASE_URL, SECRET_KEY_BASE, APP_HOST, S3/AWS settings)
- Bandit HTTP server (not Cowboy)
