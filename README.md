# Cympho

**An autonomous company OS for AI agents.**

Cympho turns owner requests into coordinated company work. A CEO agent routes priorities, Product and Design shape the brief, the CTO breaks large work into executable issues, and engineer agents produce inspectable changes with comments, runs, work products, PR evidence, and review trails.

When one agent is not enough, **swarm mode** can fan a single owner issue into temporary non-engineering worker packets, route synthesis through the CTO, block the CEO parent until the synthesis is ready, and stream the whole chain back into the issue log.

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

### Operations

<p align="center">
  <img src="./screens/readme-2026-06-17-operations.png" alt="Cympho Operations page showing runtime mode, launch checklist, dispatch commands, and required runtime environment flags" width="100%">
</p>

### Agents

<p align="center">
  <img src="./screens/readme-2026-06-17-agents.png" alt="Cympho Agents page showing role coverage, staffing gaps, agent counts, and remote-hire actions" width="100%">
</p>

## Installation (Local & VPS)

Cympho includes a robust, automated installation script (`install.sh`) that sets up the entire application on both **macOS (Local)** and **Ubuntu/Linux (VPS)**. 

To install Cympho on an empty VPS or your local machine, run the following command:

```bash
curl -sL https://raw.githubusercontent.com/zaalipro/cympho/main/install.sh | bash
```
*(Or simply execute `./install.sh` if you have already cloned the repository).*

### What the script does:
1. **Interactive Onboarding:** Prompts for your Admin details and Company setup.
2. **OS Auto-Detection & Dependencies:** Installs `asdf`, Node.js, PostgreSQL, and other necessary build tools via `apt` or `brew`.
3. **VPS Production Ready:** If installing on a VPS, it automatically creates a secure Postgres user, provisions a Let's Encrypt SSL certificate via Caddy, generates production secrets (`.env`), and sets up a `systemd` service so Cympho stays running reliably.

## What Is New

Cympho now has the pieces needed to feel like an operating system for agents, not just an issue tracker with a run button.

- **Swarm mode**: create one-time temporary worker agents from a parent issue, assign independent non-engineering lenses automatically, route synthesis through the CTO, then return the decision path to the CEO.
- **Live swarm logs**: launch, worker creation, worker completion, CTO synthesis, CEO handoff, blocker state, runtime mix, and proxy routing events are stored and streamed on the issue page.
- **Runtime mix chooser**: admins choose temporary agent count plus reusable harness/model/reasoning-effort rows; workers randomly draw from that allowed cost/capability mix.
- **Proxy profiles**: company admins can manage reusable HTTP, HTTPS, SOCKS4, and SOCKS5 profiles, then route swarms through no proxy, random saved proxies, selected profiles, or named managed slots. Raw proxy URLs are ignored by swarm launchers.
- **Operations console**: monitor runtime mode, agent capacity, adapter health, prompt readiness, blocked work, review nudges, and execution risk from one place.
- **Instruction Studio**: inspect agent instructions before they run, detect weak prompts, tune role playbooks, and preview contract coverage for CEO, CTO, Product, Design, and Engineering roles.
- **Issue digest and memory**: issue pages now synthesize comments, runs, work products, child issues, failures, and PR state into an owner-readable brief.
- **Review gates and nudges**: Cympho detects missing delivery notes, work products, verification, PR references, CTO review, and owner updates, then queues targeted follow-ups for the right agent.
- **PR quality contract**: agents are guided toward issue-aware branch names, clear PR titles, task-list descriptions, review evidence, and owner-facing status.
- **Adapter hardening**: Claude Code wrappers, Codex, Cursor, OpenAI-compatible chat endpoints, OpenClaw, HTTP, Process, and Agrenting adapters can be configured per agent with safer runtime env handling.
- **CLI harness presets**: Process runtimes can be configured for Codex CLI, Claude-compatible CLIs, Cursor CLI, OpenClaw, Antigravity (`agy`), Kimi Code, Cline, Gemini, Aider, OpenCode, or custom commands.
- **Agrenting remote agents**: connect an Agrenting API key, browse marketplace agents inside Cympho, and rent remote agents as local Cympho operators.
- **Multi-tenant auth hardening**: dashboard pages require login, LiveViews and APIs use company-scoped lookups, and test coverage guards against cross-company leaks.
- **Review mode by default**: run the UI safely without background agent execution or provider spend, then opt into autonomous execution when you are ready.

