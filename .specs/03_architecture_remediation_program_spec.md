---
spec_id: 03
feature_name: architecture_remediation_program
status: in-progress
created: 2026-05-28
last_updated: 2026-05-29
source_prompt: |
  "please review app's architecture and try to improve it. simplify and do more bug hunts."
  The user then selected, for this spec's scope, the full program: all confirmed bugs,
  all prioritized simplifications, and the large monolith decompositions.
assumptions:
  - The bare "issues" PubSub broadcasts (work_products, tool_call_traces, issue_thread_interactions) currently have NO subscribers (verified by grep), so they are a latent cross-tenant leak plus dead code. They will be made company-scoped AND routed through Cympho.PubSubGuard rather than deleted, to keep the events available for future consumers while closing the leak — reason: the user chose the "full program," which favors complete fixing over removal, and scoping is the lower-regret option.
  - Agent API keys are 256-bit values from :crypto.strong_rand_bytes(32); therefore salting is NOT required and the "unsalted-SHA256 collision/rainbow" framing is overstated. Only a constant-time hash comparison is adopted — reason: salts mitigate low-entropy secrets, not high-entropy random tokens.
  - The "unmonitored Task in AutoAssignmentReassigner can crash the GenServer" finding is a FALSE POSITIVE and is excluded — reason: lib/cympho/issues/auto_assignment_reassigner.ex already uses Task.Supervisor.async_nolink, handles {:DOWN, ref, ...}, and has a catch-all handle_info/2.
  - The budget-overspend "race" is treated as "verify and, if needed, extend" rather than a confirmed defect — reason: lib/cympho/finances.ex already takes lock: "FOR UPDATE" on BudgetPolicy (line ~256); the open question is whether agent-level spend is covered by the same lock.
  - The program ships as a sequence of independently-revertable, theme-grouped PRs; this single spec defines the program and the Task List (generated after approval) sequences the PRs — reason: one mega-PR would be unreviewable and high-risk.
  - All decompositions and de-duplications are behavior-preserving (no functional or visible change; identical PubSub topics for subscribed events, telemetry, log lines, and error-tuple shapes) — reason: matches the discipline of the in-flight spec 02.
  - IssueLive.Show decomposition is owned by spec 02 and is excluded here to avoid conflict.
---

# 03 — Architecture Remediation & Simplification Program

## Requirements Document

### Introduction

This spec defines a remediation and simplification program for the Cympho platform, derived from a full multi-agent architecture review and bug hunt (21 finder agents across 16 subsystems and 5 cross-cutting sweeps, followed by adversarial verification that refuted ~49% of candidates). The audience is the engineering team. The goal is to close confirmed correctness and security gaps — dominated by cross-tenant data-isolation defects — and to reduce structural debt (dead code, duplication, oversized modules) without changing observable behavior. The business value is a safer multi-tenant product (no cross-company leakage), fewer production 500s, and a codebase that is faster to change.

### Functional Requirements

#### REQ-001 — Eliminate cross-tenant data exposure (multi-tenancy / IDOR)

**User Story**

> As a company operator, I want every data read and every domain-event broadcast to be strictly scoped to my company, so that no agent, plugin, user, or background process can read or receive another company's data.

**Acceptance Criteria**

1. **AC-001** — WHEN a plugin calls `HostServices.get_issue/2`, `HostServices.list_issues/3`, or `HostServices.get_agent/2` THEN the system SHALL return only records belonging to the plugin's `company_id`, and SHALL return `{:error, :not_found}` for a record owned by another company.
2. **AC-002** — WHEN `agent_actions` resolves a blocker reference by UUID (`resolve_blocker_ref/3`) THEN the system SHALL resolve only an `Issue` whose `company_id` matches the acting issue's `company_id`, returning `:error` otherwise.
3. **AC-003** — IF `Workspaces.list_project_workspaces_for_company/1` is called with `nil` THEN the system SHALL return `[]` (never `Repo.all(ProjectWorkspace)`).
4. **AC-004** — WHEN any context broadcasts an issue-related domain event (`work_product_*`, `tool_call_trace_*`, issue thread interaction events) THEN the system SHALL publish only on a company-scoped topic `"company:#{company_id}:issues"`, never the bare `"issues"` topic.
5. **AC-005** — WHERE a company-scoped getter exists (e.g. `Issues.get_company_issue/2`) THE SYSTEM SHALL route all request-driven callers (LiveViews, JSON controllers, MCP, host services) through the scoped variant rather than the unscoped `get_*(id)`.
6. **AC-006** — WHEN a LiveView or controller loads a `Goal`, `ProjectWorkspace`, `ExecutionWorkspace`, or `Issue` by an id taken from params THEN the system SHALL verify the loaded record's `company_id` equals the current company before acting, returning a not-found/redirect otherwise.
7. **AC-007** — WHEN `ReviewNudges`/`stale_scanner` selects a fallback reviewer THEN the system SHALL choose only agents in the same `company_id`, never a global fallback.
8. **AC-008** — WHILE a company-scoped event is broadcast THE SYSTEM SHALL route it through `Cympho.PubSubGuard.broadcast/2`, so a `nil` `company_id` is refused and logged rather than silently published on a malformed topic.
9. **AC-009** — WHEN `Agents.list_agents_by_role/2` and `Agents.get_idle_agent_by_role/2` are called THEN they SHALL filter by `company_id` so role resolution never returns an agent from another company.

#### REQ-002 — Harden authentication, secrets, and write-path whitelisting

**User Story**

> As a security stakeholder, I want secrets to fail-closed and write paths to whitelist fields, so that misconfiguration or hostile params cannot bypass auth or escalate privileges.

**Acceptance Criteria**

1. **AC-010** — IF a JWT signing secret (`:user_jwt_secret`, `:agent_jwt_secret`) is unset WHILE running in `:prod` THEN the system SHALL refuse to boot (raise in `config/runtime.exs`) rather than fall back to `"default-secret-change-in-production"`.
2. **AC-011** — WHEN a user accepts a company invite (`Companies.accept_invite/2`) THEN the system SHALL verify the accepting user's email equals the invite's `email` before creating membership, returning `{:error, :email_mismatch}` otherwise.
3. **AC-012** — WHEN an `Agent` is updated through a request-driven path THEN the system SHALL use a restricted update changeset that excludes `:company_id`, `:governance_status`, `:board_approval_id`, `:requires_board_approval`, `:spent_monthly_cents`, `:permissions`, and `:capabilities`.
4. **AC-013** — WHEN a `User` is updated through a request-driven path THEN the changeset SHALL NOT cast `:company_id`; company assignment SHALL occur only through membership/invite flows.
5. **AC-014** — WHEN an agent API key is verified (`AgentApiKey.valid_api_key?/2`) THEN the system SHALL compare the stored and computed hashes using a constant-time comparison (`Plug.Crypto.secure_compare/2`).

#### REQ-003 — Fix concurrency and crash-safety defects

**User Story**

> As an operator, I want background processes and shared state to be race-free and crash-isolated, so that a single failure cannot corrupt data or trip the supervisor restart budget.

**Acceptance Criteria**

1. **AC-015** — WHEN `Cympho.Adapters.Registry.lookup/1` runs before or during the Registry's own `init/1` THEN the call SHALL NOT raise `:badarg` on a missing ETS table (table creation precedes availability for lookups, or lookups tolerate absence).
2. **AC-016** — WHEN concurrent `record_token_usage` calls debit the same budget policy THEN the system SHALL serialize check-and-debit so cumulative spend cannot exceed the policy limit; the spec SHALL first confirm whether agent-level spend shares the existing `FOR UPDATE` lock and extend it if it does not.
3. **AC-017** — WHEN `EventStore` assigns sequence numbers after a process restart THEN it SHALL NOT reuse or collide sequence ids for a topic.
4. **AC-018** — WHEN a notification delivery exhausts `max_retries` (`RetryWorker`) THEN the system SHALL record a `NotificationDeliveryFailure` capturing the channel and reason.

#### REQ-004 — Fix data-integrity and performance defects

**User Story**

> As a developer, I want hot paths free of N+1 queries and write paths backed by matching validations and DB constraints, so that the system stays fast and returns friendly errors instead of 500s.

**Acceptance Criteria**

1. **AC-019** — WHEN `AgentPrompt.team_status_line/1` builds a CEO/CTO prompt THEN per-agent assignment counts SHALL be computed in a single aggregate query, not one query per agent.
2. **AC-020** — WHEN `ApprovalController.index` lists approvals for a company THEN the query SHALL filter by `company_id` in SQL, not load-all-then-filter in memory.
3. **AC-021** — WHEN `Issues.unblock_dependents/1` runs THEN it SHALL avoid one query per dependent (batch the lookups/updates).
4. **AC-022** — WHEN a controller converts a user-supplied string to an atom (e.g. `issue_interaction_controller`) THEN it SHALL map through an explicit whitelist, never `String.to_existing_atom/1` or `String.to_atom/1` on raw input.
5. **AC-023** — WHERE a changeset declares a `unique_constraint`, `foreign_key_constraint`, or `check_constraint` THE SYSTEM SHALL have a backing DB index/constraint (and any DB constraint SHALL have a changeset handler), so violations surface as changeset errors rather than 500s.

#### REQ-005 — Remove dead code and consolidate duplication

**User Story**

> As a maintainer, I want dead code removed and duplicated logic consolidated, so that the codebase is smaller and a change is made in one place, not many.

