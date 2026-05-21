# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Working Principles

These bias toward caution over speed. For trivial tasks, use judgment.

### Think before coding

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.

### Simplicity first

- Minimum code that solves the problem. Nothing speculative.
- No abstractions for single-use code, no "flexibility" that wasn't requested, no error handling for impossible scenarios.
- If you wrote 200 lines and it could be 50, rewrite it.

### Surgical changes

- Touch only what the task requires. Don't "improve" adjacent code, comments, or formatting.
- Match existing style even if you'd write it differently.
- Remove imports/variables your changes orphaned; don't delete pre-existing dead code unless asked.
- Every changed line should trace directly to the user's request.

### Goal-driven execution

- Turn vague tasks into verifiable goals: "fix the bug" → "write a test that reproduces it, then make it pass."
- For multi-step work, state a brief plan with a verify-step for each item.
- Strong success criteria let you loop independently; weak ones ("make it work") force constant clarification.

## Project Overview

Cympho is an AI agent orchestration platform built with Elixir/Phoenix. Agents (engineers, PMs, designers, CEOs, CTOs) work on issues within multi-tenant companies. The system manages agent lifecycles, heartbeats, execution policies, governance approvals, decisions with reversal, an MCP server for external AI consumption, and real-time collaboration over both LiveView and Phoenix Channels.

## Commands

```bash
mix setup                    # Install deps, create DB, migrate, seed
mix ecto.reset               # Drop + recreate DB with migrations and seeds
mix test                     # Run all tests (auto creates/migrates test DB)
mix test test/path/to_test.exs       # Run a single test file
mix test test/path/to_test.exs:123   # Run single test at line 123
mix format                   # Format code
mix phx.server               # Start dev server (port 4000)
iex -S mix phx.server        # Start server with IEx shell
mix assets.build             # Build CSS/JS for dev
mix assets.deploy            # Build + minify assets for production
mix credo                    # Static analysis (informational; aim for clean over time)
mix credo --strict           # All checks at full strictness
mix dialyzer                 # Typecheck (first run builds PLT, ~3min; cached after)
```

`mix test` is aliased to `ecto.create --quiet && ecto.migrate --quiet && test` so a fresh checkout works with one command. Credo and dialyxir are configured but not yet enforced in CI — treat them as informational tools that catch regressions in new code. Test DB credentials: `paperclip/paperclip@localhost/cympho_test`.

## Logging conventions