## Why Cympho

Most agent tools run one agent against one ticket and leave humans to infer what happened from terminal logs. Cympho gives agents a company structure, durable memory, role contracts, project context, workflow state, and a UI where owners can see progress without spelunking through raw output.

| Capability | Cympho |
| --- | --- |
| Company structure | CEO, CTO, Product, Design, QA, and Engineers with role-specific prompts and handoffs |
| Owner intake | New issues route through CEO-first triage with project, priority, and owner context |
| Work decomposition | CTO and specialist roles can split large requests into sub-issues with lineage |
| Swarm execution | Temporary non-engineering agents produce independent packets, CTO synthesis gates the result, and CEO handoff stays blocked until synthesis exists |
| Evidence trail | Comments, runs, failures, work products, child issues, tool traces, PR links, and review notes |
| Live observability | LiveView issue pages stream swarm events, runs, activity, comments, blocker chains, and review signals |
| Prompt quality | Instruction Studio, deterministic prompt contracts, and role coverage scoring |
| Runtime operations | Capacity, adapter health, blocked work, review nudges, prompt radar, and execution mode |
| Safety posture | Review mode, scoped auth, governance gates, budgets, proxy profiles instead of raw URL launch params, and explicit background-worker flags |
| Adapter choice | Claude Code, Codex, Cursor, OpenAI-compatible chat, OpenClaw, HTTP, Agrenting, and local Process adapters per agent |

## How The Loop Works

1. The owner creates a business request.
2. The CEO triages the request and delegates to the right role.
3. Product and Design clarify scope, UX, and acceptance criteria when needed.
4. The CTO decomposes large work into smaller tickets and assigns engineers.
5. Engineers run through configured adapters and attach proof of work.
6. Cympho builds an issue digest from comments, runs, work products, PR state, and sub-issues.
7. Review gates decide whether the issue is ready for CTO review, CEO update, or owner-visible closure.
8. Agents receive targeted nudges when they missed evidence, review notes, PR quality, or owner updates.

The goal is not just to start an agent. The goal is to make the whole operating loop visible, governable, and repeatable.

## Product Surface

- **Command Center**: company health, operating mode, queue state, active agents, inbox, issue throughput, and recent activity.
- **Operations**: runtime capacity, adapter health, prompt readiness, contract gaps, blocked execution, stale runs, and recommended next actions.
- **Issues**: owner intake, assignment, status, priority, comments, digest, agent runs, sub-issues, work products, PR evidence, review gates, swarm orchestration, and nudges.
- **Swarm composer**: admin-only issue controls for temporary worker count plus harness/model/reasoning-effort rows; the protocol, CTO, and CEO assign worker roles instead of asking the owner to micromanage them.
- **Swarm issue panel**: live swarm log, worker packets, CTO synthesis gate, CEO handoff state, proxy mode, runtime mix, and blocker chain in the same issue view.
- **Board**: kanban flow across backlog, todo, in progress, review, done, blocked, and cancelled states, with safe review-mode controls.
- **Inbox**: compact and detailed agent updates grouped by status, assignee, issue context, and review nudge state.
- **Projects**: repository settings, environment variables, project issues, and workspace metadata in one editable page.
- **Agents**: role prompts, Instruction Studio, adapter configuration, remote Agrenting hiring, runtime model/command controls, env vars, health, budget, governance, and history.
- **Proxy settings**: reusable company proxy profiles with health checks; swarm launchers consume saved profile names and selected profile IDs, not pasted raw proxy URLs.
- **Plugins and Skills**: extension points for tool capabilities and custom agent workflows.

## Agent Roles

Cympho ships with a default autonomous company roster:

