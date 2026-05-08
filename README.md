# Cympho

Cympho is a Phoenix LiveView application for running an autonomous software company. Owners create business requests, a CEO routes and prioritizes the work, Product and Design shape it, the CTO breaks technical work into sub-issues, and engineers execute through configurable agent adapters.

The app is multi-tenant by company, with projects, issues, goals, agents, inboxes, execution runs, work products, comments, governance approvals, budgets, secrets, and real-time LiveView/Channel updates.

## Notable Changes

- **Owner intake and browser auth**: `/login` supports real user sessions, while `/dev/login` signs into a local owner account and bootstraps a dev company when needed. In dev, the owner shortcut uses `owner@cympho.local` / `password1234`.
- **Expanded company roster**: new companies now include CEO, CTO, Product Lead, Design Lead, and engineers. Routing and prompts understand product, design, technical, strategic, and engineering work.
- **Review mode by default in dev**: background automation is opt-in, so local browsing and UI testing do not accidentally burn provider credits. The dashboard, kanban board, and issue pages show whether the company is in review or autonomous mode.
- **Adapter provider/model controls**: agent configuration now has adapter-specific controls for Claude Code, Codex, Cursor, OpenClaw, and Process. Codex uses a model selector, Claude Code uses a runtime command, OpenClaw uses provider-qualified models, and Process supports presets plus model forwarding.
- **Claude-compatible cheap-provider support**: Claude Code adapters can use wrapper commands such as `cz` or `cm` through `CYMPHO_CLAUDE_COMMAND`, per-agent command config, runtime env vars, and the local `$HOME/.cld` env loader.
- **Project show page is editable**: project settings, repository URL, environment variables, and recent issues live on `/projects/:id`; `/projects/:id/edit` maps to the same experience.
- **More informative issue pages**: issue detail now surfaces sub-issues, work products, tool-call traces, run failure reasons, log excerpts, and richer agent activity.
- **Improved inbox and dashboard**: inbox filters, counts, agent grouping, and cards are more actionable; dashboard includes operating mode and next-action guidance.

## Setup

Install the versions in `.tool-versions` first. This repo currently targets Elixir `1.19.5-otp-28` and Erlang `28.4.3`.

```bash
mix setup
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000). In development, visit [http://localhost:4000/dev/login](http://localhost:4000/dev/login) to enter as the seeded owner.

Useful commands:

```bash
mix ecto.reset
mix test
mix test test/path/to_test.exs
mix format
mix assets.build
mix assets.deploy
```

`mix test` creates and migrates the test database automatically. The default test database credentials are `paperclip/paperclip@localhost/cympho_test`.

## Running Agents

Development starts in review mode. To enable autonomous execution locally, opt into only the processes you need:

```bash
CYMPHO_ORCHESTRATOR_ENABLED=1 \
CYMPHO_START_HEALTH_CHECKER=1 \
CYMPHO_START_HEARTBEAT_WATCHDOG=1 \
mix phx.server
```

Additional optional workers:

```bash
CYMPHO_START_BOARD_APPROVAL_EXECUTOR=1
CYMPHO_START_SCHEDULER=1
CYMPHO_SCHEDULE_ROUTINE_TRIGGERS=1
```

Claude Code defaults to the `cz` wrapper in dev. Override it when needed:

```bash
CYMPHO_CLAUDE_COMMAND=claude mix phx.server
CYMPHO_CLAUDE_COMMAND=cm mix phx.server
```

For local wrapper commands, keep provider credentials in `$HOME/.cld` or in the app's secret/runtime environment stores. Do not commit provider API keys. Common exports are:

```bash
export ANTHROPIC_BASE_URL="https://..."
export ANTHROPIC_API_KEY="..."
export ANTHROPIC_MODEL="..."
```

Agent configuration supports:

- `claude_code`: runtime command such as `claude`, `cz`, or `cm`, with env forwarding.
- `codex`: OpenAI Codex model selector.
- `cursor`: Cursor CLI command and model selector.
- `openclaw`: provider, provider-qualified model, endpoint, runtime, and harness id.
- `process`: custom command or preset with provider/model forwarding.

The Cursor and OpenClaw model lists are intentionally editable through environment extension points:

```bash
CYMPHO_CURSOR_MODELS="my-cursor-model"
CYMPHO_OPENCLAW_MODELS="provider/custom-model"
```

## Core Workflow

1. Create or select a company.
2. Create projects and attach repository URLs or project-level environment variables.
3. Create an owner issue from `/issues/new`; the request is routed to the CEO when one exists.
4. CEO/Product/Design/CTO roles refine and split work into sub-issues.
5. Engineers execute work through their configured adapter.
6. Issue pages show comments, sub-issues, work products, run history, tool traces, and review outcomes.
7. Inbox and dashboard summarize what needs owner or agent attention.

## Architecture

- `Cympho.Issues` manages issue lifecycle and state transitions.
- `Cympho.Agents` manages agent roster, roles, runtime config, and governance status.
- `Cympho.Orchestrator` coordinates issue execution and publishes updates.
- `Cympho.AgentAdapters` and `Cympho.Adapters` provide backend integrations for Claude Code, Codex, Cursor, HTTP, OpenClaw, and Process.
- `Cympho.HeartbeatEngine` tracks wakes, runs, budgets, secrets, and liveness.
- `Cympho.Inbox`, `Cympho.Dashboard`, `Cympho.Projects`, `Cympho.Goals`, `Cympho.Routines`, `Cympho.Workspaces`, `Cympho.Secrets`, and governance contexts support the operating system around the agents.
- LiveViews in `lib/cympho_web/live/` provide the main UI; Phoenix Channels handle higher-frequency telemetry and event replay.

## Production Notes

Production must set normal Phoenix runtime secrets plus `CYMPHO_ENCRYPTION_KEY`. The app raises in production when the encryption key is missing.

Use managed environment variables or Cympho secrets for provider credentials in production. `$HOME/.cld` is a development convenience for local wrapper commands, not a deployment contract.