- Use Elixir's `Logger` module (not Erlang's `:logger`) in all `lib/` code. Add `require Logger` to any module that emits logs.
- Prefer keyword metadata over string interpolation: `Logger.warning("budget exhausted", agent_id: id, policy_id: pid)` over `Logger.warning("budget exhausted for agent #{id}")`.
- Standard metadata keys: `issue_id`, `agent_id`, `company_id`, `component`. Reuse these so downstream filters work consistently.
- `:logger.add_handler/3` is the correct API for registering loggers (e.g. Sentry's handler in `Cympho.Application.start/2`); only the *emission* sites must use `Logger`.

## Claude CLI Wrappers

Agent execution can point at a Claude-compatible wrapper command instead of the default `claude` binary. Set `CYMPHO_CLAUDE_COMMAND` or an agent/runtime `command` value to a wrapper such as `cz` or `cm`.

The Claude Code adapters source `$HOME/.cld` before checking or invoking the command. Keep that file local-only and use it for provider exports such as `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, and `ANTHROPIC_MODEL` when running cheap compatible providers in development. Production should use managed environment variables or the app's secret stores rather than relying on a personal dotfile.

## Architecture

### OTP Supervision Tree

`Cympho.Application` starts a `:one_for_one` supervisor with these children, in order:

- `Cympho.Repo` (Ecto), `{Phoenix.PubSub, name: Cympho.PubSub}`, `{Task.Supervisor, name: Cympho.TaskSupervisor}`
- Registries: `OrchestratorRegistry`, `AgentHeartbeat.Registry` (later: `PluginRegistry`)
- `Cympho.AgentHeartbeat.Supervisor` (dynamic supervisor for per-agent heartbeats)
- `Cympho.Issues.AutoAssignmentReassigner` — reassigns queued issues when agents go idle
- `Cympho.Notifications.NotificationSupervisor`
- `Cympho.Orchestrator.Dispatcher` — dispatches agent runs
- `Cympho.HeartbeatEngine.Watchdog` — timer-based liveness watchdog
- `Cympho.BoardApprovals.BoardApprovalActionExecutor`
- `Cympho.Scheduler` (Quantum cron jobs)
- `{Finch, name: Cympho.Finch}` — HTTP client for adapters and notifications
- `Cympho.Adapters.Registry` + `Cympho.AgentAdapters.HealthChecker`
- `Cympho.PluginRegistry` (Registry) + `Cympho.Plugins.Registry` + `Cympho.Plugins.Supervisor`
- `Cympho.Skills.HotReloader`
- `Cympho.RateLimiting.BroadcastDedup`, `Cympho.RateLimiting.IpRateLimiter`
- `Cympho.EventStore` (ETS event replay buffer)
- `CymphoWeb.Endpoint`

After boot, `Cympho.Adapters.Registry.register_builtin/0` and `Cympho.RoutineTriggers.schedule_all_triggers/0` run.

### Core Domain Flow

1. **Issues** (`Cympho.Issues`) — managed via `Issues.StateMachine`. Issues carry `lock_version` for optimistic concurrency.
2. **Agents** (`Cympho.Agents`) — AI agent entities with roles, adapter types, API keys.
3. **Orchestrator** (`Cympho.Orchestrator`) — GenServer registered by `issue_id`; manages agent sessions, creates comments, transitions issue state, publishes PubSub events.
4. **Agent Adapters** (`Cympho.AgentAdapters`) — behaviour-based backends: `claude_code`, `codex`, `cursor`, `http`, `openclaw`, `process`. `Cympho.Adapters.Registry` resolves with fallback; `HealthChecker` tracks availability.
5. **Heartbeat Engine** (`Cympho.HeartbeatEngine`) — wakeup queue, watchdog, budget checks, secret injection, run tracking.
6. **Agent Runner** (`Cympho.AgentRunner`) — executes agent tasks (mock available for tests).

Supporting contexts under `lib/cympho/`: `Decisions`, `Inbox`, `BoardApprovals`, `ExecutionPolicies`, `WorkProducts`, `ToolCallTraces`, `Wakes`, `Goals`, `Projects`, `Routines`, `RoutineTriggers`, `Workspaces`, `Skills`, `Plugins`, `Secrets`, `Budgets`, `Activities`, `Documents`, `Attachments`, `Labels`, `RecentSearches`, `IssueReadStates`, `GovernanceAuditLogs`, `PrincipalPermissions`, `Companies`, `Users`.

### Multi-Tenancy

Company-based. Most schemas have a `company_id` FK. `CymphoWeb.UserAuth` (LiveView `on_mount`) loads the current user, their companies, and current company into the socket. Broadcasts are scoped per company (e.g., `company:{id}:decisions`, `company:{id}:activity`) — guard against `nil` `company_id` to prevent cross-company event leakage.

### Authentication

- **Users**: session cookies via `Cympho.Authentication` (Argon2 hashing).
- **Agents** (three methods via `CymphoWeb.Plugs.AgentAuth`): JWT (Bearer), API key (`X-API-Key`), legacy `X-Agent-ID`.
- **Board**: `CymphoWeb.Plugs.BoardAuth` verifies board membership for governance mutations.
- **GitHub webhooks**: `CymphoWeb.Plugs.GithubWebhookVerification` validates webhook secrets.

### Web Layer

- **LiveViews** in `lib/cympho_web/live/` with `.heex` templates — primary UI. Major areas: issues, kanban, inbox, agents, governance/approvals, execution policies, workspaces (with exec-workspace, services, previews), skills, plugins (incl. marketplace), routines, projects/goals, settings, org chart, onboarding, search, activity, tool-call traces.
- **Controllers** in `lib/cympho_web/controllers/` — JSON APIs (issues, agents, routines, work products, documents, attachments, MCP, etc.), webhook receivers (`telegram_controller`, `github_controller`), and HTML pages (`page_controller`, `preview_controller`, `company_switcher_controller`).
- **Channels** are flat files at `lib/cympho_web/*_channel.ex` (not in a `channels/` subdirectory): `activity_channel`, `comments_channel`, `company_channel` (event replay on join), `heartbeats_channel`, `issue_channel`, `issues_channel`, `runs_channel`. Companion modules: `events.ex` (broadcast helper), `rate_limiter.ex` (channel-side token bucket), `socket.ex`. Channels carry high-frequency telemetry (heartbeats, runs, activity) where LiveView diffing isn't a fit.
- **Components** in `lib/cympho_web/components/`: `badge`, `card`, `nav_rail`, `company_rail`, `company_switcher`, `company_switcher_static`, `interaction_card`, plus `core_components.ex`.

### Key Subsystems

- **Governance**: Board approvals with voting, execution policies, decisions, decision reversals, audit logs, principal permissions.
- **Decisions** (`Cympho.Decisions`): governance decision events with reversal support, scoped per company on `company:{id}:decisions`.
- **Inbox** (`Cympho.Inbox`): per-agent unread/dismissed/archived state, broadcast on `inbox:{agent_id}`.
- **Agent Actions** (`Cympho.AgentActions`): parses a `cympho-actions` JSON block from agent responses to drive side effects (`create_issue`, `submit_review`, `approve_issue`, `request_changes`, `block_issue`, `comment`, `attach_work_product`, `set_pr_url`, `handoff`).
- **Auto-Assignment** (`Cympho.Issues.AutoAssignmentReassigner`): supervised GenServer that reassigns queued issues when agents go idle.
- **Rate Limiting** (`Cympho.RateLimiting`): per-socket token bucket (10 events/sec), broadcast dedup (~500 ms window), IP-based connection throttling. All routed through GenServers — no public ETS handles.
- **EventStore** (`Cympho.EventStore`): ETS-backed scoped-topic buffer (~200 events per topic) for WebSocket replay on `after_join`, so reconnecting clients catch up cleanly.
- **Plugins**: extensible plugin system with capability-gated host services (see `PLUGIN_SDK.md`).
- **Skills**: skill manifests, loaders, hot-reloader, sandbox execution.
- **Routines**: scheduled routines with webhook triggers and run history.
- **Workspaces**: execution workspaces, environments, leases, probes, runtime services, preview proxying.
- **Finances**: budget enforcement, token usage tracking, billing.
- **Notifications**: multi-channel (email, Telegram, webhook) with supervisor and retry worker.
- **MCP Server**: `Cympho.Mcp.Server` exposes tools to AI models (`list_issues`, `create_issue`, etc.); routed via `mcp_controller.ex`.

### Design System

Dark-mode-first UI inspired by Linear. See `DESIGN.md` for the full spec. Tailwind CSS with custom tokens (brand indigo `#5e6ad2`, canvas/panel/surface layers). Inter Variable font. Kanban drag-and-drop via SortableJS.

## Conventions

- All schemas use `:binary_id` (UUID) primary keys and `:utc_datetime` timestamps.
- Phoenix Context pattern — each domain has a context module as its public API (e.g., `Cympho.Issues`, `Cympho.Agents`, `Cympho.Decisions`, `Cympho.Inbox`).
- Test support modules: `ConnCase`, `DataCase`, `ChannelCase`, `LiveCase`. Pool mode: `Ecto.Adapters.SQL.Sandbox` in manual mode.
- Tool versions pinned in `.tool-versions`: Elixir `1.19.5-otp-28`, Erlang `28.4.3`.
- Production config via env vars in `config/runtime.exs` (`DATABASE_URL`, `SECRET_KEY_BASE`, `APP_HOST`, `POOL_SIZE`, `LIVE_VIEW_SALT`, `S3_BUCKET`/`S3_HOST`/`S3_SCHEME`/`S3_ENDPOINT`, `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION`, `SENTRY_DSN`, `RELEASE_ENV`).
- Bandit HTTP server (not Cowboy).
- Mix aliases: `setup`, `ecto.setup`, `ecto.reset`, `test` (defined in `mix.exs`).
- **SortableJS is loaded via CDN** (`cdn.jsdelivr.net/npm/sortablejs@1.15.6` in `lib/cympho_web/controllers/layouts/root.html.heex`), not as an npm dependency — don't try to bump it in `package.json`.