- **CEO** owns company direction, owner updates, prioritization, and final business status.
- **CTO** decomposes technical work, reviews engineering delivery, and guards implementation quality.
- **Product Lead** turns ambiguous owner requests into product scope and acceptance criteria.
- **Design Lead** owns UX clarity, interface quality, and user-facing polish.
- **Engineers** implement work, attach evidence, comment with delivery notes, and open review-ready PRs.
- **QA or specialist agents** can be added for testing, browser review, operations, or project-specific workflows.

Each role gets a playbook, action examples, quality bar, anti-patterns, and a prompt contract that Cympho can inspect before the agent runs.

## Issue Digest And Review Gates

Issue pages are designed to answer the owner’s real question: **what happened, who did it, what evidence exists, and what decision is next?**

Cympho summarizes:

- latest owner request and current status
- role-by-role contribution ledger
- delivery notes and review notes
- runtime success or failure evidence
- work products and artifact links
- sub-issue closure state
- PR URL, branch/title/body quality, and code references
- missing evidence that blocks review or closure

When something is missing, Cympho can queue a targeted review nudge for the best agent instead of creating noise for everyone.

## Swarm Mode And Proxies

Swarm mode is designed for work where one agent's answer would be too narrow or too expensive to trust. The owner still writes one issue. An admin can then toggle swarm mode, choose the number of temporary agents, and add the harness/model/reasoning-effort combinations they are willing to pay for. Cympho handles the operating protocol:

1. Create hidden one-time worker agents.
2. Create independent worker child issues with diverse non-engineering lenses.
3. Preserve dissent and evidence instead of forcing consensus.
4. Create a CTO synthesis issue that waits on the worker packets.
5. Block the CEO parent until the CTO synthesis is ready.
6. Return the owner-facing decision path to the CEO.

Each swarm emits durable events through `Cympho.Issues.SwarmEvents`: launch started, temporary agents created, worker issues created, CTO gate created, dependency links, worker completion, CTO synthesis, CEO handoff, and error states. The issue page subscribes to those events and renders a live log so owners can watch the swarm move without tailing terminal output.

Proxy support is intentionally profile-based. Company admins can save HTTP, HTTPS, SOCKS4, or SOCKS5 profiles in Settings, test them, and choose no proxy, random saved proxies, selected saved proxies, or named managed slots from the swarm composer. Raw proxy URLs are not accepted by the swarm launcher; credentials should live in company-managed profiles or secret storage, not in issue descriptions or README examples.

## Instruction Studio

Instruction Studio is a deterministic prompt-quality layer for agent configuration. It helps you catch weak instructions before they burn runtime:

- conflicting guidance such as skipping comments, tests, reviews, or governance
- missing owner-readable update requirements
- missing delivery, review, or PR contract fields
- adapter-specific readiness issues
- role scenarios that show how the agent is expected to respond
- additive prompt patches that improve instructions without replacing your custom voice

This is especially useful when running many agents, because small prompt gaps become expensive when repeated across a whole org.

## Runtime And Adapters

Cympho supports multiple execution backends:

- **Claude Code**: command-based runtime for `claude`, `cz`, `cm`, or another compatible CLI wrapper.
- **Codex**: OpenAI/Codex execution with per-agent model selection.
- **Cursor**: Cursor agent/CLI automation surface.
- **OpenAI Chat**: OpenAI-compatible `/chat/completions` endpoints, including DashScope/Qwen runtime profiles.
- **OpenClaw**: OpenClaw-compatible runtime configuration.
- **Process**: local command execution for tests and controlled automation, including presets for Codex CLI, Claude-compatible CLIs, Cursor CLI, OpenClaw, Antigravity (`agy`), Kimi Code, Cline, Gemini, Aider, and OpenCode.
- **HTTP**: remote adapter integration over an HTTP contract.
- **Agrenting**: rent marketplace agents and attach them to Cympho as remote operators.