**Acceptance Criteria**

1. **AC-024** — WHEN the codebase is searched for call sites THEN zero-caller code SHALL be removed: `Cympho.Comments.Parser`, `Cympho.Orchestrator.Session`, the no-op `Dispatcher.broadcast_state/1` and its call sites, the no-op `Orchestrator.ensure_adapter_failure_table/0` and its call site, and `Cympho.ExecutionPolicies.ExecutionStageResult` (with a migration to drop its table).
2. **AC-025** — WHEN issue list filters are applied THEN they SHALL be expressed through a single generic filter helper rather than the ~36 near-identical `maybe_filter_by_*` private functions in `issues.ex`.
3. **AC-026** — WHEN JWT primitives are used THEN `UserAuthJWT` and `AgentAuthJWT` SHALL both delegate to one shared `Cympho.JWTBase` (sign/verify/validate), eliminating ~150 LOC of duplication and centralizing crypto.
4. **AC-027** — WHEN a controller translates changeset errors THEN it SHALL call one shared helper (`CymphoWeb.ControllerHelpers.translate_errors/1`), not one of 6 copies; identical role-normalization and time-extraction helpers SHALL likewise be consolidated into single shared modules.
5. **AC-028** — WHEN any dead-code removal or de-duplication PR lands THEN `mix test` SHALL stay green and observable behavior (routes, JSON shapes, rendered HTML, PubSub topics, telemetry) SHALL be unchanged.

#### REQ-006 — Decompose monolithic modules

**User Story**

> As a maintainer, I want the largest modules split into focused submodules behind stable facades, so that the code is testable and navigable, with no behavior change.

**Acceptance Criteria**

1. **AC-029** — WHEN `agent_actions.ex` (2581 LOC), `issue_digest.ex` (2300 LOC), `issues.ex` (2175 LOC), `agent_live/show.ex` (1969 LOC), and `runtime_operations.ex` (1545 LOC) are decomposed THEN every public function signature, PubSub topic, telemetry event, log line, and error-tuple shape SHALL remain unchanged.
2. **AC-030** — WHEN a decomposition completes for a targeted file THEN no resulting module SHALL exceed ~800 LOC, and the original module SHALL remain as a thin facade delegating to the new focused submodules.
3. **AC-031** — WHEN each decomposition PR lands THEN `mix test`, `mix credo`, and `mix dialyzer` SHALL be green.

### Non-Functional Requirements

#### NFR-001 — Performance
1. **AC-032** — WHEN an agent prompt is built for a company with N agents THEN the number of DB queries for assignment counts SHALL be O(1), not O(N).
2. **AC-033** — WHILE listing approvals or unblocking dependents THE SYSTEM SHALL issue a bounded number of queries independent of result-set size.

#### NFR-002 — Security
1. **AC-034** — WHEN any request-driven read or write executes THEN it SHALL be scoped to the caller's `company_id`; cross-company access SHALL return not-found/unauthorized.
2. **AC-035** — IF a required secret is missing in production THEN the system SHALL fail closed (no hardcoded fallback) and SHALL never log secret or API-key values.

#### NFR-003 — Accessibility
None — this is backend remediation. The only request-path changes (workspace/goal ownership checks) make no visible UI change; no markup, focus order, or contrast is altered.

#### NFR-004 — Observability
1. **AC-036** — WHEN `PubSubGuard` refuses a malformed/`nil`-company broadcast THEN it SHALL emit a `Logger.warning` with `component: :pub_sub_guard`.
2. **AC-037** — WHEN an invite acceptance fails an email check, or a notification exhausts retries THEN the system SHALL log the event with standard metadata (`company_id`, and `agent_id`/`issue_id` where applicable) and persist the notification failure.

#### NFR-005 — Reliability
1. **AC-038** — WHEN any PR in this program is reverted THEN the system SHALL return to its prior behavior (each PR is independently revertable and behavior-preserving except for the intended bug fix).
2. **AC-039** — WHEN a background GenServer receives an unexpected message THEN it SHALL not crash (a catch-all clause exists), preserving the supervisor restart budget.

#### NFR-006 — Compatibility
1. **AC-040** — WHEN the program ships THEN the public REST API shapes, MCP tool contracts, JWT token format, and all *subscribed* PubSub topic names SHALL remain unchanged. The only topic change is moving the currently-unsubscribed `"issues"` broadcasts to `"company:#{id}:issues"`, which has no current consumer.
2. **AC-041** — WHEN a DB migration is applied (e.g. dropping `execution_stage_results`, adding indexes) THEN it SHALL be backward-compatible with the running release (additive indexes; the dropped table has no readers).

### Out of Scope

- **IssueLive.Show decomposition** — owned by spec 02 (in progress).
- **Plugins/Skills context merge and dual-adapter-tree cleanup** — owned by spec 02 and its follow-ups; this program only fixes correctness/security inside the surviving modules.
- **AutoAssignmentReassigner "unmonitored task" fix** — verified false positive; no change (see assumptions).
- **API-key salting / re-hashing** — unnecessary for 256-bit random tokens; only constant-time comparison is in scope.
- **Net-new features** — no new product behavior; this program is remediation + simplification only.
- **Rewriting the LLM router, MCP server surface, or notification channels** beyond the specific defects listed.

### User Journeys

1. **Operator (tenant isolation) — happy path:** An operator in Company A opens the workspace/goal/issue pages and the agent operations views. Every list and detail view shows only Company A data; no event from Company B ever reaches their channels. Behavior is identical to before, minus the leaks.
2. **Plugin author — alternate path:** A plugin with `read:issues` capability calls `HostServices.list_issues`; it receives only its own company's issues; a crafted `get_issue` for another company's id returns not-found.
3. **Deploy engineer — alternate path:** A production deploy missing `CYMPHO_USER_JWT_SECRET` fails to boot with a clear error, instead of silently running on a public default secret.

---

## Plan Document

### Introduction

The program is a sequence of small, behavior-preserving, independently-revertable PRs grouped by theme, executed on top of the existing Elixir/Phoenix (Phoenix 1.8, LiveView 1.1, Ecto 3.10, OTP 28) codebase. The core technical constraint is **behavior preservation**: except for the intended bug fix in each PR, tests, telemetry, log lines, PubSub topics for subscribed events, REST/MCP contracts, and rendered HTML must remain equivalent. The dominant defect class is cross-tenant data isolation, addressed by routing reads through company-scoped getters and broadcasts through `Cympho.PubSubGuard`. Secondary work hardens auth/secrets, fixes a small set of concurrency/data-integrity/performance defects, removes dead code, consolidates duplication, and decomposes five monoliths behind stable facades. Success criteria: all confirmed multi-tenancy/IDOR paths are scoped and covered by tests; secrets fail-closed; `mix test`/`mix credo`/`mix dialyzer` stay green; and the five largest modules drop under ~800 LOC each without behavioral change.

### Understanding

The agent's restatement: the user asked for an architecture review, simplification, and bug hunt, and then chose the **full program** scope — fix all confirmed bugs, apply all prioritized simplifications, and decompose the monoliths. Key objectives, in priority order:

1. Close confirmed cross-tenant leaks and IDOR (REQ-001) — highest risk.
2. Harden secrets/auth/write-paths (REQ-002).
3. Fix concurrency/crash-safety defects (REQ-003).
4. Fix data-integrity and N+1 performance defects (REQ-004).
5. Remove dead code and consolidate duplication (REQ-005).
6. Decompose the five monolithic modules behind facades (REQ-006).

Open clarifying questions: none remaining. Scope was resolved by the user ("full program"). The "scope-vs-delete" choice for the unsubscribed `"issues"` broadcasts is recorded as an assumption (scope + guard).

### Solution Design

**High-level approach.** Fix the leaf bugs first (cheap, high-value, low-risk), then refactor. Each numbered item below names the exact file and call site, validated against the source during this review. Multi-tenancy fixes follow one of three mechanical shapes: (a) route an unscoped `get_*(id)` to its scoped sibling `get_company_*(company_id, id)`; (b) add a `company_id` filter to a list/broadcast; (c) add an ownership check after a params-driven load. Decompositions follow the spec-02 pattern: extract focused submodules, keep the original as a facade.

**Data flow & architecture.** Reads flow LiveView/controller/MCP/plugin → context function → Repo, and writes additionally broadcast on a company topic that LiveViews subscribe to in `mount/3`. The fix centralizes two crossing points: (1) **scoped getters** as the only request-path read API, and (2) **`PubSubGuard.broadcast/2`** as the only broadcast API for company-scoped events. Decompositions change only internal module boundaries, not these flows.

**Step-by-step execution plan.**

