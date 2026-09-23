# Small-VPS hardening implementation plan

> Execute with subagent-driven development, regression-first tests, task-scoped review, and a final integration review.

**Goal:** Implement the approved first phase of the application audit: reachable authorization fixes, reliable run controls, bounded subprocess resources, targeted query/render reductions, and safe API serialization.

**Architecture:** Retain Phoenix contexts, OTP supervision, existing adapters and response envelopes. Make ownership checks authoritative at mutation boundaries; remove duplicated work rather than introducing replacement frameworks.

**Spec:** The user-approved plan in this conversation, sections 3 and 5. Section 4 is explicitly deferred.

## Global Constraints

- Work in `/Users/zaali/dev/cympho` on its current branch, as explicitly requested. Preserve all pre-existing uncommitted changes. Do not commit, stash, reset, switch branches, push or deploy.
- Read AGENTS.md. Use native Superpowers TDD and verification. Keep changes surgical and maintain existing style.
- First-phase work only. Do not implement the separate recovery/budget/replay/lease redesign backlog.
- Task ownership below is exclusive. Do not modify another task's files without coordinator approval. Ask the coordinator about necessary cross-task edits.
- No additional dependencies or production schema changes are planned. No provider credentials, paid calls, production DB writes, or production settings changes.
- Run tests through `.superpowers/sdd/2026-09-23-small-vps-hardening/run-tests.py` with your task id. This serializes shared compilation and uses a task-specific disposable test DB. Do not run raw `mix test`, reset a database, or run broad `mix format`.
- Format only files you own. Do not spawn subagents. Write a report listing changed paths, RED/GREEN commands/results, implementation decisions, and remaining concerns.
- Preserve features and existing response envelopes. Exclude credentials and secret-bearing configuration from JSON projections.
- Output limit is 8,000,000 bytes, following the existing AgentRunner contract. The small-VPS target uses the existing `low` profile; do not change the global default for existing installations.

## Task 1: Routine and launch-item tenant boundaries; bounded routine overview

**Ownership:** `lib/cympho/routines.ex`, `lib/cympho/routines/routine.ex`, `lib/cympho_web/live/routine_live/*`, `lib/cympho/launch_items.ex`, `lib/cympho/launch_items/*`, `lib/cympho_web/controllers/launch_item_controller.ex`, and related routine/launch-item tests. Do not edit other controllers or general issue contexts.

- Write failing cross-company context and LiveView tests: forged create company, forged update company, cross-company agent/project, non-null foreign routine exposed by local association, and writer-A/viewer-B launch-item move.
- On create take tenant scope from the authenticated boundary. Make company ownership immutable on ordinary updates. Enforce association consistency in the schema/context as well as the web layer.
- Preserve legacy null-company routines only when all non-null associated resources consistently belong to the requested company; never let a non-null foreign company through fallback lookup.
- Replace routine overview and index preloads of all historical runs with aggregate counts, stale/failure existence flags, and latest-run projections. Keep exact global health counts, trigger presentation, latest-run labels and access to routine detail history.
- Do not preload the entire run history for command selection or streamed page entries. Reuse pagination already present. Health counts need SQL counts, not counts after a limit.
- Add large-history and time-boundary regression coverage proving exact health values and bounded returned run records.
- Verify related existing context, controller and LiveView tests. Report any pre-existing failures separately.

## Task 2: Company ownership, membership revocation and company JSON

**Ownership:** `lib/cympho/companies.ex`, relevant company membership/invite schemas, `lib/cympho/company_rbac.ex` if necessary, `lib/cympho_web/controllers/company_controller.ex`, `lib/cympho_web/live/company_live/*`, `lib/cympho_web/socket.ex`, `lib/cympho_web/company_channel.ex`, related company and channel tests. Do not alter replay behavior or unrelated company import/export.

