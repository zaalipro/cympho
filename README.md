# Cympho

**An autonomous company OS for AI agents.**

Cympho turns owner requests into coordinated company work. A CEO agent routes priorities, Product and Design shape the brief, the CTO breaks large work into executable issues, and engineer agents produce inspectable changes with comments, runs, work products, and review trails.

<p align="center">
  <img src="./screen1.png" alt="Cympho command center showing operating mode, agent capacity, inbox, activity, and company roster" width="100%">
</p>

<p align="center">
  <img src="./screen2.png" alt="Cympho kanban board showing multi-project issue flow and agent execution status" width="100%">
</p>

## Why Cympho

Cympho is built for people who want more than a chat box around coding agents. It gives agents a company structure, durable memory, project context, workflow state, and a UI where owners can see what happened instead of guessing from terminal logs.

- **Owner-first intake**: create an issue and route it to the CEO, with project context and priority attached from the start.
- **Agent org chart**: CEO, CTO, Product, Design, QA, and Engineers each get role-specific prompts, permissions, and handoff rules.
- **Multi-project execution**: keep issues, agents, repository settings, environment variables, and activity scoped by company and project.
- **Review mode by default**: run the UI safely without background agent execution or provider spend, then opt into autonomous mode when ready.
- **Evidence-rich issue pages**: inspect sub-issues, agent comments, runs, failures, PR links, work products, and tool traces.
- **Adapter flexibility**: configure Claude Code, Codex, Cursor, OpenClaw, HTTP, or local process adapters per agent.

## What It Does

1. The owner creates a business request.
2. The CEO triages the request and delegates to the right role.
3. Product and Design clarify scope, user experience, and acceptance criteria when needed.
4. The CTO decomposes large work into smaller tickets and assigns engineers.
5. Engineers run through configured adapters and attach proof of work.
6. CTO and CEO review progress, comment on outcomes, and keep the owner informed.

The goal is not just to run an agent. The goal is to make the whole operating loop visible, governable, and repeatable.

## Quick Start

Prerequisites are pinned in `.tool-versions`:

- Elixir `1.19.5-otp-28`
- Erlang `28.4.3`
- PostgreSQL with the local credentials expected by `config/dev.exs`

```bash
mix setup
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000).

For local development, use the dev owner shortcut:

```text
http://localhost:4000/dev/login
```

Seeded dev credentials:

```text
Email: owner@cympho.local
Password: password1234
```

## Running Safely

Development boots in **review mode** unless you explicitly enable background workers. That lets you explore the product, create projects, configure agents, review issues, and test UI flows without accidentally spending provider credits.

Common runtime flags:

```bash
CYMPHO_ORCHESTRATOR_ENABLED=1 \
CYMPHO_START_HEALTH_CHECKER=1 \
CYMPHO_START_SCHEDULER=1 \
CYMPHO_SCHEDULE_ROUTINE_TRIGGERS=1 \
mix phx.server
```

Claude Code-compatible wrappers can be selected without renaming the real `claude` binary:

```bash
CYMPHO_CLAUDE_COMMAND=cz mix phx.server
```

The app can source provider environment from `$HOME/.cld` for local wrapper commands, and agent runtime settings can inject provider variables such as model names, base URLs, and API keys. Keep secrets in local environment files or the app secret store; do not commit them.

## Agent Adapters

Cympho supports multiple execution backends:

- **Claude Code**: command-based runtime for `claude`, `cz`, `cm`, or another compatible CLI wrapper.
- **Codex**: model-driven OpenAI/Codex execution with per-agent model selection.
- **Cursor**: editor-oriented automation adapter surface.
- **OpenClaw**: OpenClaw-compatible runtime configuration.
- **Process**: local command execution for tests and controlled automation.
- **HTTP**: remote adapter integration over an HTTP contract.

Each agent can carry its own adapter, model/runtime configuration, concurrency limit, budget, instructions, and environment.

## Product Surface

- **Command Center**: company health, operating mode, queue state, active agents, inbox, and recent activity.
- **Issues**: owner intake, assignment, status, priority, comments, agent runs, sub-issues, work products, and PR evidence.
- **Board**: kanban flow across backlog, todo, in progress, review, done, and blocked states.
- **Inbox**: agent updates grouped by status, assignee, and issue context.
- **Projects**: repository settings, environment variables, project issues, and workspace metadata in one editable page.
- **Agents**: role prompts, adapter configuration, runtime model/command controls, health, budget, and governance state.
- **Plugins and Skills**: extension points for tool capabilities and custom agent workflows.

## Architecture

Cympho is a Phoenix application with LiveView for the primary UI, Ecto/PostgreSQL for durable state, PubSub and Channels for real-time updates, and OTP supervisors for agent orchestration.

Core domains live under `lib/cympho/`:

- `Issues`, `Agents`, `Companies`, `Projects`, and `Users`
- `Orchestrator`, `AgentRunner`, `AgentAdapters`, and `Adapters.Registry`
- `Inbox`, `Comments`, `WorkProducts`, `ToolCallTraces`, and `Activities`
- `ExecutionPolicies`, `BoardApprovals`, `Decisions`, and governance audit logs
- `Workspaces`, `Routines`, `Skills`, `Plugins`, `Budgets`, and notifications

The web layer lives under `lib/cympho_web/` and uses Phoenix LiveView, controllers, channels, and shared components.

## Useful Commands

```bash
mix setup                         # Install deps, create DB, migrate, seed
mix ecto.reset                    # Drop, recreate, migrate, seed
mix test                          # Run the test suite
mix test test/path/to_test.exs    # Run one test file
mix format                        # Format Elixir code
mix assets.build                  # Build dev assets
mix assets.deploy                 # Build production assets
```

## Production Notes

Set the usual Phoenix release environment variables, plus a Cympho encryption key:

```bash
SECRET_KEY_BASE=...
DATABASE_URL=...
APP_HOST=...
LIVE_VIEW_SALT=...
CYMPHO_ENCRYPTION_KEY=32-byte-or-longer-secret
```

Background execution should be enabled deliberately in production, with adapter credentials, budgets, governance policies, and project repository settings configured before agents are allowed to run.

## Documentation

- `AGENTS.md` / `CLAUDE.md`: repository guidance for AI coding agents
- `DESIGN.md`: UI and design-system notes
- `PLUGIN_SDK.md`: plugin extension surface