_Phase 1 — Multi-tenancy (REQ-001):_
1. `lib/cympho/plugins/host_services.ex` — `get_issue/2` → use `Issues.get_company_issue(company_id, issue_id)` (thread `company_id` into the function); `list_issues/3` → `Issues.list_issues(Map.put(filters, :company_id, company_id))`; `get_agent/2` → scope to company. (AC-001)
2. `lib/cympho/agent_actions.ex` `resolve_blocker_ref/3` (line ~1181) — match `Repo.get(Issue, ref)` on `%Issue{company_id: ^company_id}`; pass the real `company_id` (drop the leading underscore). (AC-002)
3. `lib/cympho/workspaces.ex` `list_project_workspaces_for_company(nil)` (lines 25–27) — return `[]`. (AC-003)
4. `lib/cympho/work_products.ex` (broadcasts at lines 45, 67, 83), `lib/cympho/tool_call_traces.ex` (line ~285), `lib/cympho/issue_thread_interactions.ex` (lines ~42, ~142) — load the parent issue's `company_id` and broadcast `"company:#{company_id}:issues"` via `PubSubGuard`. (AC-004, AC-008)
5. `lib/cympho/issues.ex` — audit request-path callers of `get_issue/1` (line 465) and route them to `get_company_issue/2` (line 476). (AC-005)
6. LiveView ownership checks: `lib/cympho_web/live/goal_live/index.ex` (delete handler using `Goals.get_goal!`), `lib/cympho_web/live/workspace_live/exec_workspace.ex`, `lib/cympho_web/live/workspace_live/show_workspace.ex` — verify `company_id` against the socket before acting; add `Goals.get_company_goal/2`. (AC-006)
7. `lib/cympho/review_nudges/stale_scanner.ex` `agents_for/2` (line ~229) — remove the global fallback. (AC-007)
8. `lib/cympho/agents.ex` `list_agents_by_role/2`, `get_idle_agent_by_role/2` — add `company_id` filter. (AC-009)

_Phase 2 — Auth/secrets (REQ-002):_
9. `config/runtime.exs` — in `:prod`, `raise` if `CYMPHO_USER_JWT_SECRET`/`CYMPHO_AGENT_JWT_SECRET` are unset; remove the in-module default in `user_auth_jwt.ex`/`agent_auth_jwt.ex`. (AC-010)
10. `lib/cympho/companies.ex` `accept_invite/2` — add `user.email != invite.email -> {:error, :email_mismatch}` to the `cond`. (AC-011)
11. `lib/cympho/agents/agent.ex` — add `update_changeset/2` excluding the sensitive fields; update request-path callers. (AC-012)
12. `lib/cympho/users/user.ex` — confirm `changeset/2` excludes `:company_id` (it does); ensure no request path uses `registration_changeset` for updates. (AC-013)
13. `lib/cympho/agents/agent_api_key.ex` `valid_api_key?/2` — use `Plug.Crypto.secure_compare/2`. (AC-014)

_Phase 3 — Concurrency/crash-safety (REQ-003):_
14. `lib/cympho/adapters/registry.ex` — ensure the ETS table is created and populated before lookups can occur, or guard `lookup/1` against a missing table. (AC-015)
15. `lib/cympho/finances.ex` — verify the `FOR UPDATE` lock (line ~256) also covers agent-level spend; extend with `Ecto.Multi`/row lock if not. (AC-016)
16. `lib/cympho/event_store.ex` — derive the next sequence from persisted/in-table max rather than a counter reset to 0 on restart. (AC-017)
17. `lib/cympho/notifications/retry_worker.ex` — on `max_retries_exceeded`, insert a `NotificationDeliveryFailure` with channel + reason. (AC-018)

_Phase 4 — Data-integrity / performance (REQ-004):_
18. `lib/cympho/agent_prompt.ex` `team_status_line/1` — replace the per-agent count with one `Issues.count_assignments_by_agent_id(company_id)` returning a map. (AC-019)
19. `lib/cympho_web/controllers/approval_controller.ex` `index` — filter approvals by `company_id` in the query. (AC-020)
20. `lib/cympho/issues.ex` `unblock_dependents/1` — batch the dependent lookups/updates. (AC-021)
21. `lib/cympho_web/controllers/issue_interaction_controller.ex` — replace `String.to_existing_atom` with an explicit whitelist map. (AC-022)
22. Schema↔migration reconciliation sweep across `lib/cympho/**` schemas and `priv/repo/migrations` — add missing indexes/constraints behind frequently-filtered columns (`company_id`, `issue_id`, `agent_id`, `status`) and add changeset handlers for unbacked constraints. (AC-023)

_Phase 5 — Dead code / duplication (REQ-005):_
23. Delete zero-caller code (Comments.Parser, Orchestrator.Session, `Dispatcher.broadcast_state/1`, `Orchestrator.ensure_adapter_failure_table/0`, `ExecutionStageResult` + drop migration). (AC-024)
24. Replace the ~36 `maybe_filter_by_*` in `issues.ex` with one generic `filter_optional/3`. (AC-025)
25. Extract `Cympho.JWTBase`; both JWT modules delegate. (AC-026)
26. Extract `CymphoWeb.ControllerHelpers.translate_errors/1` (6 callers), `Cympho.Agents.RoleNormalizer.normalize_role/1` (3 callers), and `Cympho.TimeHelpers` (`run_time/1`, `comment_time/1`, `newest_by/2`) shared by IssueDigest/IssueMemory. (AC-027)

_Phase 6 — Decomposition (REQ-006):_
27. Split `agent_actions.ex` into `WorkflowExecutor` / `GovernanceExecutor` / `DelegationExecutor` behind an `execute/3` dispatcher facade. (AC-029, AC-030)
28. Split `issue_digest.ex` into `IssueState`, `ContributionSummary`, `CompletionContracts`, `ReviewReadiness`, `CommentClassifier`. (AC-029, AC-030)
29. Split `issues.ex` into `Issues.Queries`, `Issues.Commands`, `Issues.Checkout` (+ existing `Issues.StateMachine`), keeping `Issues` as a facade. (AC-029, AC-030)
30. Split `agent_live/show.ex` into LiveComponents (`AgentConfiguration`, `RuntimeProfileSelector`, `InstructionStudio`, `SkillsPanel`) + `CymphoWeb.Format.AdapterReadiness`. (AC-029, AC-030)
31. Split `runtime_operations.ex` into `RuntimeOperations` (aggregation), `RuntimeAnalysis` (scoring), `RuntimeFormatting` (presentation). (AC-029, AC-030)

**Edge cases & failure handling.** `nil` `company_id` anywhere in a scoped read returns `[]`/not-found and (for broadcasts) is refused by `PubSubGuard`. Constant-time comparison must not short-circuit on length. The blocker-ref fix must still allow same-company sibling resolution by title. Decomposition must preserve `defp`→`def` visibility only where the facade needs it; everything else stays private.

**Scalability & performance considerations.** N+1 removals reduce prompt-build and approval-list latency. Added indexes are additive. `PubSubGuard` adds one string check per broadcast — negligible.

**Decisions.**
- **DES-001** — Centralize all company-scoped broadcasts through `Cympho.PubSubGuard.broadcast/2` on `"company:#{id}:issues"`. satisfies: REQ-001.
- **DES-002** — Make scoped getters (`get_company_*`) the only request-path read API; add missing ones (`Goals.get_company_goal/2`). satisfies: REQ-001.
- **DES-003** — Add restricted `update_changeset/2` for Agent; keep User `changeset/2` free of `:company_id`. satisfies: REQ-002.
- **DES-004** — Fail-closed secret loading in `config/runtime.exs` for `:prod`. satisfies: REQ-002.
- **DES-005** — Bind invite acceptance to the invite's email. satisfies: REQ-002.
- **DES-006** — Constant-time API-key hash comparison. satisfies: REQ-002.
- **DES-007** — Boot-order-safe ETS reads in `Adapters.Registry`. satisfies: REQ-003.
- **DES-008** — Verify/extend `FOR UPDATE` to cover agent-level spend. satisfies: REQ-003.
- **DES-009** — Monotonic EventStore sequence across restarts. satisfies: REQ-003.
- **DES-010** — Persist notification delivery failures on retry exhaustion. satisfies: REQ-003.
- **DES-011** — Single-query aggregations and SQL-side filtering on hot paths. satisfies: REQ-004.
- **DES-012** — Whitelist-based atom conversion for params. satisfies: REQ-004.
- **DES-013** — Reconcile changeset constraints with DB indexes/constraints. satisfies: REQ-004.
- **DES-014** — Remove zero-caller modules/functions; drop unused table. satisfies: REQ-005.
- **DES-015** — Generic `filter_optional/3` replacing ~36 helpers. satisfies: REQ-005.
- **DES-016** — Shared `JWTBase`, `ControllerHelpers`, `RoleNormalizer`, `TimeHelpers`. satisfies: REQ-005.
- **DES-017** — Facade-preserving decomposition of the five monoliths. satisfies: REQ-006.
- **DES-018** — Test-first-per-bug, one-theme-per-PR, behavior-preservation discipline. satisfies: REQ-001, REQ-002, REQ-003, REQ-004, REQ-005, REQ-006.

### Components & Interfaces