- Write failing tests for board-member/admin grant, invite or removal of owner; last-owner removal under concurrent requests; allowed lower-role management; legitimate owner actions.
- Require an owner to grant/remove owner status and protect the last owner transactionally. Enforce via actor-aware context entrypoints used by authenticated boundaries. Keep trusted bootstrap/internal fixture paths functioning without creating a client-selectable bypass.
- Re-read/lock authority and target state where necessary to avoid stale authorization. Cover owner invite acceptance if grants could outlive authority.
- After committed membership removal disconnect `socket:<company_id>:<user_id>`; recheck membership on company channel joins including delegated subtopics. Do not disconnect users from unrelated companies. Agent-token lifecycle changes are deferred.
- Replace raw Ecto responses for memberships, invites and join requests with explicit allowlisted maps preserving the `data` envelope. Exclude token/hash/secret material from list responses; an authorized invite creation may return the newly issued token needed by the existing workflow.
- Add successful mutation/nonempty read JSON tests as well as revocation and scope tests. Do not fix the separate join-request discoverability policy in this task.

## Task 3: Bind GitHub actions to the authorized repository

**Ownership:** `lib/cympho_web/controllers/github_controller.ex`, `lib/cympho/github.ex`, GitHub/PR-contract helpers, PR URL and merge-related portions of `lib/cympho/agent_actions.ex`, corresponding GitHub/action tests. Preserve pre-existing AgentActions changes in all other areas.

- Write failing signed-webhook tests with project A's valid secret and project B's issue/PR URL. Cover pull-request and review events and no side effects on rejected events.
- Bind issue.project_id to the project whose secret was verified before dedup/action processing; authenticate against the canonical base repository while preserving normal fork PRs.
- Validate PR owner/repository against the issue's project repository when linking a PR and before server-side merging. Reuse a small canonical repository parser if needed; cover supported GitHub HTTPS/SSH repo URLs and reject malformed/mismatched URLs.
- Never perform real GitHub calls in tests. Mock only the network boundary. Do not add project-secret runtime injection; that is separate work.
- Verify existing webhook and AgentActions PR/merge tests, preserving valid workflows and quality gates.

## Task 4: Authoritative run controls, pure preflight and bounded poll/timer work

**Ownership:** `lib/cympho/agents.ex`, `lib/cympho/orchestrator.ex`, `lib/cympho/orchestrator/dispatcher.ex`, `lib/cympho/runtime_preflight.ex`, `lib/cympho_web/controllers/agent_controller.ex`, related agent/session/dispatcher/preflight tests. Preserve existing dispatcher edits. Do not change adapter files or recovery policy.

- Write regressions for progress/kill during a normal delegated dispatcher run and for preflight leaving an error-state agent unchanged.
- Resolve active session ownership through the orchestrator/adapter/run ledger rather than gating on heartbeat `:running`. Preserve existing return shapes, legacy path compatibility and no-run semantics. Verify the exact current owner before cancellation; do not stop a reassigned successor or release a live child's admission slot prematurely.
- Make preview selection read-only; keep error recovery only on the actual dispatch path.
- Coalesce pending demand polls without dropping the final wake. Preserve periodic polling and company-specific requests; do not reintroduce multiple timer chains or an unbounded drain loop under continuous input.
- Keep exactly one heartbeat timer per orchestrator across fallback/no-work retries; stale timer messages must not multiply chains or compress liveness miss intervals.
- Add burst-wakeup/fallback regression tests with observable poll or telemetry counts and lifecycle outcomes.
- Replace AgentController's raw role-update schema response with its existing safe agent projection or an equivalent explicit allowlist.

## Task 5: Direct-adapter output caps and Agrenting cleanup

**Ownership:** `lib/cympho/adapters/process_adapter.ex`, `codex_adapter.ex`, `cursor_adapter.ex`, `agrenting_adapter.ex`, one narrowly scoped shared adapter helper if needed, and associated adapter tests. Coordinate before changing AgentRunner or RunDeadline shared behavior.

