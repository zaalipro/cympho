---
spec_id: 02
feature_name: architecture_consolidations_phase_1
status: awaiting-approval
created: 2026-05-28
last_updated: 2026-05-28
source_prompt: |
  now create a spec file for this — where "this" refers to the broad architecture
  audit captured in /Users/zaali/.claude/plans/please-review-app-s-architecture-enumerated-alpaca.md.
  After clarification, the user scoped this spec to the top three high-impact
  consolidations: (a) merge the duplicate Plugins/Skills contexts, (b) collapse
  the dual `lib/cympho/adapters/` and `lib/cympho/agent_adapters/` trees, and
  (c) decompose the 3,112-LoC `lib/cympho_web/live/issue_live/show.ex` into
  focused LiveComponents. NFRs are behaviour-preservation only — no behavioural
  changes are intended.
assumptions:
  - The canonical public context for the plugin/skill concept is `Cympho.Skills` and the canonical name in user-facing copy is "Skill". Reason: the `skill_live/` LiveViews are the user-facing surface; the `Cympho.Plugins` module is 101 LoC of CRUD whereas `Cympho.Skills` (192 LoC) already owns the agent-skill association logic and the `agent_skills` join table.
  - `Cympho.Plugins` survives only as an *internal* runtime namespace covering the supervisor, worker, registry, host services, plugin state, and webhook plumbing. Reason: those modules are runtime infrastructure, not domain CRUD; renaming every internal supervisor/worker to "Skill" would be a far larger blast radius than the cleanup warrants.
  - The single canonical DB schema for the `plugins` table is `Cympho.Skills.Plugin`. Reason: it already maps to the same table as `Cympho.Plugins.Plugin`, carries the `manifest_errors` field used by the hot reloader, and is the schema referenced by the `agent_skills` join. The duplicate `lib/cympho/plugins/plugin.ex` is the one to delete.
  - The `Cympho.Skills.Skill` schema (separate `skills` table) is treated as out-of-scope for this spec and stays as-is. Reason: it lacks the `author`, `status`, `capabilities` fields and is referenced by its own LiveViews independent of the Plugin schema; folding it into the Plugin schema is a separate, larger migration.
  - The canonical `claude_code_adapter` implementation is `lib/cympho/adapters/claude_code_adapter.ex` (the smaller 5,442-LoC version, registered via `Cympho.Adapters.Registry`); the larger `lib/cympho/agent_adapters/claude_code_adapter.ex` (10,368 LoC) is legacy and will be deleted. Reason: the registry only knows about the `Cympho.Adapters` tree, and the shim `lib/cympho/agent_adapters.ex` already routes resolution there. This must be verified during TASK-001 by confirming no `use Cympho.AgentAdapters.Adapter` (or direct module reference) exists outside the legacy file itself before deletion.
  - The shim module `lib/cympho/agent_adapters.ex` is retained for one release as a deprecation soft-landing, then removed in a follow-up spec. Reason: belt-and-braces — any forgotten downstream caller gets a Logger warning rather than a CompileError. The internal codebase migrates off it immediately.
  - LiveComponent extraction strategy for `issue_live/show.ex` uses **stateful** `Phoenix.LiveComponent` modules for sections that own user events (comments, work products, review gates, agent panel) and **stateless** `Phoenix.Component` function components for pure-rendering subtrees (header, description, child issues tree, activity timeline). Reason: stateful components allow `handle_event` and per-section assigns isolation; function components are simpler when no internal state is needed.
  - PubSub subscriptions stay on the parent LiveView mount; child LiveComponents receive updates via `send_update/2` rather than subscribing independently. Reason: keeps the message routing single-sourced and avoids duplicate subscriptions on remount.
  - No deprecation of existing public function names is required outside `Cympho.AgentAdapters.*` — every `Cympho.Skills.*` function survives because Skills is the canonical context. Reason: minimizes call-site churn; only `Cympho.Plugins.*` callers (6 known LiveView files plus 2 internal modules) migrate.
  - Behaviour-preservation is verified end-to-end via `mix test` plus a manual smoke test of the issue show page; no new test infrastructure is introduced. Reason: the existing suite already covers the touched contexts; the refactor's value rests on preserving the current observable surface, not extending it.
---

# 02 — Architecture Consolidations, Phase 1 (Plugins/Skills Merge, Dual Adapter Cleanup, Issue Show LiveView Split)

## Requirements Document

### Introduction

This spec captures the first phase of architectural consolidation work surfaced by the May 2026 architecture audit. The audience is the Cympho engineering team. The goals are to (1) eliminate the duplicate `Cympho.Plugins` / `Cympho.Skills` context pair so there is a single public domain API for the plugin/skill concept, (2) collapse the parallel `lib/cympho/adapters/` and `lib/cympho/agent_adapters/` trees so there is a single adapter behaviour, registry, and Claude Code implementation, and (3) decompose the 3,112-LoC `lib/cympho_web/live/issue_live/show.ex` into focused LiveComponents and function components so future work on the issue page is tractable. The business value is reduced cognitive load for every contributor touching these modules, lower drift risk between sibling implementations, and a faster editor / formatter / Dialyzer loop on the issue show page.

### Functional Requirements

#### REQ-001 — Single canonical context for the plugin/skill concept

**User Story**

> As a Cympho engineer, the agent wants exactly one public context module exposing plugin/skill CRUD and toggle operations, so that there is no ambiguity about which module to call and no risk of two contexts mutating the same row through divergent code paths.

**Acceptance Criteria**

1. **AC-001** — WHEN the consolidation work is complete THEN `Cympho.Plugins` SHALL no longer expose any public CRUD function for the `plugins` table (`list_plugins/1`, `get_plugin/1`, `get_company_plugin/2`, `get_plugin_by_identifier/2`, `create_plugin/1`, `update_plugin/2`, `delete_plugin/1`, `toggle_plugin/1`, `update_plugin_settings/2`, `change_plugin/2`).
2. **AC-002** — WHEN any caller previously importing `Cympho.Plugins` for CRUD invokes the new canonical API THEN the call SHALL succeed against `Cympho.Skills` with an equivalent function signature and identical observable behaviour (return shape, error tuple, broadcast topic).
3. **AC-003** — WHILE both schemas exist in `lib/`, exactly one schema module SHALL declare `schema "plugins"` (the surviving `Cympho.Skills.Plugin`); `lib/cympho/plugins/plugin.ex` SHALL be deleted.
4. **AC-004** — WHEN a developer runs `grep -r "Cympho.Plugins\." lib/ test/ --include="*.ex" --include="*.heex"` THEN the only remaining references SHALL be to internal runtime modules under `Cympho.Plugins.*` (Registry, Supervisor, Worker, HostServices, PluginState, PluginLog, PluginWebhook, ExamplePlugin); no result SHALL reference removed CRUD functions.
5. **AC-005** — WHEN any LiveView under `lib/cympho_web/live/plugin_live/` or `lib/cympho_web/live/plugin_marketplace_live/` mounts after the consolidation THEN it SHALL render the same UI it rendered before, reading from `Cympho.Skills` instead of `Cympho.Plugins`.
6. **AC-006** — WHEN the consolidation is complete THEN `Cympho.Skills.update_skill_status/2` SHALL no longer reach into `Cympho.Plugins.update_plugin/2`; it SHALL mutate the row directly through Skills-owned changeset logic.
7. **AC-007** — WHERE the same identifier is used to look up a plugin (`Cympho.Plugins.get_plugin_by_identifier/2` previously) THE SYSTEM SHALL expose `Cympho.Skills.get_plugin_by_identifier/2` (newly added, operating on `Cympho.Skills.Plugin`) as the sole resolver and return identical results for identical inputs. The pre-existing `Cympho.Skills.get_skill_by_identifier/2` continues to resolve against the separate `skills` table (`Cympho.Skills.Skill`) and is unaffected by this consolidation.

#### REQ-002 — Single canonical adapter system

**User Story**

> As a Cympho engineer, the agent wants a single adapter behaviour, registry, and `claude_code_adapter` implementation, so that adding or modifying an adapter is unambiguous and no risk exists of two implementations diverging silently.

**Acceptance Criteria**

1. **AC-008** — WHEN the consolidation is complete THEN exactly one behaviour module SHALL declare adapter callbacks: `Cympho.Adapters.Adapter`; `lib/cympho/agent_adapters/adapter.ex` SHALL be deleted.
2. **AC-009** — WHEN the consolidation is complete THEN exactly one Claude Code adapter implementation SHALL exist: `lib/cympho/adapters/claude_code_adapter.ex`; `lib/cympho/agent_adapters/claude_code_adapter.ex` SHALL be deleted.
3. **AC-010** — WHEN the consolidation is complete THEN exactly one mock adapter SHALL exist: `lib/cympho/adapters/mock_adapter.ex`; `lib/cympho/agent_adapters/mock_adapter.ex` SHALL be deleted.
4. **AC-011** — WHEN the consolidation is complete THEN `lib/cympho/agent_adapters/health_checker.ex` SHALL be relocated to `lib/cympho/adapters/health_checker.ex` (module name updated to `Cympho.Adapters.HealthChecker`), with all references updated.
5. **AC-012** — WHILE the deprecation soft-landing period is active, the shim `Cympho.AgentAdapters` SHALL continue to delegate `register/2`, `resolve/1`, `fallback_chain/1`, `all_types/0`, and `lookup/1` to `Cympho.Adapters`, with each delegating call emitting `Logger.warning("Cympho.AgentAdapters is deprecated; call Cympho.Adapters directly", ...)`.
6. **AC-013** — WHEN the consolidation is complete THEN no file under `lib/` other than `lib/cympho/agent_adapters.ex` SHALL reference `Cympho.AgentAdapters.*`; all internal callers SHALL invoke `Cympho.Adapters.*` directly.
7. **AC-014** — WHEN the adapter registry boots in `Cympho.Application.start/2` THEN `Cympho.Adapters.Registry.register_builtin/0` SHALL still register the seven built-in adapter types (`:claude_code`, `:codex`, `:cursor`, `:http`, `:openclaw`, `:process`, `:agrenting`) and the optional `:mock` in the test environment.
8. **AC-015** — WHEN `Cympho.Adapters.HealthChecker` ticks after consolidation THEN it SHALL update agent health status using the same semantics as the pre-consolidation `Cympho.AgentAdapters.HealthChecker` (same `Agents.update_agent/2` call, same recovery and failure transitions).