- **Cympho.PubSubGuard** — refuse malformed/`nil`-company broadcasts (already exists; now wired in). API: `broadcast(topic :: String.t(), message :: term()) :: :ok | {:error, :malformed_topic}`. Path: `lib/cympho/pub_sub_guard.ex`.
- **Cympho.Plugins.HostServices** — capability-gated, company-scoped host API. API: `get_issue(company_id, issue_id, capabilities)`, `list_issues(company_id, filters, capabilities)`, `get_agent(company_id, agent_id, capabilities)`. Path: `lib/cympho/plugins/host_services.ex`.
- **Cympho.Issues** — facade exposing scoped reads. API (unchanged signatures): `get_company_issue/2`, `list_issues/1`, `count_assignments_by_agent_id/1` (new), `unblock_dependents/1`. Path: `lib/cympho/issues.ex`.
- **Cympho.Goals** — scoped goal read. API: `get_company_goal(company_id, id)` (new). Path: `lib/cympho/goals.ex`.
- **Cympho.Agents** — scoped role lookups + restricted update. API: `list_agents_by_role(role, company_id)`, `get_idle_agent_by_role(role, company_id)`; `Cympho.Agents.Agent.update_changeset/2` (new). Paths: `lib/cympho/agents.ex`, `lib/cympho/agents/agent.ex`.
- **Cympho.Companies** — invite binding. API: `accept_invite(token, user_id)` (unchanged signature, added email check). Path: `lib/cympho/companies.ex`.
- **Cympho.JWTBase** — shared JWT primitives. API: `sign(claims, opts)`, `verify_and_decode(token, opts)`. Path: `lib/cympho/jwt_base.ex` (new).
- **CymphoWeb.ControllerHelpers** — shared changeset error translation. API: `translate_errors(changeset) :: map()`. Path: `lib/cympho_web/controllers/controller_helpers.ex` (new).
- **Cympho.Agents.RoleNormalizer** — `normalize_role(binary | atom) :: atom()`. Path: `lib/cympho/agents/role_normalizer.ex` (new).
- **Cympho.TimeHelpers** — `run_time/1`, `comment_time/1`, `newest_by/2`. Path: `lib/cympho/time_helpers.ex` (new).
- **Decomposition submodules** (new, behind facades): `Cympho.AgentActions.{WorkflowExecutor,GovernanceExecutor,DelegationExecutor}`, `Cympho.{IssueState,ContributionSummary,CompletionContracts,ReviewReadiness,CommentClassifier}`, `Cympho.Issues.{Queries,Commands,Checkout}`, `CymphoWeb.AgentLive.{AgentConfiguration,RuntimeProfileSelector,InstructionStudio,SkillsPanel}`, `Cympho.{RuntimeAnalysis,RuntimeFormatting}`. Paths under `lib/cympho/` and `lib/cympho_web/live/agent_live/`.

### Dependencies

- **plug_crypto** — already transitively present via Phoenix/Plug; used for `Plug.Crypto.secure_compare/2`. No new constraint. Reason: constant-time comparison primitive already in the dependency tree.

No other new libraries, frameworks, or tools are introduced.

### Integration Points

Scoped host service (REQ-001):

```elixir
# lib/cympho/plugins/host_services.ex
def get_issue(company_id, issue_id, capabilities) when is_list(capabilities) do
  if "read:issues" in capabilities do
    case Cympho.Issues.get_company_issue(company_id, issue_id) do
      nil -> {:error, :not_found}
      issue -> {:ok, issue}
    end
  else
    {:error, :unauthorized}
  end
end
```

Company-scoped broadcast via the guard (REQ-001):

```elixir
# lib/cympho/work_products.ex
{:ok, wp} = ... # after insert + preload(:issue)
Cympho.PubSubGuard.broadcast(
  "company:#{wp.issue.company_id}:issues",
  {:work_product_created, wp}
)
```

Blocker-ref tenancy match (REQ-001):

```elixir
# lib/cympho/agent_actions.ex
defp resolve_blocker_ref(ref, siblings, company_id) when is_binary(ref) do
  cond do
    uuid_like?(ref) ->
      case Repo.get(Issue, ref) do
        %Issue{company_id: ^company_id} = i -> {:ok, i}
        _ -> :error
      end

    true ->
      case Enum.find(siblings, &(&1.title == ref)) do
        %Issue{} = sibling -> {:ok, sibling}
        _ -> :error
      end
  end
end
```

Fail-closed secrets (REQ-002):

```elixir
# config/runtime.exs (inside `if config_env() == :prod do`)
user_jwt_secret =
  System.get_env("CYMPHO_USER_JWT_SECRET") ||
    raise "CYMPHO_USER_JWT_SECRET must be set in production"

config :cympho, :user_jwt_secret, user_jwt_secret
```

Invite email binding (REQ-002):

```elixir
# lib/cympho/companies.ex — accept_invite/2 cond
user = Users.get_user!(user_id)

cond do
  is_nil(invite) -> {:error, :not_found}
  CompanyInvite.expired?(invite) -> mark_invite_expired(invite); {:error, :expired}
  invite.status != "pending" -> {:error, :already_used}
  user.email != invite.email -> {:error, :email_mismatch}
  true -> Repo.transaction(fn -> ... end)
end
```

Constant-time API-key check (REQ-002):

```elixir
# lib/cympho/agents/agent_api_key.ex
def valid_api_key?(api_key, key_hash) do
  Plug.Crypto.secure_compare(hash_api_key(api_key), key_hash)
end
```

### Testing Strategy

- **Unit:**
  - **TEST-001** — `PubSubGuard` refuses `nil`-company topics; scoped broadcasts succeed. verifies: AC-004, AC-008, AC-036.
  - **TEST-002** — `HostServices.{get_issue,list_issues,get_agent}` return only same-company records. verifies: AC-001.
  - **TEST-003** — `resolve_blocker_ref` rejects a cross-company UUID, accepts same-company. verifies: AC-002.
  - **TEST-004** — `list_project_workspaces_for_company(nil)` returns `[]`. verifies: AC-003.
  - **TEST-005** — scoped getters: `get_company_issue/2`, `get_company_goal/2`, role lookups filter by company. verifies: AC-005, AC-006, AC-009.
  - **TEST-006** — `stale_scanner` fallback never crosses company. verifies: AC-007.
  - **TEST-007** — `accept_invite/2` returns `:email_mismatch` for the wrong user. verifies: AC-011.
  - **TEST-008** — Agent `update_changeset/2` ignores sensitive fields; User changeset ignores `:company_id`. verifies: AC-012, AC-013.
  - **TEST-009** — `valid_api_key?/2` uses constant-time compare (behavioral: matches/rejects). verifies: AC-014.
  - **TEST-010** — `team_status_line/1` issues O(1) count queries (assert via query log/telemetry). verifies: AC-019, AC-032.
  - **TEST-011** — `issue_interaction_controller` rejects unknown atom input without raising. verifies: AC-022.
  - **TEST-012** — `JWTBase` round-trips tokens for both user and agent token types. verifies: AC-026.
  - **TEST-013** — `EventStore` sequence is monotonic across a simulated restart. verifies: AC-017.
  - **TEST-014** — `RetryWorker` persists a delivery failure on exhaustion. verifies: AC-018.
- **Integration:**
  - **TEST-015** — Two-company fixture: a LiveView/controller load of a foreign `Goal`/`Workspace`/`Issue` id returns not-found/redirect. verifies: AC-006, AC-034.
  - **TEST-016** — `ApprovalController.index` returns only the caller's company approvals via a scoped query. verifies: AC-020.
  - **TEST-017** — Adapter `Registry.lookup/1` does not raise at boot ordering. verifies: AC-015.
- **End-to-end:** None — no browser-level flow changes; LiveView integration tests (TEST-015) cover the request paths.
- **Regression:** **TEST-018** — full `mix test` plus `mix credo`/`mix dialyzer` green after each PR; decomposition PRs additionally assert unchanged public API via existing context/LiveView tests. verifies: AC-028, AC-029, AC-031, AC-038, AC-040, AC-041.
- **Manual QA:** **TEST-019** — boot with a missing JWT secret in a `:prod`-like env and confirm the app refuses to start. verifies: AC-010, AC-035.

### Rollout Plan

- **Migration:** Add indexes for frequently-filtered columns (additive, online-safe). Add a migration to drop the `execution_stage_results` table when `ExecutionStageResult` is removed. Backfill: none.
- **Backwards compatibility:** Public REST/MCP/JWT contracts unchanged. The only PubSub topic change moves currently-unsubscribed `"issues"` broadcasts to `"company:#{id}:issues"`; no current consumer is affected (verified by grep — no subscribers).
- **Rollback:** Each PR is independently revertable via `git revert`; no destructive data change except the `execution_stage_results` drop, which is recreatable from migration history if needed.
- **Observability:** Add `Logger.warning` on `PubSubGuard` refusals (`component: :pub_sub_guard`); log invite email-mismatch; persist `NotificationDeliveryFailure` rows. No new external metrics required.
- **Feature flags:** None — fixes are behavior-preserving except the intended bug fix; gating would add risk without benefit. Decomposition PRs are pure refactors, not flagged.

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Routing a getter to its scoped variant breaks an internal (non-request) caller that legitimately needs cross-company reads (e.g. a background scheduler) | Medium | Medium | Audit each `get_*(id)` call site; only convert request-driven paths; keep unscoped getter for internal use and document it. |
| Decomposition silently changes behavior (private→public visibility, macro/compile order) | Medium | High | Behavior-preservation tests run before/after; one monolith per PR; rely on existing context/LiveView test coverage; `dialyzer` gate. |
| Making `"issues"` broadcasts company-scoped breaks an undiscovered subscriber | Low | Medium | Grep confirmed no subscribers; add scoped subscribers where useful in the same PR; revert is trivial. |
| Fail-closed secret raise breaks an existing prod deploy that relied on the default | Low | High | Announce env-var requirement before deploy; document in deploy_example.sh; ship in its own PR. |
| Constant-time/secure_compare on differing-length inputs | Low | Low | `Plug.Crypto.secure_compare/2` handles this; add a test for mismatch. |
| Budget-lock change introduces a deadlock or contention | Low | Medium | Confirm current `FOR UPDATE` scope first; only extend if a real gap exists; load-test the debit path. |