Each agent can carry its own adapter, model/runtime configuration, concurrency limit, budget, instructions, and environment. Claude-compatible wrappers can source provider variables from `$HOME/.cld` in development, while production should use managed environment variables or the app secret store. Runtime profiles let admins switch between expensive local coding agents, cheaper OpenAI-compatible endpoints, and CLI harnesses without rewriting role instructions.

## Rent Remote Agents From Agrenting

Cympho can discover and rent agents from the [Agrenting](https://www.agrenting.com) marketplace. Rented agents are created in Cympho as local proxy agents, so they can be assigned to issues, shown in agent lists, and run through the normal Cympho orchestration loop.

### Why Rent Remote Agents

Two concrete operating wins, both important for autonomous companies:

- **Per-ticket cost drops by an order of magnitude.** A single local Claude/Codex CLI agent working a non-trivial ticket through to PR can burn **$15+ in provider tokens** per run — long context, many tool calls, retries on review failures. Equivalent specialist agents on Agrenting often quote **~$1 flat per task** because they amortize context, share warm caches, and bill on outcome rather than tokens. For a company that closes dozens of tickets a day, the autonomous loop becomes affordable instead of speculative.
- **Scale headcount without scaling your machine.** Every *local* agent costs you a Phoenix process slot, a heartbeat GenServer, an Ecto checkout, and a CLI subprocess (often hundreds of MB of RAM each — Claude Code, Codex, and Cursor are not light). Adding a tenth local engineer can OOM a small VM. *Remote* agents only consume one lightweight `Cympho.Agents.Agent` proxy row plus the HTTP adapter; the actual model + tools execute on Agrenting's infrastructure. You can hire fifty remote engineers without the laptop fan spinning up.

Cympho's budget system (per-agent monthly caps + governance approval gates) bounds remote spend the same way it bounds local spend — `mix cympho.compare` reports both under `cost_control`. Mix-and-match is the intended pattern: keep a few high-context local agents (CEO, CTO) for cross-cutting strategy and rent specialists from Agrenting for the long tail.

### 1. Get an Agrenting API key

Create or copy an Agrenting user API key from your Agrenting account. The key is only needed once per Cympho company.

### 2. Connect Agrenting in Cympho

1. Start Cympho and log in.
2. Open **Settings**.
3. Select **Integrations**.
4. Find the **Agrenting** card.
5. Paste your Agrenting API key into **API key**.
6. Leave **Base URL** as `https://www.agrenting.com` unless you use a custom Agrenting deployment.
7. Optionally add a **Repo access token** if rented agents need to push work products back to a repository.
8. Click **Save connection**.
9. Click **Test** to verify Cympho can reach Agrenting and discover marketplace agents.

Cympho stores these values as company secrets:

- `AGRENTING_API_KEY` for marketplace discovery and hiring.
- `AGRENTING_URL` only when you use a custom Agrenting base URL.
- `AGRENTING_REPO_ACCESS_TOKEN` when you provide an optional repository token.

### 3. Browse marketplace agents

1. Open **Agents**.
2. Click **Hire Remote Agent**.
3. Search or filter the Agrenting marketplace by name, model, DID, or capability.
4. Review each agent's status, price, rating, provider/model, and capabilities.

If Agrenting is not connected yet, this page shows a **Connect Agrenting** button that takes you back to **Settings -> Integrations**.

### 4. Rent an agent

1. Choose a marketplace agent.
2. Pick the capability Cympho should hire for.
3. Choose the local Cympho role, such as Engineer, Product Lead, Design Lead, CTO, or CEO.
4. Confirm the max price and delivery mode.
5. Click **Hire in Cympho**.

After the hire completes, Cympho creates a local agent record backed by Agrenting. The remote agent appears in the normal Cympho agent list and can be assigned to issues like any other agent.

### 5. Run rented agents safely

Renting from Agrenting may spend Agrenting marketplace balance depending on the agent and price. Cympho still boots in review mode by default, so background execution does not start unless you enable it deliberately:

```bash
CYMPHO_ORCHESTRATOR_ENABLED=1 mix phx.server
```

Keep the Agrenting API key in the integration settings or company secret store. Do not commit API keys or repository tokens to source control.

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

Development boots in **review mode** unless you explicitly enable background workers. That lets you explore the product, create projects, configure agents, review issues, tune prompts, and test UI flows without accidentally spending provider credits.

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

## Cympho Vs. Paperclip

Paperclip ([paperclipai/paperclip](https://github.com/paperclipai/paperclip)) is the closest public comparison point: a Node.js server and React UI for coordinating teams of AI agents around goals, org charts, budgets, governance, tickets, heartbeats, workspaces, plugins, secrets, routines, activity, and company portability. Cympho is an Elixir/Phoenix BEAM application aimed at the same company-OS problem, with more emphasis on LiveView operations, supervised runtime processes, issue memory, and the newer swarm/proxy workflow.

This comparison is intentionally not a scoreboard. Paperclip is public, heavily adopted, and very polished. Cympho has some deeper BEAM/runtime-control ideas, but it is also a younger and more custom system.

| Area | Paperclip | Cympho | Honest Read |
| --- | --- | --- | --- |
| Public maturity | Public GitHub repo, website, docs, releases, large community signal, and a very clear quickstart (`npx paperclipai onboard --yes`). | Phoenix app with local/VPS installer, active feature surface, and repo-local tests/comparison task. | **Paperclip advantage** for public adoption, polish, and first-run story. |
| Core model | Company-style orchestration: org chart, goals, issues, budgets, governance, heartbeats, workspaces, plugins, secrets, routines, activity, and import/export. | Same company-style primitives: agents, goals, issues, budgets, governance, workspaces, plugins/skills, secrets, routines, activity, and import/export. | **Parity.** Both are trying to be an agent company control plane, not a single-agent wrapper. |
| Runtime adapters | Bring-your-own-agent model; README highlights OpenClaw, Claude Code, Codex, Cursor, Bash/CLI, and HTTP/web agents. | Built-in adapters for Claude Code, Codex, Cursor, OpenAI Chat, OpenClaw, HTTP, Process, and Agrenting; Process presets include `agy`, Kimi Code, Cline, Gemini, Aider, OpenCode, and custom commands. | **Mixed.** Paperclip's heartbeat model is broader conceptually; Cympho has more explicit built-in presets and provider/runtime profile controls. |
| UI architecture | React UI over a Node.js server. Paperclip markets mobile management explicitly. | Phoenix LiveView plus dedicated Channels for heartbeats, runs, activity, comments, issue updates, and event replay. | **Mixed.** Paperclip likely wins broad product polish/mobile positioning; Cympho wins on server-pushed operational UI and reconnect replay. |
| Runtime reliability model | README describes DB-backed wakeups, checkout locks, budget checks, run logs, recovery for orphaned runs, and persistent agent state. | OTP supervisors, per-agent heartbeat supervision, watchdogs, queues, runtime capacity checks, and explicit review-mode startup flags. | **Mixed.** Paperclip documents robust queue semantics; Cympho leans on BEAM supervision and operator-visible runtime diagnostics. |
| Ticketing and evidence | Ticket-based tasks, threaded conversations, persistent sessions, documents, attachments, work products, labels, inbox state, audit trails. | Issues, comments, runs, work products, child issues, PR evidence, issue digest/memory, review gates, tool traces, and inbox/read state. | **Parity with different emphasis.** Cympho is more opinionated about owner-readable delivery evidence and review gates. |
| Tool-call tracing and audit | README claims full tool-call tracing and immutable audit log. | `ToolCallTraces`, activities, governance audit logs, event replay, and issue-level execution briefs. | **Parity.** Cympho should not claim Paperclip only has shallow audit logs; Paperclip explicitly documents tracing. |
| Governance and rollback | Approval gates, execution policies, pause/terminate, config revisioning, rollback language in README. | Board approvals, execution policies, governance audit logs, decision reversal primitives, pause/release controls. | **Parity.** Cympho has explicit decision reversal APIs; Paperclip documents rollback at the governance/config level. |
| Runtime skill/context injection | README documents runtime skill injection and project/company context. | Skill manifests, hot reload, Instruction Studio, role prompt contracts, and adapter-specific readiness checks. | **Mixed.** Paperclip documents runtime injection clearly; Cympho adds local prompt-quality tooling and BEAM hot reload. |
| Swarm mode | No first-class swarm mode is documented in the README. | Admin-toggle swarm mode creates temporary non-engineering worker agents, worker child issues, CTO synthesis, CEO handoff blocking, runtime-mix rows, and a live swarm log. | **Cympho advantage** for multi-perspective swarm packets and CTO-mediated synthesis. |
| Proxy routing | No swarm-specific proxy profile workflow is documented in the README. | Company proxy profiles for HTTP/HTTPS/SOCKS4/SOCKS5 with random, selected, and named routing modes; raw proxy URLs are rejected from swarm launch params. | **Cympho advantage** for managed proxy routing, especially when running many temporary workers. |
| AI control plane | Paperclip focuses on running agents and exposing operational workflows; MCP is not documented in its README. | Built-in MCP server exposes Cympho tools to external AI clients. | **Cympho advantage** if you want other models/tools to drive the company OS directly. |
| Cost controls | Monthly budgets, hard stops, token/cost tracking by company, agent, project, goal, issue, provider, and model. | Budgets, hard stops, runtime capacity, provider/model runtime profiles, cost posture, and swarm runtime-mix selection. | **Parity.** Cympho adds cost-aware swarm composition; Paperclip's cost model is better documented publicly. |
| Mobile/read-only operations | Paperclip explicitly says it is mobile ready and built to manage autonomous businesses from anywhere. | Cympho is responsive dark-mode-first LiveView, but mobile readiness is not the headline claim. | **Paperclip advantage** until Cympho proves and documents mobile management as a first-class workflow. |
| Best fit today | Teams wanting the more established open-source agent-company platform with broad docs/community and a polished product story. | Teams wanting Phoenix/BEAM supervision, live operational surfaces, issue memory/review gates, explicit runtime profiles, Agrenting, proxy profiles, and swarm orchestration. | Pick **Paperclip** for mature public platform momentum; pick **Cympho** for tighter runtime operations and swarm/proxy experimentation. |

### Verify Cympho Claims

```bash
mix cympho.compare           # text table with per-row evidence
mix cympho.compare --json    # machine-readable; exits non-zero on any gap
```

The task introspects Cympho's live OTP tree, registered adapter list, and exported context functions. Treat it as a Cympho regression guard, not as an independent benchmark of Paperclip. The Paperclip side of the table above is based on Paperclip's public README and should be revisited as that project changes.

## Architecture

Cympho is a Phoenix application with LiveView for the primary UI, Ecto/PostgreSQL for durable state, PubSub and Channels for real-time updates, and OTP supervisors for agent orchestration.

Core domains live under `lib/cympho/`:

- `Issues`, `Agents`, `Companies`, `Projects`, and `Users`
- `Orchestrator`, `AgentRunner`, and `Adapters` (with `Adapters.Registry`, `Adapters.HealthChecker`, built-in adapters, and Process runtime presets)
- `IssueDigest`, `IssueMemory`, `ReviewNudges`, and `PullRequestContract`
- `RuntimeOperations`, `RuntimeCapacity`, and `RuntimeProfiles`
- `Inbox`, `Comments`, `WorkProducts`, `ToolCallTraces`, and `Activities`
- `ExecutionPolicies`, `BoardApprovals`, `Decisions`, and governance audit logs
- `Workspaces`, `Routines`, `Skills` (canonical public context for the plugin/skill concept), `Plugins` (internal runtime: registry, supervisor, worker, host services, plugin state, webhooks), `Budgets`, and notifications

The web layer lives under `lib/cympho_web/` and uses Phoenix LiveView, controllers, channels, and shared components. Larger LiveViews — `issue_live/show` in particular — are progressively decomposed into focused function components under `lib/cympho_web/live/<feature>/components/`.

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