#### REQ-003 — Decompose issue show LiveView into focused components

**User Story**

> As a Cympho engineer, the agent wants the 3,112-LoC `IssueLive.Show` module split into focused LiveComponents and stateless function components, so that the formatter / Dialyzer / editor loop is fast, event handlers are co-located with their UI, and future feature work touches only the relevant section.

**Acceptance Criteria**

1. **AC-016** — WHEN the decomposition is complete THEN `lib/cympho_web/live/issue_live/show.ex` SHALL be under 1,200 LoC and contain only the parent LiveView lifecycle callbacks (`mount/3`, `handle_params/3`), PubSub message routing in `handle_info`, top-level `render/1`, and helpers that genuinely apply to multiple child components.
2. **AC-017** — WHEN the decomposition is complete THEN `lib/cympho_web/live/issue_live/show.html.heex` SHALL be under 700 LoC and SHALL invoke at least six child components via `<.live_component>` or function-component syntax for the major visual sections (header, description, review gates, work products, child issues, activity, agent panel, comments).
3. **AC-018** — WHEN a user loads the issue show page after the decomposition THEN every visible UI element (header, status badge, priority badge, assignee combobox, description card, review gates panel, agent contributions, decomposition tree, activity timeline, work products list, agent right-side panel, comments) SHALL render with the same content and styling as before.
4. **AC-019** — WHEN any of the 41 `handle_event` clauses fire after the decomposition THEN the resulting state mutation and broadcast SHALL produce identical observable side effects (same Repo writes, same PubSub broadcasts, same flash messages, same redirects) as before.
5. **AC-020** — WHEN any of the 20 `handle_info` messages arrive after the decomposition THEN the parent LiveView SHALL route the update to the affected child component(s) via `send_update/2`, and the rendered output SHALL match the pre-decomposition output for the same input event.
6. **AC-021** — WHILE the LiveView is mounted, PubSub subscriptions SHALL remain on the parent LiveView (`Issues.subscribe/1`, `Comments.subscribe/1`, `CymphoWeb.Events.subscribe_to_runs/1`, `Documents.subscribe/1`, `IssueReadStates.subscribe/1`); no child LiveComponent SHALL call `Phoenix.PubSub.subscribe/2`.
7. **AC-022** — IF a child LiveComponent crashes during render THEN the parent LiveView SHALL continue to render the unaffected sections, and the crash SHALL be reported via the existing Sentry handler with metadata including the child component module name.

### Non-Functional Requirements

#### NFR-001 — Performance

This refactor must not regress performance. All NFR-001 criteria are about preserving today's observable timing.

1. **AC-023** — WHEN the issue show page is mounted post-decomposition THEN the time-to-first-render SHALL be within ±10% of the pre-decomposition value as measured by Phoenix LiveView's existing telemetry events (`:phoenix, :live_view, :mount, :stop`).
2. **AC-024** — WHEN `mix test` runs to completion post-consolidation THEN the total wall-clock time SHALL be within ±10% of the pre-consolidation baseline.
3. **AC-025** — WHEN any consolidated context function (`Cympho.Skills.list_skills/1`, `Cympho.Skills.toggle_skill/1`, `Cympho.Adapters.resolve_agent/1`) is invoked THEN the number of SQL queries issued per call SHALL be equal to the pre-consolidation count.

#### NFR-002 — Security

1. **AC-026** — WHEN any `Cympho.Skills.*` function is called with a `company_id` filter THEN it SHALL enforce the same tenant scoping as the pre-consolidation `Cympho.Plugins.*` equivalent, with no broadening of returned rows across tenants.
2. **AC-027** — WHILE the deprecation shim `Cympho.AgentAdapters` exists, it SHALL NOT introduce any new code path that bypasses tenant scoping or adapter validation.
3. **AC-028** — WHEN the consolidation merges the two `plugins` table schemas THEN no new field SHALL be added that exposes previously private data (e.g., raw API keys, internal config secrets); the surviving schema is the existing `Cympho.Skills.Plugin` shape only.

#### NFR-003 — Accessibility

1. **AC-029** — WHEN the issue show page renders after the decomposition THEN every keyboard interaction (Tab order, Esc to close modals, Enter to submit comment forms, `j`/`k` navigation if present) SHALL behave identically to pre-decomposition.
2. **AC-030** — WHEN a screen reader navigates the decomposed issue show page THEN the heading hierarchy (`h1`, `h2`, `h3`) SHALL be preserved with no new heading-level skips introduced by the component boundaries.

#### NFR-004 — Observability

1. **AC-031** — WHEN any log line was previously emitted from `Cympho.Plugins.*`, `Cympho.AgentAdapters.*`, or `IssueLive.Show` THEN an equivalent log line SHALL be emitted from the consolidated module, preserving level and metadata keys (`agent_id`, `company_id`, `issue_id`, `component`).
2. **AC-032** — WHEN the deprecation shim `Cympho.AgentAdapters` is called THEN it SHALL emit `Logger.warning("Cympho.AgentAdapters is deprecated; call Cympho.Adapters directly", ...)` with metadata `caller_module` derived from `Process.info(self(), :current_stacktrace)` (best-effort, not failing if unavailable).
3. **AC-033** — WHILE the issue show page is mounted post-decomposition THEN every Phoenix LiveView telemetry event (`:phoenix, :live_view, :mount`, `:handle_event`, `:handle_params`) SHALL continue to fire with measurements and metadata matching the pre-decomposition shape.

#### NFR-005 — Reliability

1. **AC-034** — WHEN any consolidated function returns an error tuple THEN the tuple shape SHALL match the pre-consolidation shape (`{:error, %Ecto.Changeset{}}`, `{:error, :not_found}`, `{:error, String.t()}`).
2. **AC-035** — WHEN the adapter registry boots and a previously-registered adapter type fails to register THEN the registry SHALL log the failure at `:warning` level and continue booting (same behaviour as today).
3. **AC-036** — IF the `Cympho.Skills.Plugin` schema's `manifest_errors` field contains data for a plugin row THEN the consolidated `update_skill_status/2` SHALL clear or preserve that field with the same logic as the pre-consolidation `Skills.update_plugin/2` path.

#### NFR-006 — Compatibility

1. **AC-037** — WHEN any external integration (Plugin SDK documented in `PLUGIN_SDK.md`, MCP tool callers) invokes the public surface THEN the surface SHALL continue to accept the same parameters and return the same response shape; no public API contract is altered by this spec.
2. **AC-038** — WHILE the deprecation shim `Cympho.AgentAdapters` exists, any code outside this repository that aliased `Cympho.AgentAdapters` SHALL continue to function unchanged.
3. **AC-039** — WHEN existing tests in `test/cympho/plugins_test.exs`, `test/cympho/skills_test.exs`, `test/cympho/adapters_test.exs` (and similar) run post-consolidation THEN they SHALL pass without modification beyond mechanical alias renames where the test referenced `Cympho.Plugins.list_plugins/1` or `Cympho.AgentAdapters.*`.

### Out of Scope