### Research

Context7 MCP was not required: this is internal remediation grounded entirely in the existing codebase; no external library API needed beyond primitives already in the dependency tree. Fallback references (official documentation) for the specific primitives used:

- `Plug.Crypto.secure_compare/2` — https://hexdocs.pm/plug_crypto/Plug.Crypto.html — plug_crypto (current via Phoenix 1.8), accessed 2026-05-28 — constant-time binary comparison for secret/hash checks.
- `Ecto.Multi` / `Repo.transaction` with row locks — https://hexdocs.pm/ecto/Ecto.Multi.html — ecto ~3.10, accessed 2026-05-28 — serialize check-and-debit for budget enforcement.
- `Phoenix.PubSub.broadcast/3` — https://hexdocs.pm/phoenix_pubsub/Phoenix.PubSub.html — phoenix_pubsub (current via Phoenix 1.8), accessed 2026-05-28 — topic semantics confirming the bare `"issues"` topic is global, not company-scoped.

### Codebase Analysis

- **Patterns observed:** Phoenix Context pattern (one context module per domain as public API); adapter behaviour + ETS registry; LiveView mount-then-subscribe with PubSub-driven updates; optimistic concurrency via `lock_version` on issues; tenant scoping via `company_id` filters; a `PubSubGuard` intended to refuse `nil`-company topics (currently unused).
- **Conventions in use:** `:binary_id` UUID PKs; `:utc_datetime` timestamps; `Cympho.Domain` (context) / `Cympho.Domain.Schema` (schema) naming; `Logger` with keyword metadata (`issue_id`, `agent_id`, `company_id`, `component`); tests mirror `lib/` structure.
- **Testing approach in use:** `Cympho.DataCase` (contexts), `CymphoWeb.ConnCase` (controllers), `CymphoWeb.ChannelCase` (channels), `CymphoWeb.LiveCase` (LiveViews); `Ecto.Adapters.SQL.Sandbox` in manual mode; `mock` for adapter tests.
- **Similar implementations already in the repo:** `lib/cympho/documents.ex` already broadcasts on a company-scoped topic — the correct template for fixing the unscoped broadcasts. `Issues.get_company_issue/2` (issues.ex:476) is the scoped-getter template. `User.notification_prefs_changeset/2` is the restricted-changeset template for the new Agent `update_changeset/2`. Spec 02's IssueLive.Show decomposition is the structural template for the agent_live/show split.
- **Integration points new code must hook into:** the supervision tree (`application.ex`) for any new process (none planned); LiveView `mount/3` subscriptions for the newly-scoped topics; `config/runtime.exs` for secret loading.
- **Reusable utilities:** `Cympho.PubSubGuard.broadcast/2`, `Issues.get_company_issue/2`, `Plug.Crypto.secure_compare/2`, `CymphoWeb.LiveCase`, `Ecto.Multi`.

---

## Task List Document

Tasks are grouped into seven independently-revertable PRs, topologically ordered. Task IDs are sequential and never reset per PR. Each implementation PR is behavior-preserving except for its intended fix.

### PR 1 — Multi-tenancy hardening (REQ-001)

> **Status (2026-05-29):** implemented; full suite green (2153 tests) + 10 new PR-1 tests. TASK-001/002 used pre-existing scoped getters; TASK-011 was already satisfied (callers route through `get_company_issue/2`). AC-004 is realized by scoping broadcasts to `company:#{id}:issues` (consumed by `IssueLive.Show`) and adding catch-all `handle_info` to the index/my_issues/kanban LiveViews so they tolerate the now-live events. TASK-015 (`resolve_blocker_ref`) and TASK-018 (`stale_scanner`) cover private functions, and TASK-019 (two-company LiveView integration) needs an authenticated-conn harness — deferred to a follow-up commit within this PR.