- Write output-flood regressions for each direct adapter before implementation. Use controllable local fixture commands, not installed paid model CLIs.
- Apply the existing AgentRunner ceiling of 8,000,000 bytes and error convention `{:output_limit_exceeded, limit, diagnostic_tail}`. Enforce any existing smaller configured limit without permitting a larger one.
- Bound accumulated output and diagnostic tails; include an upstream limiter where supported so the port mailbox cannot grow without bound. Preserve exit/cancel behavior and structured output parsing below the limit.
- On overflow fail, synchronously terminate/reap the owned child tree, then emit one terminal result. Never truncate structured output and pretend success. Verify worker/child/slot cleanup.
- On Agrenting timeout or polling error after paid hiring creation, attempt cancellation unless the remote state is already terminal. Preserve hiring ID and cancellation failure in terminal error evidence; do not claim remote cleanup succeeded when it failed. Durable provider reconciliation remains deferred.
- Add timeout, poll-error, terminal-status and cancellation-failure tests using mocked HTTP boundary. No paid/provider requests.

## Task 6: Finch startup, lazy preferences and board duplicate work

**Ownership:** `lib/cympho/application.ex`, `lib/cympho/notifications/dispatcher.ex`, `lib/cympho_web/live/kanban_live/*`, `lib/cympho_web/components/issue_digest.ex` only as needed for precomputed digest input, corresponding runtime/notification/kanban tests. Do not modify Routines files, general Issues preloads or runtime preflight.

- Write a running-Finch regression (not only Config.Reader assertions), then pass configured pool options into the actual Finch child spec. The existing low profile must yield size 2; keep current default/override behavior.
- Remove unconditional all-tenant notification preference warmup. Retain correct lazy loading, preference invalidation, defaults and first delivery; test a cold cache with real preferences.
- Eliminate duplicate board mount/handle_params loading and equivalent tuple/Endpoint broadcast recomputation. Preserve project filtering, deletions, ordering and updates that arrive by only one existing event path.
- Compute each full issue digest once per relevant board refresh and reuse the result for cards and the shared banner. Do not globally drop comment preloads or change digest semantics. Preserve rendering and event correctness.
- Add query/digest invocation or telemetry assertions alongside rendered-state tests. Avoid brittle tests inspecting source text.

## Task 7: Safe workspace and budget API projections

**Ownership:** `lib/cympho_web/controllers/workspace_controller.ex`, `lib/cympho_web/controllers/budget_controller.ex`, narrowly scoped JSON view/helper modules if justified, and related controller tests. Company and Agent controllers belong to Tasks 2 and 4.

- Write failing successful read/create/update tests for nonempty project/execution workspace and budget responses.
- Replace raw Ecto structs with explicit allowlisted JSON maps, including existing workspace subresource response paths that are unsafe. Preserve existing envelopes and normal scalar response fields.
- Never serialize Ecto metadata, unloaded associations, plaintext injected secrets, secret bindings, credential-bearing config, agent keys or invite tokens through a generic map dropper.
- Reuse existing safe projections where present. Test secret omission with deliberate sentinel values and round-trip normal fields. This task does not change Budget/Policy consistency or enforcement semantics.

## Integration and verification

- Maintain a source snapshot of the user baseline and per-task diff/review artifacts outside tracked code. No commits are authorized by this workflow.
- Run task-scoped spec and quality review after each task, fixing important findings, then one broad final integration review of the task-only diff.
- Run the full suite in a disposable DB with all migrations. Compare failures against the snapshot baseline; do not fix unrelated existing failures or hide them.
- Check formatting on changed files, compile, and run focused/static checks plus browser smoke only if needed. Ego Lite only; one task session; never clear browser data.
- Use the existing low resource profile for controlled trials, without changing production configuration. Measure available local before/after query counts, retained history and bounded-output behavior. Do not claim a 2-core/2-GB production capacity certificate without that Linux/cgroup environment.
- Document measured results and exact external benchmark steps (cold boot, 10-minute idle, 100 idle agents, active+queued run, wake burst, long history; three repetitions) and remaining deferred risks.