- Folding the `Cympho.Skills.Skill` schema (table `skills`) into `Cympho.Skills.Plugin` (table `plugins`). The two schemas have different field sets and their own LiveViews; merging them is a separate, larger migration.
- Renaming any internal `Cympho.Plugins.*` runtime module (`Registry`, `Supervisor`, `Worker`, `HostServices`, `PluginState`, `PluginLog`, `PluginWebhook`) to a `Cympho.Skills.*` equivalent. The runtime infrastructure keeps its name.
- Deletion of the `Cympho.AgentAdapters` shim itself. The shim is retained for one release window; removal is a follow-up spec.
- Extracting helpers from the issue show LiveView that are genuinely shared across the kanban, my-issues, or new-issue LiveViews; only helpers unique to `IssueLive.Show` are decomposed in this spec.
- Re-styling, re-flowing, or re-designing any visible UI element on the issue show page. Behaviour and appearance must be byte-equivalent.
- Adapter base / session-wrapper extraction (audit finding #11). That is a follow-up consolidation.
- Any of the other 24 findings in the architecture audit document.

### User Journeys

1. **Engineer adds a new plugin/skill via the LiveView:**
   - Open `/skills/new`.
   - Fill in identifier, name, manifest path, version, description.
   - Click "Create".
   - The LiveView calls `Cympho.Skills.create_skill/1` (or the merged plugin equivalent).
   - The new row appears in the index list and broadcasts on the company topic.
   - Expected behaviour identical to pre-consolidation; only the underlying function name changes from `Cympho.Plugins.create_plugin/1` to the canonical Skills surface.

2. **Operator toggles a plugin enabled/disabled:**
   - Open `/plugins` (legacy URL kept) or `/skills`.
   - Click the toggle on a row.
   - The LiveView calls `Cympho.Skills.toggle_skill/1`.
   - Row updates; PubSub broadcasts to other subscribed LiveViews; identical to pre-consolidation.

3. **Engineer loads the issue show page:**
   - Navigate to `/issues/:id`.
   - Page renders with header, description, review gates, work products, child issues, activity timeline, agent panel, and comments — same as before.
   - Click "Add Comment" → comment posts via the Comments LiveComponent → list updates.
   - Drag a child issue → reorders via the child issues LiveComponent.
   - Open a tool-call trace → expands inline via the Activity LiveComponent.
   - All flows preserve the pre-decomposition observable behaviour.

---

## Plan Document

### Introduction

This plan executes three independent but related refactors in a single spec for cohesion: (1) collapse the duplicate `Cympho.Plugins` / `Cympho.Skills` contexts, (2) eliminate the parallel adapter trees under `lib/cympho/adapters/` and `lib/cympho/agent_adapters/`, and (3) decompose the oversized `lib/cympho_web/live/issue_live/show.ex` into LiveComponents. Each refactor ships as a discrete PR so reverts remain surgical. The technical constraint is behaviour preservation: tests, telemetry, log lines, PubSub topics, error tuple shapes, and rendered HTML must remain equivalent. No new dependencies are introduced; the only runtime additions are deprecation warnings on the `Cympho.AgentAdapters` shim. Success criterion: all three changes ship green through `mix test`, `mix credo`, and `mix dialyzer` with no behavioural regressions observed in manual smoke tests of the affected pages.

### Understanding

The agent's restatement of the request: the user wants the audit's top three "remove duplicate surfaces" findings written up as a single spec covering the Plugins/Skills merge, the dual adapter cleanup, and the `IssueLive.Show` decomposition, with non-functional requirements framed as behaviour-preservation rather than improvement targets.

Key objectives:

- Exactly one canonical context for the plugin/skill domain concept.
- Exactly one adapter behaviour, one Claude Code implementation, one mock adapter.
- An `IssueLive.Show` parent file under 1,200 LoC, with the major visual sections extracted to focused components.
- Zero observable behaviour change across REST API, MCP tools, LiveView UX, PubSub broadcasts, and telemetry.

Open clarifying questions: none — the user's clarification step resolved scope and NFR style. The two remaining assumptions that warrant in-task verification are recorded in the metadata (canonical claude_code_adapter identity; surviving `plugins` table schema).

### Solution Design

**High-level approach.** Each of the three refactors is approached as a "delete one of two duplicates, redirect callers to the survivor, ship behind tests" mechanical change for parts 1 and 2, and as a "extract sections to components, route messages from parent" structural change for part 3. The three PRs ship in the order: (a) Plugins/Skills merge (smallest blast radius, isolated to one domain), (b) adapter cleanup (mechanical deletion plus a soft-landing shim), (c) `IssueLive.Show` decomposition (largest cognitive change, isolated to one file tree).

**Data flow & architecture.**

- *Plugins/Skills.* All public CRUD calls flow into `Cympho.Skills`. The `Cympho.Plugins` namespace shrinks to internal runtime modules only (`Registry`, `Supervisor`, `Worker`, `HostServices`, `PluginState`, `PluginLog`, `PluginWebhook`). The surviving DB schema for the `plugins` table is `Cympho.Skills.Plugin`.
- *Adapters.* All adapter resolution flows through `Cympho.Adapters.Registry`. The `Cympho.AgentAdapters` shim continues to delegate but logs a deprecation warning. `Cympho.Adapters.HealthChecker` replaces `Cympho.AgentAdapters.HealthChecker` in the supervision tree.
- *IssueLive.Show.* The parent LiveView owns mount, PubSub subscriptions, route params, and the message-routing `handle_info` clauses. Each major visual section becomes a child component receiving a focused slice of assigns. Updates from the parent flow to children via `send_update/2`; user events fire inside the child component's own `handle_event` and either mutate child-local state or notify the parent via `send/2` for cross-section effects.

**Step-by-step execution plan.**

1. **Plugins/Skills merge (PR #1):**
   1. Audit all callers of `Cympho.Plugins.*` CRUD functions (already enumerated in discovery: 6 LiveViews + 2 internal modules).
   2. Mirror each public CRUD function from `Cympho.Plugins` into `Cympho.Skills` if not already present.
   3. Update `Cympho.Skills.update_skill_status/2` to write directly through Skills changeset logic instead of delegating to `Cympho.Plugins.update_plugin/2`.
   4. Update all 6 LiveView callers + 2 internal callers to use `Cympho.Skills.*`.
   5. Delete the public CRUD functions from `lib/cympho/plugins.ex`. The module retains only internal runtime helpers, if any.
   6. Delete `lib/cympho/plugins/plugin.ex` (duplicate schema mapping the same table).
   7. Run `mix test`, `mix credo`, `mix dialyzer`. Manually smoke-test the `/plugins`, `/plugins/:id/edit`, `/skills`, `/skills/:id/edit`, and plugin-marketplace pages.

2. **Adapter cleanup (PR #2):**
   1. Verify the canonical `claude_code_adapter` (Assumption: `lib/cympho/adapters/claude_code_adapter.ex` is the one registered with `Cympho.Adapters.Registry`; the larger `lib/cympho/agent_adapters/claude_code_adapter.ex` has no live callers). Confirm via `grep -r "AgentAdapters.ClaudeCodeAdapter\|agent_adapters/claude_code" lib/ test/`.
   2. Move `lib/cympho/agent_adapters/health_checker.ex` to `lib/cympho/adapters/health_checker.ex`; rename module to `Cympho.Adapters.HealthChecker`; update internal references in `lib/cympho/application.ex` to point to the new module path.
   3. Update the shim `lib/cympho/agent_adapters.ex` to emit `Logger.warning("Cympho.AgentAdapters is deprecated", ...)` from each delegating function.
   4. Update the one internal caller of `Cympho.AgentAdapters` (the new `Cympho.Adapters.HealthChecker`, after move) to call `Cympho.Adapters` directly.
   5. Delete `lib/cympho/agent_adapters/adapter.ex`.
   6. Delete `lib/cympho/agent_adapters/claude_code_adapter.ex`.
   7. Delete `lib/cympho/agent_adapters/mock_adapter.ex`.
   8. Confirm the directory `lib/cympho/agent_adapters/` is empty and delete it.
   9. Run `mix test`, `mix credo`, `mix dialyzer`. Manually smoke-test agent execution against a Claude Code adapter and the mock adapter in test mode.

3. **IssueLive.Show decomposition (PR #3):**
   1. Identify the six-to-eight major sections from the discovery report (header, description, review gates, work products, child issues / decomposition, activity timeline, agent right-side panel, comments).
   2. For each section, decide stateful (`Phoenix.LiveComponent`) vs stateless (`Phoenix.Component`) based on whether it owns user events. Per the metadata assumption: Comments, WorkProducts, ReviewGates, AgentPanel are stateful; Header, Description, ChildIssues, ActivityTimeline are stateless.
   3. Create each component file under `lib/cympho_web/live/issue_live/components/` (new directory). Each stateful component module is named `CymphoWeb.IssueLive.Show.<Section>`. Each function component lives in a `CymphoWeb.IssueLive.Show.Components` module or per-file as appropriate.
   4. Move the relevant template HEEx subtree, the relevant `handle_event` clauses, and any section-only helpers from `show.ex` and `show.html.heex` into the new component module.
   5. In the parent `show.ex`, replace each subtree with `<.live_component module={...} id={...} ... />` or `<.section_name ... />` syntax.
   6. In the parent `handle_info` clauses, route any inbound PubSub message to the affected child via `Phoenix.LiveView.send_update/2` rather than recomputing assigns at the parent level.
   7. Run `mix test`, `mix credo`, `mix dialyzer`. Manually smoke-test the issue show page: all 41 events, all 20 PubSub message types, keyboard navigation, screen-reader heading order.

**Edge cases & failure handling.**

- *Forgotten caller of `Cympho.Plugins.*`.* If a `grep` miss leaves a stale call site, the compiler raises `UndefinedFunctionError` at compile time (functions removed from public surface). The build fails fast; no runtime surprise.
- *Forgotten caller of `Cympho.AgentAdapters.*`.* The shim survives one release, emitting deprecation warnings, so a forgotten call site logs rather than crashes. The follow-up spec deletes the shim once the warning count has been zero for a release.
- *LiveComponent crash during render.* The parent LiveView SHALL trap the exit (Phoenix's default behaviour for LiveComponent isolates render exceptions) and Sentry SHALL receive the report with the child module name in metadata.
- *PubSub message arrives before the child component is mounted.* The parent stashes the latest message per section in assigns; on next `send_update/2`, the child receives it. (Phoenix LiveView already guarantees `update/2` is called for mounted-or-mounting children.)
- *Schema deletion conflict.* If both `Cympho.Plugins.Plugin` and `Cympho.Skills.Plugin` reference the same `plugins` table and a third caller imports the wrong one after deletion, compile fails. No data loss risk because no migration is run.

**Scalability & performance considerations.** Behaviour-preservation means no new performance characteristics. Specifically, no new SQL queries are introduced (each consolidated function maps 1:1 to its predecessor), and LiveView assigns size on the parent decreases (each child holds its own slice), so the diff sent to the client per update SHOULD shrink slightly — measurable as a follow-up but not gated on this spec.

**Decisions.**

- **DES-001** — Adopt `Cympho.Skills` as the canonical public context; demote `Cympho.Plugins` to internal runtime infrastructure. Satisfies: REQ-001.
- **DES-002** — Delete `lib/cympho/plugins/plugin.ex` and retain `lib/cympho/skills/plugin.ex` as the surviving `plugins` table schema. Satisfies: REQ-001.
- **DES-003** — Inline the `update_skill_status/2` mutation in `Cympho.Skills` (no delegation to `Cympho.Plugins.update_plugin/2`). Satisfies: REQ-001.
- **DES-004** — Retain `Cympho.Skills.Skill` and the `skills` table unchanged; defer Skill↔Plugin schema merging to a later spec. Satisfies: REQ-001 (out-of-scope boundary).
- **DES-005** — Delete `lib/cympho/agent_adapters/adapter.ex`, `claude_code_adapter.ex`, `mock_adapter.ex`; relocate `health_checker.ex` to `lib/cympho/adapters/health_checker.ex` as `Cympho.Adapters.HealthChecker`. Satisfies: REQ-002.
- **DES-006** — Keep `lib/cympho/agent_adapters.ex` as a logged-deprecation shim for one release window. Satisfies: REQ-002.
- **DES-007** — Decompose `IssueLive.Show` along visual-section boundaries identified in the discovery report (8 sections: Header, Description, ReviewGates, WorkProducts, ChildIssues, ActivityTimeline, AgentPanel, Comments). Satisfies: REQ-003.
- **DES-008** — Use `Phoenix.LiveComponent` for sections owning `handle_event` clauses; use `Phoenix.Component` (stateless) for pure-rendering sections. Satisfies: REQ-003.
- **DES-009** — PubSub subscriptions stay on the parent LiveView; the parent fans updates out to children via `send_update/2`. Satisfies: REQ-003.
- **DES-010** — Place new component modules under `lib/cympho_web/live/issue_live/components/`, mirroring Phoenix conventions, with module names `CymphoWeb.IssueLive.Show.<SectionName>`. Satisfies: REQ-003.

### Components & Interfaces

- **`Cympho.Skills`** — Sole public context for the plugin/skill domain. API: all existing public functions (the `_skill`-suffixed family operating on the `skills` table, plus `get_plugin/1`, `update_plugin/2`, `available_for_agent/1`, `list_skills_for_agent/1`, `assign_skill_to_agent/3`, `remove_skill_from_agent/2`, `update_skill_status/2`) PLUS newly mirrored `_plugin`-suffixed functions added during consolidation to absorb the deleted `Cympho.Plugins` CRUD surface, all operating on `Cympho.Skills.Plugin`: `list_plugins/1`, `get_company_plugin/2`, `get_plugin_by_identifier/2`, `create_plugin/1`, `delete_plugin/1`, `toggle_plugin/1`, `update_plugin_settings/2`, `change_plugin/2`. Path: `lib/cympho/skills.ex`.
- **`Cympho.Skills.Plugin`** — Sole schema for the `plugins` table. Path: `lib/cympho/skills/plugin.ex` (existing; preserved).
- **`Cympho.Plugins`** — Reduced to a documentation-only umbrella module that re-exports the internal runtime namespace; all public CRUD functions removed. Path: `lib/cympho/plugins.ex`.
- **`Cympho.Adapters.Adapter`** — Sole adapter behaviour. API: 8 callbacks (`run/4`, `health_check/1`, `config_schema/0`, `name/0`, `available?/0`, `available?/1` optional, `type/0`, `validate_config/1`). Path: `lib/cympho/adapters/adapter.ex` (existing; preserved).
- **`Cympho.Adapters.HealthChecker`** — Sole health checker GenServer (relocated from `agent_adapters/`). API: `start_link/1`, `check_all/0` (existing signatures preserved). Path: `lib/cympho/adapters/health_checker.ex` (new path).
- **`Cympho.AgentAdapters`** — Deprecation soft-landing shim. API: existing five delegating functions, each now emitting a deprecation warning. Path: `lib/cympho/agent_adapters.ex` (existing; updated to warn).
- **`CymphoWeb.IssueLive.Show`** — Parent LiveView. API: `mount/3`, `handle_params/3`, `handle_info/2` (PubSub routing), `render/1` (top-level wrapper). Path: `lib/cympho_web/live/issue_live/show.ex` (existing; trimmed).
- **`CymphoWeb.IssueLive.Show.Header`** — Stateless component rendering title, status badge, priority badge, identifier strip, assignee combobox. Path: `lib/cympho_web/live/issue_live/components/header.ex` (new).
- **`CymphoWeb.IssueLive.Show.Description`** — Stateless component rendering description card and edit affordances. Path: `lib/cympho_web/live/issue_live/components/description.ex` (new).
- **`CymphoWeb.IssueLive.Show.ReviewGates`** — Stateful LiveComponent owning review-gate, next-owner-assignment, review-signal, and contract-nudge events. Path: `lib/cympho_web/live/issue_live/components/review_gates.ex` (new).
- **`CymphoWeb.IssueLive.Show.WorkProducts`** — Stateful LiveComponent owning attach/validate/cancel/remove work-product events. Path: `lib/cympho_web/live/issue_live/components/work_products.ex` (new).
- **`CymphoWeb.IssueLive.Show.ChildIssues`** — Stateless component rendering the decomposition tree and child-issue health cards. Path: `lib/cympho_web/live/issue_live/components/child_issues.ex` (new).
- **`CymphoWeb.IssueLive.Show.ActivityTimeline`** — Stateless component rendering the activity timeline and timeline filter buttons. Path: `lib/cympho_web/live/issue_live/components/activity_timeline.ex` (new).
- **`CymphoWeb.IssueLive.Show.AgentPanel`** — Stateful LiveComponent rendering the right-side agent panel (run status, session controls). Path: `lib/cympho_web/live/issue_live/components/agent_panel.ex` (new).
- **`CymphoWeb.IssueLive.Show.Comments`** — Stateful LiveComponent owning add/delete comment events, comment templates, and revision diff viewing. Path: `lib/cympho_web/live/issue_live/components/comments.ex` (new).

### Dependencies

None — no new libraries, frameworks, or tools are introduced by this spec.

### Integration Points

**1. Migrating `Cympho.Plugins.*` callers in plugin LiveViews.**

```elixir
# Before — lib/cympho_web/live/plugin_live/show.ex
defmodule CymphoWeb.PluginLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Plugins

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    plugin = Plugins.get_company_plugin(socket.assigns.current_company.id, id)
    {:ok, assign(socket, plugin: plugin)}
  end
end

# After
defmodule CymphoWeb.PluginLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Skills

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    plugin = Skills.get_company_skill(socket.assigns.current_company.id, id)
    {:ok, assign(socket, plugin: plugin)}
  end
end
```

**2. Updating the supervision tree for the relocated HealthChecker.**

```elixir
# lib/cympho/application.ex — before
children = [
  # ...
  {Cympho.AgentAdapters.HealthChecker, []},
  # ...
]

# After
children = [
  # ...
  {Cympho.Adapters.HealthChecker, []},
  # ...
]
```

**3. Deprecation warning in the `Cympho.AgentAdapters` shim.**

```elixir
# lib/cympho/agent_adapters.ex
defmodule Cympho.AgentAdapters do
  require Logger

  @moduledoc """
  Deprecated. Call `Cympho.Adapters` directly. This module will be removed
  in a follow-up release once all internal callers have migrated.
  """

  def resolve(agent) do
    warn_deprecated(:resolve)
    Cympho.Adapters.resolve(agent)
  end

  def register(type, module) do
    warn_deprecated(:register)
    Cympho.Adapters.register(type, module)
  end

  # ... fallback_chain/1, all_types/0, lookup/1 follow the same pattern

  defp warn_deprecated(fun) do
    Logger.warning("Cympho.AgentAdapters.#{fun} is deprecated; call Cympho.Adapters.#{fun} directly",
      component: :agent_adapters_shim
    )
  end
end
```

**4. Parent LiveView routing a PubSub message to a child component.**

```elixir
# lib/cympho_web/live/issue_live/show.ex — handle_info routing
@impl true
def handle_info({:comment_created, updated_issue}, socket) do
  Phoenix.LiveView.send_update(
    CymphoWeb.IssueLive.Show.Comments,
    id: "issue-comments-#{updated_issue.id}",
    issue: updated_issue
  )

  {:noreply, assign(socket, :issue, updated_issue)}
end

@impl true
def handle_info({:work_product_updated, work_product}, socket) do
  Phoenix.LiveView.send_update(
    CymphoWeb.IssueLive.Show.WorkProducts,
    id: "issue-work-products-#{socket.assigns.issue.id}",
    work_product: work_product
  )

  {:noreply, socket}
end
```

**5. Stateful LiveComponent shape for `Comments`.**

```elixir
# lib/cympho_web/live/issue_live/components/comments.ex
defmodule CymphoWeb.IssueLive.Show.Comments do
  use CymphoWeb, :live_component
  alias Cympho.Comments

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:comment_form, fn -> Comments.change_comment(%Comments.Comment{}) end)}
  end

  @impl true
  def handle_event("add_comment", %{"comment" => params}, socket) do
    case Comments.create_comment(socket.assigns.issue, params) do
      {:ok, _comment} ->
        {:noreply, assign(socket, :comment_form, Comments.change_comment(%Comments.Comment{}))}

      {:error, changeset} ->
        {:noreply, assign(socket, :comment_form, changeset)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="issue-comments">
      <%!-- moved subtree from show.html.heex --%>
    </section>
    """
  end
end
```

**6. Stateless function component shape for `Header`.**

```elixir
# lib/cympho_web/live/issue_live/components/header.ex
defmodule CymphoWeb.IssueLive.Show.Header do
  use Phoenix.Component

  attr :issue, :map, required: true
  attr :current_user, :map, required: true
  attr :editing, :atom, default: nil

  def header(assigns) do
    ~H"""
    <header class="issue-header">
      <%!-- moved subtree from show.html.heex --%>
    </header>
    """
  end
end
```

### Testing Strategy

- **Unit tests:**
  - **TEST-001** — `test/cympho/skills_test.exs` extended to cover every former `Cympho.Plugins.*` CRUD function (now on `Cympho.Skills.*`). Verifies: AC-001, AC-002, AC-006, AC-007, AC-025, AC-026, AC-028, AC-034, AC-036.
  - **TEST-002** — `test/cympho/adapters_test.exs` verifies that `Cympho.Adapters.Registry.register_builtin/0` registers the seven built-in types and the optional mock; verifies that `Cympho.Adapters.resolve_agent/1` returns the same shape as before. Verifies: AC-008, AC-014, AC-025, AC-034.
  - **TEST-003** — `test/cympho/agent_adapters_test.exs` (existing or new minimal file) verifies the shim emits a deprecation warning and still delegates correctly. Verifies: AC-012, AC-032, AC-038.
  - **TEST-004** — `test/cympho/adapters/health_checker_test.exs` (renamed from `test/cympho/agent_adapters/health_checker_test.exs` if present, otherwise new) verifies that `Cympho.Adapters.HealthChecker` ticks and updates agent health identically. Verifies: AC-011, AC-015, AC-035.

- **Integration tests:**
  - **TEST-005** — `test/cympho_web/live/plugin_live_test.exs` (or merge into `skill_live_test.exs`) verifies that the `/plugins`, `/plugins/:id/edit`, `/plugins/new` LiveViews mount and operate identically after the alias swap. Verifies: AC-004, AC-005, AC-039.
  - **TEST-006** — `test/cympho_web/live/issue_live/show_test.exs` extended to fire each of the 41 known events and assert the rendered HTML and observable side effects (PubSub broadcasts, Repo writes, flash messages) are unchanged. Verifies: AC-018, AC-019, AC-020, AC-021, AC-029, AC-030, AC-033.
  - **TEST-007** — `test/cympho_web/live/issue_live/components/<each>_test.exs` — one focused test file per new child component, covering its `update/2` and any `handle_event/3`. Verifies: AC-019, AC-020, AC-022.

- **End-to-end tests:** None — Cympho's existing test suite covers LiveView interactions at the integration level via `Phoenix.LiveViewTest`. No new e2e layer is introduced.

- **Regression tests:**
  - **TEST-008** — `mix test --warnings-as-errors` post-each-PR. Verifies: AC-024, AC-031, AC-039.

- **Manual QA:**
  - **TEST-009** — Smoke-test checklist: (a) load `/plugins` and `/skills` index, (b) create/edit/toggle a plugin from `/plugins/new`, (c) verify the same row appears under `/skills`, (d) execute an agent run using the Claude Code adapter against a test issue, (e) execute an agent run using the mock adapter in test config, (f) open `/issues/:id`, click through every section (header, description, review gates, work products, child issues, activity, agent panel, comments), verify no console errors, verify keyboard tab order, verify screen-reader heading hierarchy. Verifies: AC-005, AC-009, AC-015, AC-018, AC-022, AC-029, AC-030.

### Rollout Plan

- **Migration:** None — no schema migrations are introduced. The `plugins` table is unchanged; one of two duplicate Elixir schema modules pointing at it is deleted, not the table itself.
- **Backwards compatibility:** External callers (Plugin SDK consumers, MCP tool callers) are unaffected because no public API contract changes. Internal callers of `Cympho.Plugins.*` CRUD are updated in the same PR that removes those functions. Internal callers of `Cympho.AgentAdapters.*` continue to function through the shim with a deprecation log line for one release window.
- **Rollback:** Each refactor ships as an independent PR. To revert: `git revert` the offending PR; no data migration to unwind because no schema changes occur. If only part of a PR needs to be undone (e.g., the `IssueLive.Show` decomposition causes a regression in one section only), the parent LiveView's render can fall back to inline HEEx for the affected section while keeping the other components extracted.
- **Observability:** New log line on the deprecation shim (`Cympho.AgentAdapters` deprecated warning). No new metrics, no new alerts; existing telemetry is preserved per NFR-004.
- **Feature flag:** None — these are pure refactors with behaviour-preservation requirements; gating them behind a flag would multiply the surface area without benefit.

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| A forgotten caller of `Cympho.Plugins.*` CRUD escapes the grep audit. | Low | Medium | Compile fails fast (functions removed from public surface); `mix compile --warnings-as-errors` catches it in CI before merge. |
| The wrong `claude_code_adapter` is deleted (the larger file turns out to be the live one). | Low | High | TASK-001 explicitly verifies via grep + registry inspection before any deletion; if the larger file *is* live, swap which file is deleted and update the registry registration accordingly. |
| `IssueLive.Show` decomposition silently breaks one of 41 events or 20 PubSub messages. | Medium | High | TEST-006 fires every event and asserts pre/post equivalence; manual smoke-test checklist in TEST-009 walks every visible UI affordance. |
| A child LiveComponent crashes during render and produces a less-helpful error than the monolithic LiveView did. | Low | Low | AC-022 mandates Sentry reporting with child module metadata; existing Phoenix LiveView crash-isolation behaviour applies. |
| Deprecation log noise from `Cympho.AgentAdapters` floods production logs if an internal caller was missed. | Low | Low | Sample the deprecation warnings (Logger handler filter or log rate-limit) if volume exceeds a threshold; investigate the call sites named in metadata. |
| Schema deletion conflicts with a pending migration not yet merged. | Low | Medium | Coordinate with anyone holding open PRs touching `lib/cympho/plugins/plugin.ex` or `lib/cympho/skills/plugin.ex` before merging PR #1. |

### Research

None — these refactors operate entirely against the existing Cympho codebase and well-established Phoenix LiveView patterns (LiveComponent, function components, `send_update/2`). No new library, framework, or external documentation source was consulted. If a Phoenix LiveView documentation question arises during implementation (e.g., the exact contract of `Phoenix.LiveView.send_update/2` with respect to mount race conditions), the implementer should consult Context7 MCP for `phoenix_live_view` and record the source URL, version, and access date in this section before merging.

### Codebase Analysis

- **Patterns observed:**
  - Phoenix Context pattern — `Cympho.Issues`, `Cympho.Agents`, `Cympho.Decisions`, `Cympho.Skills` each act as the public API for their domain.
  - Adapter behaviour pattern — `Cympho.Adapters.Adapter` defines callbacks; concrete adapters implement them; `Cympho.Adapters.Registry` holds an ETS table keyed by `:type`.
  - LiveView mount-then-subscribe — `mount/3` calls `Issues.subscribe/1`, `Comments.subscribe/1`, etc.; updates arrive as messages handled in `handle_info/2`.
  - Optimistic UI updates via PubSub broadcast — context functions write to the DB, then call `Phoenix.PubSub.broadcast/3` on a scoped topic (`company:#{id}:*`).
  - Tenant scoping via `company_id` filters — every list/get function takes a `company_id` argument.

- **Conventions in use:**
  - `:binary_id` (UUID) primary keys.
  - `:utc_datetime` timestamps.
  - Module names follow `Cympho.Domain` (context) and `Cympho.Domain.Schema` (schema).
  - Logger metadata keys: `issue_id`, `agent_id`, `company_id`, `component` (per CLAUDE.md).
  - Tests in `test/cympho/` and `test/cympho_web/` mirroring the `lib/` structure.

- **Testing approach in use:**
  - `Cympho.DataCase` for context tests.
  - `CymphoWeb.ConnCase` for controller tests.
  - `CymphoWeb.LiveCase` for LiveView tests.
  - `Ecto.Adapters.SQL.Sandbox` in manual mode.

- **Similar implementations already in the repo:**
  - The existing `Cympho.Skills` context (192 LoC) and `Cympho.Skills.Plugin` schema (57 LoC) are the closest pre-existing analogues to the merged target shape — most of REQ-001's work is moving the remaining `Cympho.Plugins.*` CRUD into the established `Cympho.Skills.*` patterns.
  - `lib/cympho/adapters/registry.ex` (211 LoC) is the established adapter discovery pattern; the consolidation simply removes a parallel partial implementation, leaving this one in place.
  - The kanban LiveView at `lib/cympho_web/live/kanban_live/` shows an existing example of a LiveView that uses both `<.live_component>` and function components — useful as a structural template for the decomposed `IssueLive.Show`.

- **Reusable utilities:**
  - `Cympho.Skills.update_skill/2` and `Cympho.Skills.change_skill/2` already exist and provide changeset-style updates; the new `update_skill_status/2` (post-consolidation) inlines that pattern rather than delegating across contexts.
  - `Phoenix.LiveView.send_update/2` (Phoenix standard) is the established way to push parent-state changes into mounted children.
  - `Cympho.Adapters.Registry.resolve_agent/1` already encapsulates the "resolve with config fallback" logic; the relocated `HealthChecker` consumes it directly.
  - `CymphoWeb.LiveCase` provides the existing test helpers used by all LiveView tests — the new per-component tests use it without modification.

---

## Task List Document

Tasks are grouped by the three planned PRs. Each PR is independently revertable. Within a PR, tasks are topologically sorted by dependency.

### PR #1 — Plugins/Skills merge (REQ-001)

- [ ] **TASK-001** [verification] Run `grep -rn "Cympho.Plugins\." lib/ test/ --include="*.ex" --include="*.heex"` and `grep -rn "alias Cympho.Plugins" lib/ test/ --include="*.ex" --include="*.heex"`; record every caller in a scratch file used during PR #1. Paths: `N/A — scratch artefact, not committed`. Implements: `REQ-001`, `DES-001`. Verifies: `N/A`. Depends: `None`. Done when: the scratch list contains at minimum the 6 LiveView files and 2 internal modules named in the codebase analysis, and no additional callers of removed CRUD functions remain unaccounted for.
- [ ] **TASK-002** [service] Add `_plugin`-suffixed mirror functions to `Cympho.Skills` operating on `Cympho.Skills.Plugin`: `list_plugins/1`, `get_company_plugin/2`, `get_plugin_by_identifier/2`, `create_plugin/1`, `delete_plugin/1`, `toggle_plugin/1`, `update_plugin_settings/2`, `change_plugin/2`. Each must mirror its `Cympho.Plugins` counterpart's return shape, error tuple, broadcast topic, and SQL query count. Paths: `lib/cympho/skills.ex`. Implements: `REQ-001`, `DES-001`, `DES-002`. Verifies: `N/A`. Depends: `TASK-001`. Done when: `mix compile --warnings-as-errors` succeeds and each new function has a `@spec` matching its `Cympho.Plugins` predecessor.
- [ ] **TASK-003** [service] Inline `Cympho.Skills.update_skill_status/2` to mutate `Cympho.Skills.Plugin` rows directly via a Skills-owned changeset; remove the delegation to `Cympho.Plugins.update_plugin/2`. Paths: `lib/cympho/skills.ex`. Implements: `REQ-001`, `DES-003`. Verifies: `N/A`. Depends: `TASK-002`. Done when: `grep -n "Plugins.update_plugin" lib/cympho/skills.ex` returns no matches and behaviour-equivalence is preserved (same row mutation, same broadcast).
- [ ] **TASK-004** [ui] Update `lib/cympho_web/live/plugin_live/show.ex`, `lib/cympho_web/live/plugin_live/edit.ex`, `lib/cympho_web/live/plugin_live/new.ex`, and `lib/cympho_web/live/plugin_live/index.ex` to call `Cympho.Skills.*` (`_plugin`-suffixed family) instead of `Cympho.Plugins.*`; remove `alias Cympho.Plugins`. Paths: `lib/cympho_web/live/plugin_live/show.ex`, `lib/cympho_web/live/plugin_live/edit.ex`, `lib/cympho_web/live/plugin_live/new.ex`, `lib/cympho_web/live/plugin_live/index.ex`. Implements: `REQ-001`, `DES-001`. Verifies: `N/A`. Depends: `TASK-002`. Done when: each updated file compiles, contains no `Cympho.Plugins.` reference, and the corresponding LiveView mounts in the dev server.
- [ ] **TASK-005** [ui] Update `lib/cympho_web/live/plugin_marketplace_live/index.ex` to call `Cympho.Skills.*` instead of `Cympho.Plugins.*`; remove `alias Cympho.Plugins`. Paths: `lib/cympho_web/live/plugin_marketplace_live/index.ex`. Implements: `REQ-001`, `DES-001`. Verifies: `N/A`. Depends: `TASK-002`. Done when: file compiles and the marketplace LiveView mounts in the dev server.
- [ ] **TASK-006** [service] Update internal modules `lib/cympho/plugins/example_plugin.ex` and `lib/cympho/plugins/host_services.ex` to call `Cympho.Skills.*` for any CRUD function previously invoked via `Cympho.Plugins`; leave references to `Cympho.Plugins.{Registry,Supervisor,Worker,HostServices,PluginState,PluginLog,PluginWebhook}` runtime modules untouched. Paths: `lib/cympho/plugins/example_plugin.ex`, `lib/cympho/plugins/host_services.ex`. Implements: `REQ-001`, `DES-001`. Verifies: `N/A`. Depends: `TASK-002`. Done when: each file compiles and contains no `Cympho.Plugins.<CRUD function>` reference per TASK-001's scratch list.
- [ ] **TASK-007** [service] Remove the 10 public CRUD functions from `lib/cympho/plugins.ex` (`list_plugins/1`, `get_plugin/1`, `get_company_plugin/2`, `get_plugin_by_identifier/2`, `create_plugin/1`, `update_plugin/2`, `delete_plugin/1`, `toggle_plugin/1`, `update_plugin_settings/2`, `change_plugin/2`); update the module `@moduledoc` to describe its reduced internal-runtime role. Paths: `lib/cympho/plugins.ex`. Implements: `REQ-001`, `DES-001`. Verifies: `N/A`. Depends: `TASK-004`, `TASK-005`, `TASK-006`. Done when: `mix compile --warnings-as-errors` succeeds and none of the removed function names appear via `grep -n "def list_plugins\|def get_plugin\|def get_company_plugin\|def get_plugin_by_identifier\|def create_plugin\|def update_plugin\|def delete_plugin\|def toggle_plugin\|def update_plugin_settings\|def change_plugin" lib/cympho/plugins.ex`.
- [ ] **TASK-008** [model] Delete the duplicate `Cympho.Plugins.Plugin` schema module so only `Cympho.Skills.Plugin` maps to the `plugins` table. Paths: `lib/cympho/plugins/plugin.ex` (delete). Implements: `REQ-001`, `DES-002`. Verifies: `N/A`. Depends: `TASK-007`. Done when: the file no longer exists on disk and `mix compile --warnings-as-errors` succeeds.
- [ ] **TASK-009** [test] Extend `test/cympho/skills_test.exs` (or create it if absent) with cases covering each newly mirrored `_plugin`-suffixed function from TASK-002 plus the inlined `update_skill_status/2` from TASK-003: assert return shape, error tuples, broadcast topics, and tenant scoping. Paths: `test/cympho/skills_test.exs`. Implements: `REQ-001`, `DES-001`, `DES-002`, `DES-003`. Verifies: `TEST-001` covering `AC-001`, `AC-002`, `AC-006`, `AC-007`, `AC-025`, `AC-026`, `AC-028`, `AC-034`, `AC-036`. Depends: `TASK-003`. Done when: `mix test test/cympho/skills_test.exs` is green and each new function has at least one assertion exercising its happy path and one exercising its error path.
- [ ] **TASK-010** [test] Update `test/cympho_web/live/plugin_live_test.exs` and `test/cympho_web/live/plugin_marketplace_live_test.exs` (or create them) so all assertions pass against the Skills-backed LiveViews. Paths: `test/cympho_web/live/plugin_live_test.exs`, `test/cympho_web/live/plugin_marketplace_live_test.exs`. Implements: `REQ-001`, `DES-001`. Verifies: `TEST-005` covering `AC-004`, `AC-005`, `AC-039`. Depends: `TASK-005`. Done when: `mix test test/cympho_web/live/plugin_live_test.exs test/cympho_web/live/plugin_marketplace_live_test.exs` is green.
- [ ] **TASK-011** [verification] Run the PR #1 verification gauntlet. Paths: `N/A — terminal commands and dev-server interaction`. Implements: `N/A`. Verifies: `TEST-008` covering `AC-024`, `AC-031`, `AC-039` plus the PR #1 portion of `TEST-009` covering `AC-005`. Depends: `TASK-008`, `TASK-009`, `TASK-010`. Done when: `mix test --warnings-as-errors` is green, `mix credo --strict` reports no new findings, `mix dialyzer` is clean, and manual smoke of `/plugins`, `/plugins/new`, `/plugins/:id/edit`, `/plugins/marketplace`, `/skills`, `/skills/:id/edit` shows identical UI and PubSub behaviour to a pre-PR build.

### PR #2 — Dual adapter cleanup (REQ-002)

- [ ] **TASK-012** [verification] Run `grep -rn "AgentAdapters.ClaudeCodeAdapter\|Cympho.AgentAdapters\.ClaudeCode\|agent_adapters/claude_code" lib/ test/ priv/` and inspect `Cympho.Adapters.Registry.register_builtin/0` to confirm the canonical Claude Code adapter is `lib/cympho/adapters/claude_code_adapter.ex` and that the larger `lib/cympho/agent_adapters/claude_code_adapter.ex` has no live callers. Paths: `N/A — scratch artefact`. Implements: `REQ-002`, `DES-005`. Verifies: `N/A`. Depends: `None`. Done when: grep returns zero non-test, non-deleted-file references to `Cympho.AgentAdapters.ClaudeCode*` and the assumption recorded in spec metadata is confirmed; if the grep yields surprise callers, escalate before any deletion.
- [ ] **TASK-013** [service] Move `lib/cympho/agent_adapters/health_checker.ex` to `lib/cympho/adapters/health_checker.ex`; rename the module from `Cympho.AgentAdapters.HealthChecker` to `Cympho.Adapters.HealthChecker`; update the existing call `AgentAdapters.resolve/1` inside that module to `Cympho.Adapters.resolve_agent/1`. Paths: `lib/cympho/adapters/health_checker.ex` (new), `lib/cympho/agent_adapters/health_checker.ex` (delete). Implements: `REQ-002`, `DES-005`. Verifies: `N/A`. Depends: `TASK-012`. Done when: the file exists at its new path with the new module name and `mix compile --warnings-as-errors` succeeds.
- [ ] **TASK-014** [service] Update `lib/cympho/application.ex` to reference `Cympho.Adapters.HealthChecker` in the supervision tree (replacing `Cympho.AgentAdapters.HealthChecker`). Paths: `lib/cympho/application.ex`. Implements: `REQ-002`, `DES-005`. Verifies: `N/A`. Depends: `TASK-013`. Done when: `mix compile --warnings-as-errors` succeeds and `iex -S mix phx.server` boots with the relocated child running.
- [ ] **TASK-015** [service] Update the shim `lib/cympho/agent_adapters.ex` so each of `resolve/1`, `register/2`, `fallback_chain/1`, `all_types/0`, `lookup/1` emits `Logger.warning("Cympho.AgentAdapters.<fun> is deprecated; call Cympho.Adapters.<fun> directly", component: :agent_adapters_shim)` before delegating to `Cympho.Adapters`. Paths: `lib/cympho/agent_adapters.ex`. Implements: `REQ-002`, `DES-006`. Verifies: `N/A`. Depends: `TASK-012`. Done when: invoking any of the five shim functions in `iex` produces the warning line and still returns the delegated result.
- [ ] **TASK-016** [service] Delete the duplicate adapter behaviour definition. Paths: `lib/cympho/agent_adapters/adapter.ex` (delete). Implements: `REQ-002`, `DES-005`. Verifies: `N/A`. Depends: `TASK-013`, `TASK-015`. Done when: the file no longer exists and `mix compile --warnings-as-errors` succeeds.
- [ ] **TASK-017** [service] Delete the duplicate Claude Code adapter implementation. Paths: `lib/cympho/agent_adapters/claude_code_adapter.ex` (delete). Implements: `REQ-002`, `DES-005`. Verifies: `N/A`. Depends: `TASK-016`. Done when: the file no longer exists and `mix compile --warnings-as-errors` succeeds.
- [ ] **TASK-018** [service] Delete the duplicate mock adapter. Paths: `lib/cympho/agent_adapters/mock_adapter.ex` (delete). Implements: `REQ-002`, `DES-005`. Verifies: `N/A`. Depends: `TASK-016`. Done when: the file no longer exists and `mix compile --warnings-as-errors` succeeds.
- [ ] **TASK-019** [setup] Verify `lib/cympho/agent_adapters/` is empty and remove the directory. Paths: `lib/cympho/agent_adapters/` (delete directory). Implements: `REQ-002`, `DES-005`. Verifies: `N/A`. Depends: `TASK-017`, `TASK-018`, `TASK-013`. Done when: `ls lib/cympho/agent_adapters/` returns "No such file or directory".
- [ ] **TASK-020** [test] Add or extend `test/cympho/adapters_test.exs` to assert that `Cympho.Adapters.Registry.register_builtin/0` registers exactly seven built-in adapter types (`:claude_code`, `:codex`, `:cursor`, `:http`, `:openclaw`, `:process`, `:agrenting`) plus `:mock` under the test environment, and that `Cympho.Adapters.resolve_agent/1` returns the same shape as before consolidation. Paths: `test/cympho/adapters_test.exs`. Implements: `REQ-002`, `DES-005`. Verifies: `TEST-002` covering `AC-008`, `AC-014`, `AC-025`, `AC-034`. Depends: `TASK-014`, `TASK-019`. Done when: `mix test test/cympho/adapters_test.exs` is green.
- [ ] **TASK-021** [test] Add `test/cympho/agent_adapters_test.exs` covering the deprecation-warning shim: invoke each delegated function, assert the `Logger.warning` is emitted with `component: :agent_adapters_shim`, and assert the return value matches the corresponding `Cympho.Adapters` call. Paths: `test/cympho/agent_adapters_test.exs`. Implements: `REQ-002`, `DES-006`. Verifies: `TEST-003` covering `AC-012`, `AC-032`, `AC-038`. Depends: `TASK-015`. Done when: `mix test test/cympho/agent_adapters_test.exs` is green and uses `ExUnit.CaptureLog` to assert the warning text.
- [ ] **TASK-022** [test] Add or relocate `test/cympho/adapters/health_checker_test.exs` covering `Cympho.Adapters.HealthChecker`: assert it transitions agent health via `Agents.update_agent/2` with the same recovery and failure semantics as the pre-consolidation `Cympho.AgentAdapters.HealthChecker`. Paths: `test/cympho/adapters/health_checker_test.exs`. Implements: `REQ-002`, `DES-005`. Verifies: `TEST-004` covering `AC-011`, `AC-015`, `AC-035`. Depends: `TASK-013`. Done when: `mix test test/cympho/adapters/health_checker_test.exs` is green.
- [ ] **TASK-023** [verification] Run the PR #2 verification gauntlet. Paths: `N/A — terminal commands and dev-server interaction`. Implements: `N/A`. Verifies: `TEST-008` covering `AC-024`, `AC-031`, `AC-039` plus the PR #2 portion of `TEST-009` covering `AC-009`, `AC-015`. Depends: `TASK-019`, `TASK-020`, `TASK-021`, `TASK-022`. Done when: `mix test --warnings-as-errors` is green, `mix credo --strict` reports no new findings, `mix dialyzer` is clean, an agent run against the Claude Code adapter succeeds end-to-end against a test issue, and an agent run against the mock adapter in test config still completes.

### PR #3 — IssueLive.Show decomposition (REQ-003)

- [ ] **TASK-024** [setup] Create the new components directory under the issue LiveView tree. Paths: `lib/cympho_web/live/issue_live/components/` (new directory). Implements: `REQ-003`, `DES-010`. Verifies: `N/A`. Depends: `None`. Done when: the directory exists and `ls lib/cympho_web/live/issue_live/components/` returns successfully.
- [ ] **TASK-025** [ui] Create the stateless **Header** function component in `CymphoWeb.IssueLive.Show.Header`; move the title-hero / status / priority / assignee combobox / breadcrumb / identifier-strip HEEx subtree from `show.html.heex`; expose attrs `:issue`, `:current_user`, `:editing`. Paths: `lib/cympho_web/live/issue_live/components/header.ex`. Implements: `REQ-003`, `DES-007`, `DES-008`. Verifies: `N/A`. Depends: `TASK-024`. Done when: the module compiles, exposes `header/1`, and renders the moved subtree under tests in TASK-037.
- [ ] **TASK-026** [ui] Create the stateless **Description** function component in `CymphoWeb.IssueLive.Show.Description`; move the description card and edit affordances; expose attrs `:issue`, `:editing`, `:current_user`. Paths: `lib/cympho_web/live/issue_live/components/description.ex`. Implements: `REQ-003`, `DES-007`, `DES-008`. Verifies: `N/A`. Depends: `TASK-024`. Done when: the module compiles and exposes `description/1`.
- [ ] **TASK-027** [ui] Create the stateless **ChildIssues** function component in `CymphoWeb.IssueLive.Show.ChildIssues`; move the decomposition tree, child-issue health cards, and pending-wake panel; expose attrs `:issue`, `:child_issues`, `:child_tree`, `:child_health_cards`, `:pending_wake`. Paths: `lib/cympho_web/live/issue_live/components/child_issues.ex`. Implements: `REQ-003`, `DES-007`, `DES-008`. Verifies: `N/A`. Depends: `TASK-024`. Done when: the module compiles and exposes `child_issues/1`.
- [ ] **TASK-028** [ui] Create the stateless **ActivityTimeline** function component in `CymphoWeb.IssueLive.Show.ActivityTimeline`; move the activity timeline subtree, timeline-filter buttons, and tool-call-trace expand/collapse rendering (event handling stays on the parent for now); expose attrs `:timeline`, `:timeline_filter`, `:tool_call_traces`. Paths: `lib/cympho_web/live/issue_live/components/activity_timeline.ex`. Implements: `REQ-003`, `DES-007`, `DES-008`. Verifies: `N/A`. Depends: `TASK-024`. Done when: the module compiles and exposes `activity_timeline/1`.
- [ ] **TASK-029** [ui] Create the stateful **ReviewGates** `Phoenix.LiveComponent` in `CymphoWeb.IssueLive.Show.ReviewGates`; move the review-gates / next-owner-assignment / review-signal / contract-nudge / delegation-map / CTO-review-queue / CEO-owner-update-readiness subtree and the related `handle_event` clauses (`"resolve_review_gate"`, `"queue_review_nudge"`, `"queue_contract_nudge"`); implement `update/2` to accept the parent's relevant assigns slice. Paths: `lib/cympho_web/live/issue_live/components/review_gates.ex`. Implements: `REQ-003`, `DES-007`, `DES-008`, `DES-009`. Verifies: `N/A`. Depends: `TASK-024`. Done when: the module compiles, the moved events fire from inside the component, and their observable side effects match the pre-decomposition behaviour.
- [ ] **TASK-030** [ui] Create the stateful **WorkProducts** `Phoenix.LiveComponent` in `CymphoWeb.IssueLive.Show.WorkProducts`; move the work-product form, attach-evidence affordance, and the `handle_event` clauses `"validate_work_product"`, `"attach_work_product"`, `"cancel_work_product"`, `"add_work_product"`, `"remove_work_product"`; implement `update/2`. Paths: `lib/cympho_web/live/issue_live/components/work_products.ex`. Implements: `REQ-003`, `DES-007`, `DES-008`, `DES-009`. Verifies: `N/A`. Depends: `TASK-024`. Done when: the module compiles, the moved events fire from inside the component, and their observable side effects match the pre-decomposition behaviour.
- [ ] **TASK-031** [ui] Create the stateful **AgentPanel** `Phoenix.LiveComponent` in `CymphoWeb.IssueLive.Show.AgentPanel`; move the right-side agent panel (run status, session controls, revision diff trigger) and the `handle_event` clauses `"view_revision_diff"`, `"rollback_to_revision"`, `"fetch_tool_traces"`, `"expand_trace"`, `"collapse_trace"`, `"scroll_position"`; implement `update/2` to accept run-status payloads forwarded via `send_update/2`. Paths: `lib/cympho_web/live/issue_live/components/agent_panel.ex`. Implements: `REQ-003`, `DES-007`, `DES-008`, `DES-009`. Verifies: `N/A`. Depends: `TASK-024`. Done when: the module compiles, the moved events fire from inside the component, and observed run-status updates match the pre-decomposition behaviour.
- [ ] **TASK-032** [ui] Create the stateful **Comments** `Phoenix.LiveComponent` in `CymphoWeb.IssueLive.Show.Comments`; move the comment form, comment list, comment-template picker, and the `handle_event` clauses `"add_comment"`, `"use_comment_template"`, `"delete_comment"`; implement `update/2`. Paths: `lib/cympho_web/live/issue_live/components/comments.ex`. Implements: `REQ-003`, `DES-007`, `DES-008`, `DES-009`. Verifies: `N/A`. Depends: `TASK-024`. Done when: the module compiles, the moved events fire from inside the component, and the comment broadcasts on the existing PubSub topic.
- [ ] **TASK-033** [ui] Rewrite `lib/cympho_web/live/issue_live/show.html.heex` so each major visual section is rendered via `<.live_component module={CymphoWeb.IssueLive.Show.<Stateful>} id={...} ... />` (ReviewGates, WorkProducts, AgentPanel, Comments) or function-component syntax (`<CymphoWeb.IssueLive.Show.Header.header ... />`, etc.) for the four stateless components. Paths: `lib/cympho_web/live/issue_live/show.html.heex`. Implements: `REQ-003`, `DES-007`, `DES-008`, `DES-010`. Verifies: `N/A`. Depends: `TASK-025`, `TASK-026`, `TASK-027`, `TASK-028`, `TASK-029`, `TASK-030`, `TASK-031`, `TASK-032`. Done when: the template is under 700 LoC, contains exactly one invocation per major visual section identified in §6.3, and the rendered HTML in a smoke run is structurally equivalent to pre-decomposition.
- [ ] **TASK-034** [ui] Trim `lib/cympho_web/live/issue_live/show.ex` to the parent LiveView surface only: `mount/3`, `handle_params/3`, the top-level `render/1`, the 20 `handle_info/2` clauses (each now routing to the affected child via `Phoenix.LiveView.send_update/2`), and any genuinely cross-section private helpers; remove the moved `handle_event` clauses and section-only `defp` helpers. Paths: `lib/cympho_web/live/issue_live/show.ex`. Implements: `REQ-003`, `DES-007`, `DES-009`, `DES-010`. Verifies: `N/A`. Depends: `TASK-033`. Done when: the file is under 1,200 LoC, no `handle_event` clause references a section-owned event, every `handle_info` clause that previously mutated section-specific assigns now calls `send_update/2` with the affected child's id, and `mix compile --warnings-as-errors` succeeds.
- [ ] **TASK-035** [test] Extend `test/cympho_web/live/issue_live/show_test.exs` to fire each of the 41 known `handle_event` event strings against the LiveView and assert side-effect equivalence (Repo writes, PubSub broadcasts on `company:#{id}:*` and `issue:#{id}:*` topics, flash messages, redirects) versus a baseline captured before TASK-033. Cover each of the 20 `handle_info` message patterns to assert child components receive the expected `send_update/2` payload. Paths: `test/cympho_web/live/issue_live/show_test.exs`. Implements: `REQ-003`, `DES-007`, `DES-009`. Verifies: `TEST-006` covering `AC-018`, `AC-019`, `AC-020`, `AC-021`, `AC-029`, `AC-030`, `AC-033`. Depends: `TASK-034`. Done when: `mix test test/cympho_web/live/issue_live/show_test.exs` is green and the assertion count reflects coverage of all 41 events and 20 info messages.
- [ ] **TASK-036** [test] Add one focused test file per new component under `test/cympho_web/live/issue_live/components/`: `header_test.exs`, `description_test.exs`, `child_issues_test.exs`, `activity_timeline_test.exs`, `review_gates_test.exs`, `work_products_test.exs`, `agent_panel_test.exs`, `comments_test.exs`. Stateless components assert rendered HTML matches the input assigns; stateful components additionally assert `handle_event/3` produces the expected side effects. Paths: `test/cympho_web/live/issue_live/components/header_test.exs`, `test/cympho_web/live/issue_live/components/description_test.exs`, `test/cympho_web/live/issue_live/components/child_issues_test.exs`, `test/cympho_web/live/issue_live/components/activity_timeline_test.exs`, `test/cympho_web/live/issue_live/components/review_gates_test.exs`, `test/cympho_web/live/issue_live/components/work_products_test.exs`, `test/cympho_web/live/issue_live/components/agent_panel_test.exs`, `test/cympho_web/live/issue_live/components/comments_test.exs`. Implements: `REQ-003`, `DES-007`, `DES-008`, `DES-009`. Verifies: `TEST-007` covering `AC-019`, `AC-020`, `AC-022`. Depends: `TASK-025`, `TASK-026`, `TASK-027`, `TASK-028`, `TASK-029`, `TASK-030`, `TASK-031`, `TASK-032`. Done when: `mix test test/cympho_web/live/issue_live/components/` is green with one passing file per component.
- [ ] **TASK-037** [verification] Run the PR #3 verification gauntlet, including the full TEST-009 smoke checklist for the issue show page. Paths: `N/A — terminal commands and browser interaction`. Implements: `N/A`. Verifies: `TEST-008` covering `AC-023`, `AC-024`, `AC-031`, `AC-033` plus the PR #3 portion of `TEST-009` covering `AC-018`, `AC-022`, `AC-029`, `AC-030`. Depends: `TASK-034`, `TASK-035`, `TASK-036`. Done when: `mix test --warnings-as-errors` is green, `mix credo --strict` reports no new findings, `mix dialyzer` is clean, `wc -l lib/cympho_web/live/issue_live/show.ex` reports under 1,200 lines, `wc -l lib/cympho_web/live/issue_live/show.html.heex` reports under 700 lines, manual browser smoke confirms every section (header, description, review gates, work products, child issues, activity, agent panel, comments) renders identically to a pre-PR build, keyboard tab order is preserved, screen-reader heading hierarchy has no new skips, and Phoenix LiveView mount telemetry is within ±10% of the pre-decomposition baseline.

---

## Short Summary

This spec captures the first phase of architectural consolidation in Cympho. Three duplicated areas are being cleaned up so the codebase stops carrying two implementations for one concept. First, the **Plugins** and **Skills** Elixir contexts are merged into a single public surface (Skills) so there is only one place to call when adding or toggling a plugin. Second, the parallel `lib/cympho/adapters/` and `lib/cympho/agent_adapters/` trees collapse into a single adapter behaviour, registry, Claude Code implementation, mock adapter, and health checker — a one-release deprecation shim catches any forgotten downstream caller. Third, the 3,112-line **issue show LiveView** is decomposed into eight focused components so each visual section owns its own events and rendering. Out of scope: any behavioural change, any UI redesign, the deeper Skills↔Plugins schema merge, and the other 24 audit findings — those land in later specs.

---

## Traceability Matrix

| REQ-ID  | AC-IDs                                                                                              | DES-IDs                          | TASK-IDs                                                                                                                                                                                              | TEST-IDs                                  |
| ------- | --------------------------------------------------------------------------------------------------- | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| REQ-001 | AC-001, AC-002, AC-003, AC-004, AC-005, AC-006, AC-007                                              | DES-001, DES-002, DES-003, DES-004 | TASK-001, TASK-002, TASK-003, TASK-004, TASK-005, TASK-006, TASK-007, TASK-008, TASK-009, TASK-010, TASK-011                                                                                          | TEST-001, TEST-005, TEST-008, TEST-009    |
| REQ-002 | AC-008, AC-009, AC-010, AC-011, AC-012, AC-013, AC-014, AC-015                                      | DES-005, DES-006                 | TASK-012, TASK-013, TASK-014, TASK-015, TASK-016, TASK-017, TASK-018, TASK-019, TASK-020, TASK-021, TASK-022, TASK-023                                                                                | TEST-002, TEST-003, TEST-004, TEST-008, TEST-009 |
| REQ-003 | AC-016, AC-017, AC-018, AC-019, AC-020, AC-021, AC-022                                              | DES-007, DES-008, DES-009, DES-010 | TASK-024, TASK-025, TASK-026, TASK-027, TASK-028, TASK-029, TASK-030, TASK-031, TASK-032, TASK-033, TASK-034, TASK-035, TASK-036, TASK-037                                                            | TEST-006, TEST-007, TEST-008, TEST-009    |
| NFR-001 | AC-023, AC-024, AC-025                                                                              | DES-001, DES-005, DES-007        | TASK-009, TASK-011, TASK-020, TASK-023, TASK-035, TASK-037                                                                                                                                            | TEST-001, TEST-002, TEST-006, TEST-008    |
| NFR-002 | AC-026, AC-027, AC-028                                                                              | DES-001, DES-002, DES-006        | TASK-002, TASK-009, TASK-015, TASK-021                                                                                                                                                                | TEST-001, TEST-003                        |
| NFR-003 | AC-029, AC-030                                                                                      | DES-007, DES-008                 | TASK-033, TASK-035, TASK-037                                                                                                                                                                          | TEST-006, TEST-009                        |
| NFR-004 | AC-031, AC-032, AC-033                                                                              | DES-001, DES-005, DES-006, DES-007 | TASK-011, TASK-015, TASK-021, TASK-023, TASK-035, TASK-037                                                                                                                                            | TEST-003, TEST-006                        |
| NFR-005 | AC-034, AC-035, AC-036                                                                              | DES-001, DES-003, DES-005        | TASK-003, TASK-009, TASK-020, TASK-022                                                                                                                                                                | TEST-001, TEST-002, TEST-004              |
| NFR-006 | AC-037, AC-038, AC-039                                                                              | DES-001, DES-006                 | TASK-010, TASK-011, TASK-021, TASK-023                                                                                                                                                                | TEST-003, TEST-005, TEST-006              |

---

### Draft Spec Compliance Checklist (§11.1)

- [x] Metadata header present, all seven fields filled.
- [x] Requirements Document, Plan Document, and Traceability Matrix present.
- [x] Every functional requirement has `REQ-NNN`, a User Story, and numbered `AC-NNN` acceptance criteria.
- [x] NFR section addresses all six categories (each has acceptance criteria).
- [x] Out-of-Scope section present.
- [x] Plan Document contains all eleven subsections (§6.1 – §6.11).
- [x] Each `DES-NNN` lists which `REQ-NNN`(s) it satisfies.
- [x] Components & Interfaces lists file paths for every entry.
- [x] Dependencies entry is explicitly `None`.
- [x] Integration Points use fenced code blocks with correct language identifiers (`elixir`).
- [x] Testing Strategy maps each `TEST-NNN` to the `AC-NNN`(s) it verifies.
- [x] Rollout Plan present, including rollback steps.
- [x] Risks table populated.
- [x] Research entry is explicitly `None` with a fallback policy noted.
- [x] Task List is absent at first-draft time (now appended in Phase 5 after the gate-4 approval on 2026-05-28).
- [x] Initial Traceability Matrix mapped every `REQ-NNN` and `NFR-NNN` to `AC-NNN`, `DES-NNN`, and `TEST-NNN`; `TASK-IDs` populated in Phase 5.
- [x] No placeholders (`TBD`, `TODO`) remain.
- [x] All assumptions explicitly labeled in the metadata header.
- [x] All code snippets use fenced code blocks with correct syntax highlighting (`elixir`).

### Task List Compliance Checklist (§11.2)

- [x] Task List exists only after Requirements and Plan approval (user approved gate-4 on 2026-05-28).
- [x] Every task follows the §7.1 task format (single concrete action, Paths, Implements, Verifies, Depends, Done when).
- [x] Every implementation task references `REQ-NNN` and `DES-NNN` (verification-only tasks use `Implements: N/A` per §7.2).
- [x] Every test task references `TEST-NNN` and the acceptance criteria it covers.
- [x] Every task has file paths or `Paths: N/A — <reason>`.
- [x] Every task has `Depends:` set to another task ID or `None`.
- [x] Every task has an observable `Done when:` condition.
- [x] Tasks are ordered in implementation sequence and dependency order, grouped per PR.
- [x] Traceability Matrix is updated so every `REQ-NNN` has at least one `TASK-NNN` and one `TEST-NNN`; NFR rows likewise list backing tasks.
- [x] Final verification tasks (TASK-011, TASK-023, TASK-037) include exact test, lint, build, and manual QA commands/checks.