- [x] **TASK-001** [service] Add scoped getter `Goals.get_company_goal/2` (and `get_company_goal!/2`) filtering by `company_id`. Paths: `lib/cympho/goals.ex`. Implements: `REQ-001`, `DES-002`. Verifies: `N/A`. Depends: `None`. Done when: the function returns `nil` for a goal owned by another company and the existing goal is returned for the matching company.
- [x] **TASK-002** [service] Add scoped getter `Agents.get_company_agent/2` filtering by `company_id`. Paths: `lib/cympho/agents.ex`. Implements: `REQ-001`, `DES-002`. Verifies: `N/A`. Depends: `None`. Done when: returns `nil` for a cross-company agent id.
- [x] **TASK-003** [service] Add a `company_id` filter to `Agents.list_agents_by_role/2` and `Agents.get_idle_agent_by_role/2`. Paths: `lib/cympho/agents.ex`. Implements: `REQ-001`, `DES-002`. Verifies: `N/A`. Depends: `None`. Done when: both queries include `where: a.company_id == ^company_id` and never return a foreign-company agent.
- [x] **TASK-004** [service] Scope `HostServices.get_issue/list_issues/get_agent` to the plugin's `company_id` (`get_company_issue/2`, `Map.put(filters, :company_id, company_id)`, `get_company_agent/2`); return `{:error, :not_found}` for foreign ids. Paths: `lib/cympho/plugins/host_services.ex`. Implements: `REQ-001`, `DES-002`. Verifies: `N/A`. Depends: `TASK-002`. Done when: no host-service read returns a record from another company.
- [x] **TASK-005** [service] In `resolve_blocker_ref/3`, match `Repo.get(Issue, ref)` on `%Issue{company_id: ^company_id}` and pass the real `company_id` (drop the underscore). Paths: `lib/cympho/agent_actions.ex`. Implements: `REQ-001`, `DES-002`. Verifies: `N/A`. Depends: `None`. Done when: a UUID blocker ref to a foreign-company issue resolves to `:error`.
- [x] **TASK-006** [service] Change `Workspaces.list_project_workspaces_for_company(nil)` to return `[]`. Paths: `lib/cympho/workspaces.ex`. Implements: `REQ-001`, `DES-002`. Verifies: `N/A`. Depends: `None`. Done when: passing `nil` returns `[]`, never `Repo.all(ProjectWorkspace)`.
- [x] **TASK-007** [service] Make the three work-product broadcasts company-scoped via `PubSubGuard` (preload `:issue`, broadcast on `"company:#{issue.company_id}:issues"`). Paths: `lib/cympho/work_products.ex`. Implements: `REQ-001`, `DES-001`. Verifies: `N/A`. Depends: `None`. Done when: no broadcast targets the bare `"issues"` topic; guard refuses a `nil`-company topic.
- [x] **TASK-008** [service] Make the tool-call-trace broadcast company-scoped via `PubSubGuard`. Paths: `lib/cympho/tool_call_traces.ex`. Implements: `REQ-001`, `DES-001`. Verifies: `N/A`. Depends: `None`. Done when: broadcast targets `"company:#{id}:issues"` only.
- [x] **TASK-009** [service] Make the issue-thread-interaction broadcasts company-scoped via `PubSubGuard`, and ensure child issues created by `suggest_tasks` inherit the parent's `company_id`. Paths: `lib/cympho/issue_thread_interactions.ex`. Implements: `REQ-001`, `DES-001`. Verifies: `N/A`. Depends: `None`. Done when: broadcasts are company-scoped and created child issues carry the correct `company_id`.
- [x] **TASK-010** [service] Remove the global reviewer fallback in `stale_scanner` `agents_for/2` so escalation stays within `company_id`. Paths: `lib/cympho/review_nudges/stale_scanner.ex`. Implements: `REQ-001`, `DES-002`. Verifies: `N/A`. Depends: `None`. Done when: `agents_for/2` never queries `list_eligible_agents/1` (no-company variant).
- [x] **TASK-011** [service] Audit request-path callers of `Issues.get_issue/1` and route them through `get_company_issue/2`; keep the unscoped getter for internal/system callers and document that constraint. Paths: `lib/cympho/issues.ex`, affected controllers/LiveViews. Implements: `REQ-001`, `DES-002`. Verifies: `N/A`. Depends: `None`. Done when: grep shows no request-driven caller of `get_issue/1`.
- [x] **TASK-012** [ui] Add company-ownership checks before acting in the goal delete handler and the workspace exec/show LiveViews (compare loaded record `company_id` to socket's current company; not-found/redirect otherwise). Paths: `lib/cympho_web/live/goal_live/index.ex`, `lib/cympho_web/live/workspace_live/exec_workspace.ex`, `lib/cympho_web/live/workspace_live/show_workspace.ex`. Implements: `REQ-001`, `DES-002`. Verifies: `N/A`. Depends: `TASK-001`. Done when: loading a foreign id yields not-found/redirect, never the record.
- [x] **TASK-013** [test] Test `PubSubGuard` refuses `nil`-company topics and scoped broadcasts succeed and reach a company-scoped subscriber only. Paths: `test/cympho/pub_sub_guard_test.exs`. Implements: `REQ-001`, `DES-001`. Verifies: `TEST-001` covering `AC-004`, `AC-008`, `AC-036`. Depends: `TASK-007`. Done when: `mix test test/cympho/pub_sub_guard_test.exs` passes.
- [x] **TASK-014** [test] Test `HostServices.{get_issue,list_issues,get_agent}` return only same-company records and `:not_found` for foreign ids. Paths: `test/cympho/plugins/host_services_test.exs`. Implements: `REQ-001`, `DES-002`. Verifies: `TEST-002` covering `AC-001`. Depends: `TASK-004`. Done when: the test file passes.
- [ ] **TASK-015** [test] Test `resolve_blocker_ref` rejects a cross-company UUID and accepts a same-company one and a same-company sibling title. Paths: `test/cympho/agent_actions_test.exs`. Implements: `REQ-001`, `DES-002`. Verifies: `TEST-003` covering `AC-002`. Depends: `TASK-005`. Done when: the test passes.
- [x] **TASK-016** [test] Test `list_project_workspaces_for_company(nil)` returns `[]`. Paths: `test/cympho/workspaces_test.exs`. Implements: `REQ-001`, `DES-002`. Verifies: `TEST-004` covering `AC-003`. Depends: `TASK-006`. Done when: the test passes.
- [x] **TASK-017** [test] Test scoped getters (`get_company_issue/2`, `get_company_goal/2`, role lookups) never return foreign-company rows. Paths: `test/cympho/issues_test.exs`, `test/cympho/goals_test.exs`, `test/cympho/agents_test.exs`. Implements: `REQ-001`, `DES-002`. Verifies: `TEST-005` covering `AC-005`, `AC-006`, `AC-009`. Depends: `TASK-001`, `TASK-003`, `TASK-011`. Done when: the tests pass.
- [ ] **TASK-018** [test] Test `stale_scanner` fallback never crosses company. Paths: `test/cympho/review_nudges/stale_scanner_test.exs`. Implements: `REQ-001`, `DES-002`. Verifies: `TEST-006` covering `AC-007`. Depends: `TASK-010`. Done when: the test passes.
- [ ] **TASK-019** [test] Two-company integration: a LiveView/controller load of a foreign `Goal`/`Workspace`/`Issue` id returns not-found/redirect. Paths: `test/cympho_web/live/workspace_live_test.exs`, `test/cympho_web/live/goal_live_test.exs`. Implements: `REQ-001`, `DES-002`. Verifies: `TEST-015` covering `AC-006`, `AC-034`. Depends: `TASK-012`. Done when: the tests pass.

### PR 2 — Authentication, secrets & write-path whitelisting (REQ-002)

> **Status (2026-05-29):** implemented; full suite green (2167). JWT secrets now come from config (dev/test default in `config.exs`, prod requires env vars via `runtime.exs` — boot fails if unset); `get_secret_key` uses `fetch_env!` with no hardcoded fallback. `accept_invite/2` binds to the invite email. `Agent.update_changeset/2` (used by `do_update_agent`) drops the 7 sensitive fields — the only caller that relied on mass-assigning `governance_status` was a test, now fixed to use the governance path. API-key check uses `Plug.Crypto.secure_compare/2`. TASK-028 (prod-boot QA) is a manual release check, deferred (the `runtime.exs` `System.fetch_env!` provides the boot-time guarantee).

- [x] **TASK-020** [config] Fail closed on missing JWT secrets in `:prod` (raise in `runtime.exs`) and remove the in-module `"default-secret-change-in-production"` fallbacks. Paths: `config/runtime.exs`, `lib/cympho/user_auth_jwt.ex`, `lib/cympho/agent_auth_jwt.ex`. Implements: `REQ-002`, `DES-004`. Verifies: `N/A`. Depends: `None`. Done when: a `:prod`-env boot without the secrets raises; dev/test behavior unchanged.
- [x] **TASK-021** [service] Add the invite-email check to `Companies.accept_invite/2` (`user.email != invite.email -> {:error, :email_mismatch}`) and log the mismatch. Paths: `lib/cympho/companies.ex`. Implements: `REQ-002`, `DES-005`. Verifies: `N/A`. Depends: `None`. Done when: accepting an invite as the wrong user returns `{:error, :email_mismatch}` and creates no membership.
- [x] **TASK-022** [model] Add `Agent.update_changeset/2` excluding `:company_id`, `:governance_status`, `:board_approval_id`, `:requires_board_approval`, `:spent_monthly_cents`, `:permissions`, `:capabilities`; route request-driven update callers to it. Paths: `lib/cympho/agents/agent.ex`, request-path callers (agent controller/LiveView). Implements: `REQ-002`, `DES-003`. Verifies: `N/A`. Depends: `None`. Done when: a request update cannot change any excluded field.
- [x] **TASK-023** [model] Confirm `User.changeset/2` excludes `:company_id` and ensure no request update path uses `registration_changeset/2`. Paths: `lib/cympho/users/user.ex`, request-path callers. Implements: `REQ-002`, `DES-003`. Verifies: `N/A`. Depends: `None`. Done when: a request-driven user update cannot set `:company_id`.
- [x] **TASK-024** [service] Replace `==` in `AgentApiKey.valid_api_key?/2` with `Plug.Crypto.secure_compare/2`. Paths: `lib/cympho/agents/agent_api_key.ex`. Implements: `REQ-002`, `DES-006`. Verifies: `N/A`. Depends: `None`. Done when: valid keys match and invalid keys reject using constant-time comparison.
- [x] **TASK-025** [test] Test `accept_invite/2` returns `:email_mismatch` for a non-matching user and succeeds for the matching one. Paths: `test/cympho/companies_test.exs`. Implements: `REQ-002`, `DES-005`. Verifies: `TEST-007` covering `AC-011`. Depends: `TASK-021`. Done when: the test passes.
- [x] **TASK-026** [test] Test Agent `update_changeset/2` drops sensitive fields and User changeset drops `:company_id`. Paths: `test/cympho/agents_test.exs`, `test/cympho/users_test.exs`. Implements: `REQ-002`, `DES-003`. Verifies: `TEST-008` covering `AC-012`, `AC-013`. Depends: `TASK-022`, `TASK-023`. Done when: the tests pass.
- [x] **TASK-027** [test] Test `valid_api_key?/2` matches a correct key and rejects an incorrect one. Paths: `test/cympho/agents/agent_api_key_test.exs`. Implements: `REQ-002`, `DES-006`. Verifies: `TEST-009` covering `AC-014`. Depends: `TASK-024`. Done when: the test passes.
- [ ] **TASK-028** [verification] Manual QA: boot a `:prod`-like env with `CYMPHO_USER_JWT_SECRET` unset and confirm the app refuses to start. Paths: `N/A — manual run`. Implements: `N/A`. Verifies: `TEST-019` covering `AC-010`, `AC-035`. Depends: `TASK-020`. Done when: `RELEASE_ENV=prod MIX_ENV=prod` boot (secrets unset) raises and exits non-zero.

### PR 3 — Concurrency & crash-safety (REQ-003)

> **Status (2026-05-29):** implemented; full suite green (2170). `Adapters.Registry.lookup/1`+`all/0` guard against the boot window with `:ets.whereis/1`. `EventStore` seeds its counter from wall-clock so event ids stay monotonic across a GenServer restart. `RetryWorker`'s async timer path now records a dead-letter row on exhaustion (previously only the sync path did) — and writing that row turned out to be doubly broken (a microsecond `failed_at` and a `channel_type: "unknown"` that failed `validate_inclusion`), so failures were never persisted at all; both fixed, and `record_failure` is now crash-safe. **TASK-030 (budget race): verified NOT a bug** — `record_token_usage` runs in one transaction that inserts the usage row then takes `FOR UPDATE` on the policy and re-sums scoped spend, so concurrent debits (incl. agent-scoped) serialize and can't overspend; no change made.

- [x] **TASK-029** [service] Make `Adapters.Registry.lookup/1` boot-order-safe (create+populate the ETS table before lookups are reachable, or guard against a missing table). Paths: `lib/cympho/adapters/registry.ex`. Implements: `REQ-003`, `DES-007`. Verifies: `N/A`. Depends: `None`. Done when: a `lookup/1` during/just-after init returns `:error` instead of raising `:badarg`.
- [x] **TASK-030** [service] Confirm the `FOR UPDATE` budget lock covers agent-level spend; extend with a row lock / `Ecto.Multi` if a gap exists. Paths: `lib/cympho/finances.ex`. Implements: `REQ-003`, `DES-008`. Verifies: `N/A`. Depends: `None`. Done when: concurrent debits against one policy cannot exceed the limit (documented finding either confirmed-and-fixed or shown already-safe).
- [x] **TASK-031** [service] Derive the EventStore next-sequence from the persisted/in-table max so a restart cannot reuse ids. Paths: `lib/cympho/event_store.ex`. Implements: `REQ-003`, `DES-009`. Verifies: `N/A`. Depends: `None`. Done when: sequence is monotonic across a simulated restart.
- [x] **TASK-032** [service] In `RetryWorker`, persist a `NotificationDeliveryFailure` (channel + reason) on `max_retries_exceeded`. Paths: `lib/cympho/notifications/retry_worker.ex`. Implements: `REQ-003`, `DES-010`. Verifies: `N/A`. Depends: `None`. Done when: an exhausted retry inserts a failure row.
- [x] **TASK-033** [test] Test EventStore sequence is monotonic across a simulated restart. Paths: `test/cympho/event_store_test.exs`. Implements: `REQ-003`, `DES-009`. Verifies: `TEST-013` covering `AC-017`. Depends: `TASK-031`. Done when: the test passes.
- [x] **TASK-034** [test] Test `RetryWorker` records a delivery failure on exhaustion. Paths: `test/cympho/notifications/retry_worker_test.exs`. Implements: `REQ-003`, `DES-010`. Verifies: `TEST-014` covering `AC-018`. Depends: `TASK-032`. Done when: the test passes.
- [x] **TASK-035** [test] Test `Registry.lookup/1` does not raise under boot ordering. Paths: `test/cympho/adapters/registry_test.exs`. Implements: `REQ-003`, `DES-007`. Verifies: `TEST-017` covering `AC-015`. Depends: `TASK-029`. Done when: the test passes.

### PR 4 — Data-integrity & performance (REQ-004)

> **Status (2026-05-29):** implemented; full suite green (2173). `Agents.count_active_assignments_by_company/1` collapses the per-agent N+1 in `AgentPrompt.team_status_block` into one grouped query (fetched once, looked up per agent). `Issues.unblock_dependents/1` loads all still-blocked dependents (with blockers preloaded) in one query instead of a `get_issue` per dependent. `Approvals.list_approvals/1` takes a `:company_id` filter (joins `requested_by`); `ApprovalController.index` uses it instead of load-all-then-`Enum.filter`. `issue_interaction_controller` parses status through an explicit whitelist (`:invalid_status` on miss) instead of `String.to_existing_atom`. **TASK-040 (schema↔migration index/constraint reconciliation) is deferred** — it's a broad standalone audit with no single confirmed defect (the cc-ecto sweep findings are advisory); better done as its own focused pass against the verified-bug list rather than speculative index churn here.

- [x] **TASK-036** [service] Add `Issues.count_assignments_by_agent_id/1` (one aggregate query → `%{agent_id => count}`) and use it in `AgentPrompt.team_status_line/1` to remove the per-agent query. Paths: `lib/cympho/issues.ex`, `lib/cympho/agent_prompt.ex`. Implements: `REQ-004`, `DES-011`. Verifies: `N/A`. Depends: `None`. Done when: building a prompt for N agents issues O(1) count queries.
- [x] **TASK-037** [api] Filter `ApprovalController.index` by `company_id` in the query rather than loading all and filtering in memory. Paths: `lib/cympho_web/controllers/approval_controller.ex` (and `lib/cympho/approvals.ex` if a scoped list function is added). Implements: `REQ-004`, `DES-011`. Verifies: `N/A`. Depends: `None`. Done when: only the company's approvals are fetched from the DB.
- [x] **TASK-038** [service] Batch `Issues.unblock_dependents/1` to avoid one query per dependent. Paths: `lib/cympho/issues.ex`. Implements: `REQ-004`, `DES-011`. Verifies: `N/A`. Depends: `None`. Done when: the number of queries is independent of the dependent count.
- [x] **TASK-039** [api] Replace `String.to_existing_atom` in `issue_interaction_controller` with an explicit whitelist map. Paths: `lib/cympho_web/controllers/issue_interaction_controller.ex`. Implements: `REQ-004`, `DES-012`. Verifies: `N/A`. Depends: `None`. Done when: an unknown input value returns a 4xx, never raises.
- [ ] **TASK-040** [migration] Reconcile changeset constraints with DB objects: add missing indexes/constraints on frequently-filtered columns (`company_id`, `issue_id`, `agent_id`, `status`) and add changeset handlers for any unbacked constraints. Paths: `priv/repo/migrations/<new>`, affected schemas under `lib/cympho/**`. Implements: `REQ-004`, `DES-013`. Verifies: `N/A`. Depends: `None`. Done when: every declared `unique/foreign/check` constraint has a backing DB object and the new migration runs clean on a fresh DB.
- [x] **TASK-041** [test] Test `team_status_line/1` issues O(1) count queries (assert via query log/telemetry). Paths: `test/cympho/agent_prompt_test.exs`. Implements: `REQ-004`, `DES-011`. Verifies: `TEST-010` covering `AC-019`, `AC-032`. Depends: `TASK-036`. Done when: the test passes.
- [x] **TASK-042** [test] Test `issue_interaction_controller` rejects an unknown atom value without raising. Paths: `test/cympho_web/controllers/issue_interaction_controller_test.exs`. Implements: `REQ-004`, `DES-012`. Verifies: `TEST-011` covering `AC-022`. Depends: `TASK-039`. Done when: the test passes.
- [x] **TASK-043** [test] Test `ApprovalController.index` returns only the caller's company approvals via a scoped query. Paths: `test/cympho_web/controllers/approval_controller_test.exs`. Implements: `REQ-004`, `DES-011`. Verifies: `TEST-016` covering `AC-020`. Depends: `TASK-037`. Done when: the test passes.

### PR 5 — Dead-code removal & de-duplication (REQ-005)

> **Status (2026-05-29):** dead-code removal shipped; full suite green (2165). Deleted `Cympho.Comments.Parser` (+ its test, the only caller), `Cympho.Orchestrator.Session`, the no-op `Dispatcher.broadcast_state/1` (+ 6 call sites), the no-op `Orchestrator.ensure_adapter_failure_table/0` (+ call site), and `Cympho.ExecutionPolicies.ExecutionStageResult` (+ a drop migration for its leaf table). **The de-duplication tasks (046–049, 050) are deferred for individual review**, because verification showed they are not the safe no-ops the audit assumed: the six `translate_errors/1` implementations (TASK-048) are actually **three behaviourally-different variants** (with/without `to_string`, one using `Enum.reduce`), so consolidating would change JSON error output for endpoints with no test coverage; the JWTBase extraction (TASK-047) is security-critical crypto where a subtle divergence risks auth breakage; and the 36-`maybe_filter_by_*` consolidation (TASK-046) rewrites the hot issues query path. These are real opportunities but warrant careful, separately-reviewed PRs rather than autonomous bundling.

- [x] **TASK-044** [service] Delete zero-caller code: `Cympho.Comments.Parser`, `Cympho.Orchestrator.Session`, the no-op `Dispatcher.broadcast_state/1` + its 6 call sites, the no-op `Orchestrator.ensure_adapter_failure_table/0` + its call site. Paths: `lib/cympho/comments/parser.ex`, `lib/cympho/orchestrator/session.ex`, `lib/cympho/orchestrator/dispatcher.ex`, `lib/cympho/orchestrator.ex`. Implements: `REQ-005`, `DES-014`. Verifies: `N/A`. Depends: `None`. Done when: grep shows no callers and the project compiles.
- [x] **TASK-045** [migration] Remove `Cympho.ExecutionPolicies.ExecutionStageResult` and add a migration dropping the `execution_stage_results` table. Paths: `lib/cympho/execution_policies/execution_stage_result.ex`, `priv/repo/migrations/<new>`. Implements: `REQ-005`, `DES-014`. Verifies: `N/A`. Depends: `None`. Done when: the schema is gone, no callers remain, and the drop migration runs clean.
- [ ] **TASK-046** [service] Replace the ~36 `maybe_filter_by_*` private functions in `issues.ex` with a single generic `filter_optional/3`. Paths: `lib/cympho/issues.ex`. Implements: `REQ-005`, `DES-015`. Verifies: `N/A`. Depends: `None`. Done when: filters route through one helper and existing `issues` tests stay green.
- [ ] **TASK-047** [service] Extract `Cympho.JWTBase` (sign/verify/validate primitives) and make `UserAuthJWT`/`AgentAuthJWT` delegate to it. Paths: `lib/cympho/jwt_base.ex` (new), `lib/cympho/user_auth_jwt.ex`, `lib/cympho/agent_auth_jwt.ex`. Implements: `REQ-005`, `DES-016`. Verifies: `N/A`. Depends: `TASK-020`. Done when: duplication is removed and existing JWT tests pass.
- [ ] **TASK-048** [service] Extract `CymphoWeb.ControllerHelpers.translate_errors/1` and use it from the 6 controllers that duplicate it. Paths: `lib/cympho_web/controllers/controller_helpers.ex` (new), `lib/cympho_web/controllers/{agent,budget,company,routine,routine_trigger,workspace}_controller.ex`. Implements: `REQ-005`, `DES-016`. Verifies: `N/A`. Depends: `None`. Done when: the 6 local copies are removed and JSON error shapes are unchanged.
- [ ] **TASK-049** [service] Extract `Cympho.Agents.RoleNormalizer.normalize_role/1` (3 callers) and `Cympho.TimeHelpers` (`run_time/1`, `comment_time/1`, `newest_by/2`; IssueDigest/IssueMemory). Paths: `lib/cympho/agents/role_normalizer.ex` (new), `lib/cympho/time_helpers.ex` (new), `lib/cympho/{agent_prompt_contract,agent_prompt_contract_eval,agent_instruction_studio,issue_digest,issue_memory}.ex`. Implements: `REQ-005`, `DES-016`. Verifies: `N/A`. Depends: `None`. Done when: the duplicated helpers are removed and behavior is unchanged.
- [ ] **TASK-050** [test] Test `JWTBase` round-trips both user and agent token types (sign → verify_and_decode), including expiry and token-type validation. Paths: `test/cympho/jwt_base_test.exs`. Implements: `REQ-005`, `DES-016`. Verifies: `TEST-012` covering `AC-026`. Depends: `TASK-047`. Done when: the test passes.

### PR 6 — Monolith decomposition (REQ-006) — one module per PR

- [ ] **TASK-051** [service] Decompose `agent_actions.ex` into `AgentActions.{WorkflowExecutor,GovernanceExecutor,DelegationExecutor}` behind an `execute/3` dispatcher facade. Paths: `lib/cympho/agent_actions.ex`, `lib/cympho/agent_actions/*.ex` (new). Implements: `REQ-006`, `DES-017`. Verifies: `N/A`. Depends: `TASK-005`. Done when: each module ≤~800 LOC, public API and behavior unchanged, `mix test` green.
- [ ] **TASK-052** [service] Decompose `issue_digest.ex` into `IssueState`, `ContributionSummary`, `CompletionContracts`, `ReviewReadiness`, `CommentClassifier`, keeping `IssueDigest.build/5` as orchestrator. Paths: `lib/cympho/issue_digest.ex`, new modules under `lib/cympho/`. Implements: `REQ-006`, `DES-017`. Verifies: `N/A`. Depends: `TASK-049`. Done when: each module ≤~800 LOC, behavior unchanged, tests green.
- [ ] **TASK-053** [service] Decompose `issues.ex` into `Issues.Queries`, `Issues.Commands`, `Issues.Checkout` (plus existing `Issues.StateMachine`), keeping `Issues` as a thin facade. Paths: `lib/cympho/issues.ex`, `lib/cympho/issues/*.ex` (new). Implements: `REQ-006`, `DES-017`. Verifies: `N/A`. Depends: `TASK-011`, `TASK-036`, `TASK-038`, `TASK-046`. Done when: facade delegates, public API unchanged, tests green.
- [ ] **TASK-054** [ui] Decompose `agent_live/show.ex` into LiveComponents (`AgentConfiguration`, `RuntimeProfileSelector`, `InstructionStudio`, `SkillsPanel`) and move readiness formatting into `CymphoWeb.Format.AdapterReadiness`. Paths: `lib/cympho_web/live/agent_live/show.ex`, new components under `lib/cympho_web/live/agent_live/`. Implements: `REQ-006`, `DES-017`. Verifies: `N/A`. Depends: `TASK-022`. Done when: parent ≤~800 LOC, rendered HTML and behavior unchanged, LiveView tests green.
- [ ] **TASK-055** [service] Decompose `runtime_operations.ex` into `RuntimeOperations` (aggregation), `RuntimeAnalysis` (scoring), `RuntimeFormatting` (presentation). Paths: `lib/cympho/runtime_operations.ex`, `lib/cympho/runtime_analysis.ex` (new), `lib/cympho/runtime_formatting.ex` (new). Implements: `REQ-006`, `DES-017`. Verifies: `N/A`. Depends: `None`. Done when: each module ≤~800 LOC, snapshot output unchanged, tests green.

### PR 7 — Documentation & final verification

- [ ] **TASK-056** [docs] Document the required JWT secret env vars and the "unscoped `get_*(id)` is internal-only" convention. Paths: `deploy_example.sh`, `CLAUDE.md`. Implements: `REQ-002`, `DES-004`. Verifies: `N/A`. Depends: `TASK-020`, `TASK-011`. Done when: both files state the requirement/convention explicitly.
- [ ] **TASK-057** [verification] Run the full test suite. Paths: `N/A — command`. Implements: `N/A`. Verifies: `TEST-018` covering `AC-028`, `AC-029`, `AC-031`, `AC-038`. Depends: `TASK-001`–`TASK-055`. Done when: `mix test` exits 0.
- [ ] **TASK-058** [verification] Run static analysis and formatting. Paths: `N/A — command`. Implements: `N/A`. Verifies: `TEST-018` covering `AC-031`. Depends: `TASK-057`. Done when: `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer` are clean for the changed modules.
- [ ] **TASK-059** [verification] Manual two-company isolation smoke test (User Journeys 1–2): confirm no cross-company data is visible in workspace/goal/issue/operations views or plugin reads. Paths: `N/A — manual run`. Implements: `N/A`. Verifies: `TEST-015` covering `AC-034`, `AC-040`. Depends: `TASK-057`. Done when: a Company-B operator/plugin sees zero Company-A data end to end.

---

## Short Summary

This spec defines a remediation and simplification program for the Cympho platform, produced from a full multi-agent architecture review and bug hunt. It is for the engineering team. The program closes confirmed correctness and security gaps — most importantly a cluster of cross-tenant data-isolation defects where reads and event broadcasts were not scoped to a company — and hardens authentication and secret handling. It then pays down structural debt by removing dead code, consolidating duplicated logic, and splitting the five largest modules into focused pieces, all without changing how the product behaves. The work ships as seven small, independently-revertable pull requests, each backed by tests. New product features are explicitly out of scope.

---

## Traceability Matrix

| REQ-ID | AC-IDs | DES-IDs | TASK-IDs | TEST-IDs |
| --- | --- | --- | --- | --- |
| REQ-001 | AC-001, AC-002, AC-003, AC-004, AC-005, AC-006, AC-007, AC-008, AC-009 | DES-001, DES-002, DES-018 | TASK-001 – TASK-019 | TEST-001, TEST-002, TEST-003, TEST-004, TEST-005, TEST-006, TEST-015, TEST-017 |
| REQ-002 | AC-010, AC-011, AC-012, AC-013, AC-014 | DES-003, DES-004, DES-005, DES-006, DES-018 | TASK-020 – TASK-028 | TEST-007, TEST-008, TEST-009, TEST-019 |
| REQ-003 | AC-015, AC-016, AC-017, AC-018 | DES-007, DES-008, DES-009, DES-010, DES-018 | TASK-029 – TASK-035 | TEST-013, TEST-014, TEST-017 |
| REQ-004 | AC-019, AC-020, AC-021, AC-022, AC-023 | DES-011, DES-012, DES-013, DES-018 | TASK-036 – TASK-043 | TEST-010, TEST-011, TEST-016 |
| REQ-005 | AC-024, AC-025, AC-026, AC-027, AC-028 | DES-014, DES-015, DES-016, DES-018 | TASK-044 – TASK-050 | TEST-012, TEST-018 |
| REQ-006 | AC-029, AC-030, AC-031 | DES-017, DES-018 | TASK-051 – TASK-055 | TEST-018 |
| NFR-001 | AC-032, AC-033 | DES-011 | TASK-036, TASK-037, TASK-038, TASK-041, TASK-043 | TEST-010, TEST-016 |
| NFR-002 | AC-034, AC-035 | DES-002, DES-004 | TASK-004, TASK-011, TASK-012, TASK-020, TASK-022, TASK-023, TASK-028 | TEST-015, TEST-019 |
| NFR-003 | None — backend remediation, no UI change | N/A | N/A | N/A |
| NFR-004 | AC-036, AC-037 | DES-001, DES-010 | TASK-007, TASK-008, TASK-009, TASK-021, TASK-032 | TEST-001, TEST-014 |
| NFR-005 | AC-038, AC-039 | DES-018 | TASK-029, TASK-057, TASK-058 | TEST-018 |
| NFR-006 | AC-040, AC-041 | DES-017, DES-018 | TASK-040, TASK-051, TASK-052, TASK-053, TASK-054, TASK-055, TASK-057 | TEST-018 |

---

## Draft Spec Compliance Checklist (§11.1)

- [x] Metadata header present, all seven fields filled (spec_id, feature_name, status, created, last_updated, source_prompt, assumptions).
- [x] Requirements Document, Plan Document, and Traceability Matrix present.
- [x] Every functional requirement has `REQ-NNN`, a User Story, and numbered `AC-NNN` acceptance criteria.
- [x] NFR section addresses all six categories (Accessibility marked `None — <reason>`).
- [x] Out-of-Scope section present.
- [x] Plan Document contains all eleven subsections (§6.1–§6.11).
- [x] Each `DES-NNN` lists which `REQ-NNN`(s) it satisfies.
- [x] Components & Interfaces lists file paths for every entry.
- [x] Dependencies entry includes name, version constraint, and reason.
- [x] Integration Points use fenced `elixir` code blocks.
- [x] Testing Strategy maps each `TEST-NNN` to the `AC-NNN`(s) it verifies.
- [x] Rollout Plan present, including rollback steps.
- [x] Risks table populated.
- [x] Research entries include source URL, version, and research date; Context7 fallback noted.
- [x] Task List is absent (not yet approved at the phase-4 gate).
- [x] Initial Traceability Matrix maps every `REQ-NNN` to `AC-NNN`, `DES-NNN`, `TEST-NNN`; `TASK-IDs` are `Pending task approval`.
- [x] No `TBD`/`TODO` placeholders remain.
- [x] All assumptions labeled in the metadata header (and reflected in Out of Scope / Solution Design).
- [x] All code snippets use fenced blocks with correct syntax highlighting.

---

## Task List Compliance Checklist (§11.2)

- [x] Task List exists only after Requirements and Plan approval (approved at the phase-4 gate before generation).
- [x] Every task follows the §7.1 format (id, type, action, Paths, Implements, Verifies, Depends, Done when).
- [x] Every implementation task references a `REQ-NNN` and a `DES-NNN`.
- [x] Every test task references a `TEST-NNN` and the `AC-NNN`(s) it covers.
- [x] Every task has file paths or `Paths: N/A — <reason>`.
- [x] Every task has `Depends:` set to another task ID or `None`.
- [x] Every task has an observable `Done when:` condition.
- [x] Tasks are ordered in implementation/dependency sequence, grouped into seven revertable PRs.
- [x] Traceability Matrix updated so every `REQ-NNN` maps to at least one `TASK-NNN` and one `TEST-NNN`.
- [x] Final verification tasks include exact commands (`mix test`, `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`) and the manual two-company smoke check.
