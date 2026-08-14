# Closing the Paperclip gap

Status: active; all thirteen defined gaps closed
Created: 2026-07-30
Last hardened: 2026-08-14 (G6 and G13 closed with live provider and merge coverage)
Cympho baseline: `44ed6c3`
Paperclip baseline: `c62fa8d6a03377370c3a08ac49320cbba1c44227`, public `master` inspected on 2026-07-30

## Goal

Close the gaps that make Paperclip the safer default for a new user while preserving the parts where Cympho is already differentiated: supervised BEAM operations, owner-readable delivery evidence, Simple/Advanced modes, issue-level runtime control, and CTO-mediated swarms.

This is not a plan to copy every Paperclip screen or match community size through code. It prioritizes correctness, owner trust, and small end-to-end slices that can be verified in this repository.

## Working rules

- Treat Paperclip README claims as leads, then confirm behavior in source or tests.
- Fix correctness and spend-safety gaps before adding broad surfaces.
- Keep Simple mode plain-language and decision-oriented. Put provider, policy, provenance, and diagnostic detail in Advanced mode.
- Preserve company scoping for every query, mutation, PubSub event, and counter.
- Never persist provider credentials in browser storage, logs, fixtures, screenshots, or import previews.
- Use Ego Lite for browser QA. Do not use Safari or another browser.
- Add one focused regression test for every claimed gap closure, then run the relevant suite and the full suite before release.
- Update this document when a tranche lands. A checked box must link to code/tests or name the verification command.
- Do not mark a gap closed from a shallow `mix cympho.compare` shell alone. Close only when the register target outcome and verification column are met by code plus focused tests.

## What Cympho should preserve

These are not rebuild targets:

- Company and issue Pause/Resume/Stop, Low Power mode, adapter-session cancellation, and runtime audit events.
- Simple/Advanced UI, Compact/Detailed page density, command palette, and keyboard shortcuts.
- Current-task prompt precedence, triggering-comment delivery, prompt context telemetry, and instruction-delivery receipts.
- Review nudges, PR evidence, issue digests, owner handoffs, and CTO-mediated swarms.
- Company-scoped data access, membership roles, board governance, principal grants, and PubSub isolation.
- Executable company blueprints and their persisted launch manifests.
- Local execution workspaces, runtime services, leases, probes, previews, and workspace health surfaces.

## Priority definitions

- **P0:** correctness, double execution, spend leakage, or an owner can miss a blocking decision.
- **P1:** material product parity or trust gap with a bounded implementation path.
- **P2:** ecosystem/adoption work whose value grows after the control plane is correct.

## Gap register

| ID | Priority | Gap | Current evidence | Target outcome | Verification |
| --- | --- | --- | --- | --- | --- |
| G1 | P0 | Run-bound checkout ownership — **closed**. | A pending run binds `checkout_run_id` before provider dispatch; duplicate bind loss cancels only the duplicate; start failures propagate. Terminal cleanup requires exact `checkout_run_id == run_id` ownership, so an old run cannot clear a successor run and an unbound same-agent checkout is preserved because it may belong to a newer dispatch. Dispatcher recovery leaves successor-owned checkout state intact. | Atomically bind one non-terminal run to a checked-out issue. A duplicate run must lose before adapter dispatch, and an old terminal run must never clear a successor's lock. | `mix test test/cympho/orchestrator/dispatcher_test.exs test/cympho/orchestrator_test.exs test/cympho/heartbeat_engine_test.exs` (ownership/recovery regressions green on 2026-08-06). |
| G2 | P0 | Authoritative runtime spend enforcement — **closed with a documented cleanup risk**. | Terminal provider usage is normalized into a run-linked, tenant-validated, idempotent finance ledger. Threshold usage and incidents commit before enforcement; future preflight/run creation fail closed; hard stops cancel company, agent, issue, project, and goal work. An agent hard stop stops its live issue orchestrators, cancels active runs only for the exact `(company_id, agent_id)` pair, cancels its wakes, and then pauses it; malformed cross-company run rows remain untouched. A process crash after the ledger commit but before external cleanup still relies on recovery. | Persist the spend that crosses a threshold, evaluate one authoritative policy path, create an incident, stop further dispatch, and leave the triggering usage auditable. | `mix test test/cympho/runtime_spend_enforcement_test.exs test/cympho/finances/budget_scope_hard_stop_test.exs` (green on 2026-08-06). |
| G3 | P0 | Unified owner attention — **closed for the defined sources**. | `Cympho.OwnerAttention` normalizes human issues, reviews, ordinary and board approvals, pending questions, confirmations, and proposed-task interactions, latest unresolved failed runs, and unresolved budget incidents into one company-scoped Inbox source. Interaction rows use plain summaries instead of echoing payloads. Attention and persisted Inbox rows deduplicate by issue; interaction create/resolve events refresh a mounted Inbox; the nav badge uses `OwnerAttention.unresolved_count/2` (membership-aligned with `list_items/3`, not a second source). Review wakes reject cross-company agent/issue pairs at enqueue and remain company-scoped when an agent filter is selected. Rows remain severity-ordered, with diagnostics hidden in Simple mode and redacted stable diagnostics shown in Advanced mode. | One company-scoped Decisions feed that normalizes approvals, questions/reviews, failed runs, blockers, and spend/runtime alerts; urgent items sort first and the badge reflects the same source of truth. | `mix test test/cympho/owner_attention_test.exs test/cympho/wakes_test.exs test/cympho/issue_thread_interactions_test.exs test/cympho_web/live/inbox_live_test.exs test/cympho_web/user_auth_test.exs` (G3 suites green on 2026-08-06). |
| G4 | P1 | Explicit Agent / Plan / Ask work mode — **closed for built-in repo-capable adapters**. | Issues persist `standard`, `planning`, and `ask`; create/detail/API surfaces preserve the mode; prompts and server-side actions enforce the contract; structured questions/confirmations resume correctly. Claude uses plan permissions and Codex uses a read-only permission profile plus read-only Bubblewrap workspace mount for Plan/Ask. External HTTP/process adapters still depend on their own isolation contract. | Add `standard`, `planning`, and `ask` modes. Simple mode presents plain-language choices; prompts enforce the selected contract. | Work-mode schema/API/LiveView tests, prompt/action tests, `mix test test/cympho/agent_runner_test.exs test/cympho/adapters/codex_adapter_test.exs` (green on 2026-08-06). |
| G5 | P1 | Revision-pinned plan approval — **closed**. | Planning documents sync to the canonical revisioned `work-mode-plan`; confirmation payloads are server-pinned and immutable; stale acceptance returns `:stale_target_revision` without mutation or wake; interactions and creator agents are issue/company validated. | Confirmation targets a document revision and rejects stale approval without waking an agent. | `mix test test/cympho/issue_thread_interactions_test.exs` plus work-mode action coverage (green on 2026-08-06). |
| G6 | P1 | Remote sandbox provider lifecycle — **closed**. | `Cympho.Workspaces.Drivers.Ssh` is a real registered provider built on OTP's `:ssh`: acquire provisions an isolated remote directory, execute returns real stdout/stderr/exit status with channel-window flow control, release removes the directory, and cancel signals the recorded remote shell before teardown. Host keys are pinned by SHA-256 fingerprint through an in-memory `ssh_client_key_api` callback (no key material on disk, no implicit host-key learning), and `Cympho.Workspaces.EnvironmentConfig` resolves connection settings from deployment config plus allowlisted workspace metadata, with credentials read only from the company secret store. `EnvironmentLifecycle` passes that resolved config on acquire/release/cancel and for leases. Vendor SaaS drivers (E2B, Daytona, Modal, Kubernetes) remain unregistered and fail closed. | Define a provider driver contract, registry, lifecycle, cancellation/cleanup semantics, secret boundaries, and one real opt-in provider after a fake driver proves the contract. | `mix test test/cympho/workspaces/drivers/ssh_test.exs test/cympho/workspaces/environment_config_test.exs test/cympho/workspaces/environment_driver_test.exs test/cympho/workspaces/environment_lifecycle_test.exs test/cympho/runtime_test.exs`. The SSH suites run against a live OTP `:ssh` daemon (`Cympho.SshTestServer`) with a real shell, so acquire/execute/release, host-key rejection, output truncation, timeouts, and shell-injection refusal are proven over the actual protocol rather than against a fake. |
| G7 | P1 | Governed dynamic extension ecosystem — **closed for dynamic MCP governance**. | Fabricated marketplace metrics were removed; catalog entries are source-backed with a startable worker. Plugins expose tools through capability-gated `HostServices.expose_tool`, which registers into `Cympho.Mcp.ToolRegistry`. Tools appear on MCP list/call only after company-scoped `ToolGrants` (`allow`/`deny`/`pending`/`revoked`); unregister revokes grants; calls audit and rate-limit mutations; forged tenant attributes fail closed. Versioned external marketplace install/update/fork provenance beyond the local catalog is not claimed. | Versioned catalog sources, install/update/fork provenance, a real dynamic tool registry, capability grants, approvals, revocation, and tenant-safe MCP exposure. Remove synthetic marketplace metrics immediately. | `mix test test/cympho/plugins/catalog_test.exs test/cympho/mcp/tool_registry_grants_test.exs test/cympho/mcp/server_mutation_throttle_test.exs test/cympho/multi_tenancy_pr1_test.exs` (green on 2026-08-06). Comparator `governed_dynamic_mcp` = parity. |
| G8 | P1 | Durable evaluation and feedback loop — **closed for company-scoped domain records**. | `Cympho.Evaluations` persists suites, immutable runs/results, redacted provenance (model/prompt/skill hashes, redacted runtime profile), append-only owner feedback votes/reasons, deterministic `rerun_suite/2`, and `compare_runs/2` with tenant isolation. Prompt-contract suites reuse deterministic fixtures. Instruction Tuner additive preview/apply/rollback remains the reviewable instruction path; feedback records are append-only inputs rather than auto-applied proposals. No dedicated Evaluations LiveView is required to meet the durable-record target. | Save deterministic suites and immutable runs with model/prompt/skill provenance; collect owner feedback and connect it to reviewable instruction-improvement proposals. | `mix test test/cympho/evaluations_test.exs` (18 tests green on 2026-08-06) plus Instruction Tuner foundation suites. Comparator `durable_eval_feedback` = parity. |
| G9 | P1 | Side-effect-free import preview foundation — **closed; selective packaging remains G13**. | `Companies.Portability.preview_import/2` produces a version-aware, read-only mutation plan with exact inventory, deterministic slug collision outcome, warnings, strict reference validation, and non-secret restore requirements. Import consumes that validation, strictly remaps associations, rejects foreign/unmapped IDs, and rolls back child failures. Secret metadata keys remain allowed while value/token/auth/credential payloads are rejected without echoing them. V1 documents/revisions remain intentionally ignored. | Pure version-aware preview with inventory, slug/collision outcome, warnings, omitted-secret restore plan, and zero writes; later extend to selective and merge imports. | `mix test test/cympho/companies_portability_test.exs test/cympho_web/live/company_portability_live_test.exs` (green on 2026-08-06). |
| G10 | P1 | Resumable and improve-existing onboarding — **closed for the defined flow**. | `users.onboarding_draft` stores only allowlisted non-secret fields; Improve drafts are pinned to `company_id` and carry a durable submission UUID, so switching companies cannot restore another company's intent. The improvement transaction locks the user row, rechecks owner/admin/board membership, reuses the existing goal/CEO issue on submission replay, or creates them with `origin_type: "onboarding_improvement"`, then clears the matching draft in the same transaction. Start and Improve preserve safe state through refresh/errors and never create a duplicate company. | Persist safe non-secret draft fields, resume after refresh, and offer Start a company vs Improve this company. Improvement creates a goal/issue, not a duplicate company. | `mix test test/cympho/onboarding_test.exs test/cympho_web/live/onboarding_live_test.exs` (green on 2026-08-06). |
| G11 | P1 | Mobile safe-area/dynamic-viewport evidence — **closed for the defined browser matrix**. | Root shell/content/nav/dialog/toast surfaces use `100dvh`/`100svh`, safe-area offsets, and bottom-nav-aware scroll padding. Focused shell/auth/nav coverage is green, and `docs/MOBILE_QA.md` records Ego Lite desktop, 390x844 portrait, 390x500 keyboard-shrink, and 844x390 landscape geometry. Emulated hardware safe-area values were zero, so notched physical devices remain a documented limit. | Use dynamic viewport units and safe-area offsets for shell, dialogs, forms, and bottom actions; keep a repeatable Ego Lite smoke checklist. | `mix test test/cympho_web/components/mobile_shell_test.exs` (and auth/navigation suites), `mix assets.deploy`, and `docs/MOBILE_QA.md`. |
| G12 | P1/P2 | External observability and adoption baseline — **closed for the defined tranche**. | Optional fail-open OTLP setup and allowlisted correlation spans are implemented; incoming W3C context is extracted and durable IDs correlate cross-process work. Quickstart, operations, observability, security, contribution, and roadmap docs plus installer/doc checks now exist. This is not a production trace-backend benchmark. | Optional fail-open OTLP traces that correlate HTTP -> dispatch -> run -> adapter/tool activity, plus bootstrap, security, contribution, roadmap, and operator docs. | `mix test test/cympho/open_telemetry_test.exs test/cympho/documentation_surface_test.exs` (green on 2026-08-06). |
| G13 | P2 | Selective standard package workflow — **closed for the blueprint collections**. | `Cympho.Companies.PackageMerge` applies a package to an *existing* company with real `:skip`/`:replace`/`:rename`/`:fail` writers, matching records by natural key (label name, project prefix, agent name, goal title), remapping references to whichever record wins, and linking parents inside the merged set. `preview/3` is a pure dry run. Merge covers `labels`, `projects`, `goals`, and `agents`; `users`, `memberships`, `issues`, and `secret_manifest` are reported as unsupported with reasons rather than merged by name. `Cympho.Companies.PackageSource` adds the documented directory format (manifest + one file per collection, standard filenames only, symlinks refused, paths confined to the package root, size caps) and `load_github/2`, which requires a 40-character commit SHA unless `allow_unpinned: true` and refuses redirects off the package host. Created and replaced agents land paused with heartbeat timers disabled. | After G9, add selective includes, dry-run merge, rename/skip/replace, local/GitHub/ref sources, and a documented portable directory format with secret/path scrubbing. | `mix test test/cympho/companies/package_merge_test.exs test/cympho/companies/package_source_test.exs test/cympho/companies_portability_test.exs`. Repository-source tests run against a real loopback HTTP server, so status handling, redirect refusal, and the Finch path are exercised rather than stubbed. |

## Delivery phases

### Phase 0 — benchmark truth

- [x] Replace the self-referential `0 gaps` comparator result with a two-sided baseline that includes the register above. Evidence: `mix test test/mix/tasks/cympho_compare_test.exs` and normal/`--strict` comparator behavior.
- [x] Record Paperclip revision `c62fa8d6a03377370c3a08ac49320cbba1c44227`, inspected 2026-07-30, and distinguish local runtime checks from source-review claims.
- [x] Update README comparison copy so Paperclip's MCP gateway, remote sandboxes, evaluation/feedback, onboarding, and selective portability advantages remain visible.
- [x] Keep claims narrow: the comparator and README explicitly describe a repository/source comparison, not a production-scale or reliability benchmark.

Exit criteria: `mix cympho.compare` can report advantages, parity, and open gaps without treating absence from an old README as proof of advantage.

### Phase 1 — execution and spend safety

- [x] G1: bind checkout ownership to the actual run before adapter execution. Evidence: `test/cympho/orchestrator/dispatcher_test.exs`, `test/cympho/orchestrator_test.exs`, and heartbeat ownership tests.
- [x] G1: make terminal cleanup clear only an exact run-ID match, preserving both successor-owned and newer unbound same-agent checkouts. Evidence: `test/cympho/heartbeat_engine_test.exs` plus the focused dispatcher/orchestrator suites.
- [x] G2: route terminal runtime usage through the run-linked `Finances.record_token_usage/1` ledger and normalize OpenAI-compatible usage. Evidence: runtime-spend and adapter usage tests.
- [x] G2: commit threshold-crossing usage and its incident before enforcing the stop. Evidence: `test/cympho/runtime_spend_enforcement_test.exs` and finance threshold suites.
- [x] G2: block future dispatch and cancel the correct company/agent/issue/project/goal scope with tenant validation. Agent enforcement stops live orchestrators and cancels runs only for the exact company/agent pair before pausing the agent. Evidence: `test/cympho/finances/budget_scope_hard_stop_test.exs`.

Exit criteria: one issue cannot execute concurrently without an explicit policy, and a budget crossing cannot disappear or allow new work to dispatch.

### Phase 2 — one calm owner workflow

- [x] G3: add a normalized owner-attention query and surface it in Inbox. Evidence: `test/cympho/owner_attention_test.exs` and `test/cympho_web/live/inbox_live_test.exs`.
- [x] G3: include ordinary/board approvals, pending questions/confirmations/task proposals, failed runs, and unresolved budget incidents, with severity ordering, payload-safe summaries, and issue-level deduplication. Evidence: owner-attention and Inbox LiveView focused tests.
- [x] G3: publish interaction create/resolve changes to mounted Inbox views and keep desktop/mobile badges on `OwnerAttention.unresolved_count/2` (same membership as `list_items/3` after issue-level dedup). Evidence: `test/cympho_web/live/inbox_live_test.exs` and `test/cympho_web/user_auth_test.exs`.
- [x] G3: reject cross-company review wakes at enqueue and scope agent-filtered review reads to the selected company. Evidence: `test/cympho/wakes_test.exs` and `test/cympho/owner_attention_test.exs`.
- [x] G3: keep primary decisions/actions in Simple mode and redacted diagnostics/provenance in Advanced mode. Evidence: Inbox LiveView tests.
- [x] G4: add per-issue Agent / Plan / Ask mode with prompt/action contracts and read-only Claude/Codex workspace behavior. Evidence: work-mode suites, `test/cympho/agent_runner_test.exs`, `test/cympho/adapters/codex_adapter_test.exs`.
- [x] G5: pin the canonical plan confirmation to an immutable document revision and reject stale acceptance. Evidence: `test/cympho/issue_thread_interactions_test.exs` and work-mode action tests.
- [x] G11: harden shell viewport and safe-area behavior. Evidence: mobile-shell plus auth/navigation suites and `mix assets.build`.
- [x] G11: record repeatable Ego Lite 390x844 portrait, keyboard-shrink, and landscape evidence in `docs/MOBILE_QA.md`; the smoke exposed and verified the bottom-nav scroll-padding fix.

Exit criteria: a nontechnical owner has one place to see and resolve every blocking decision without opening Operations or understanding run internals.

### Phase 3 — real remote execution and governed extensions

- [x] G6 foundation: land an `EnvironmentDriver` behaviour, Fake driver, registry, lifecycle, redaction, and company_id fail-closed checks. Evidence: `mix test test/cympho/workspaces/environment_driver_test.exs` (green on 2026-08-06). This does not close G6 without a real remote provider.
- [x] G6 foundation: connect workspace acquisition/lease/execute/release/cancel to Workspaces and Runtime (`ensure_provider_environment/1`), including issue pause/cancel/orphan release paths. Evidence: `mix test test/cympho/workspaces/environment_lifecycle_test.exs test/cympho/runtime_test.exs` (lifecycle green on 2026-08-06). This still uses only the Fake driver.
- [x] G6: add one real opt-in remote provider. Shipped `Drivers.Ssh` — any reachable host with sshd is a provider, using OTP's `:ssh` with no vendor account and no new dependency. Evidence: `test/cympho/workspaces/drivers/ssh_test.exs` (34 tests against a live daemon) and `test/cympho/workspaces/environment_config_test.exs`.
- [x] G7: remove synthetic marketplace metrics and replace local entries with source-backed, startable catalog records. Evidence: `test/cympho/plugins/catalog_test.exs` and marketplace LiveView tests.
- [x] G7 foundation: enforce the plugin company scope for host-service issue creation, including forged atom- and string-key `company_id` attributes. Evidence: `test/cympho/multi_tenancy_pr1_test.exs`.
- [x] G7: make plugin tool registration real and expose dynamic tools through MCP only after grant/policy checks. Evidence: `lib/cympho/mcp/tool_registry.ex`, `lib/cympho/plugins/host_services.ex`, `test/cympho/mcp/tool_registry_grants_test.exs` (17 tests, 0 failures on 2026-08-06).
- [x] G7: add approval, revocation, rate limiting, audit, and tenant isolation for dynamic MCP tools. Evidence: `ToolGrants.authorize_call/3` allow/deny/pending/revoked decisions, grant revoke, `GovernanceAuditLogs` on register/grant/call, `AgentActionLimiter` on MCP mutations (`test/cympho/mcp/tool_registry_grants_test.exs`, `test/cympho/mcp/server_mutation_throttle_test.exs`).

Exit criteria: a remote workspace performs real lifecycle operations against a non-Fake provider, and an installed extension can add a tool without bypassing company governance. Governance half is met; remote provider half remains open under G6.

### Phase 4 — measurable agent improvement

- [x] G8: add evaluation suite/run/result and feedback vote storage. Evidence: `priv/repo/migrations/20260806000011_create_evaluation_tables.exs`, `lib/cympho/evaluations.ex`, `test/cympho/evaluations_test.exs`.
- [x] G8: capture redacted provenance for prompt contract, model/runtime profile, skills, cost, and source run. Evidence: immutable `EvaluationRun.provenance` + redacted metadata tests in `test/cympho/evaluations_test.exs`.
- [x] G8: support deterministic reruns before model-scored rubrics. Evidence: `Evaluations.rerun_suite/2` and compare coverage in `test/cympho/evaluations_test.exs`.
- [x] G8 foundation: keep Instruction Tuner changes additive and reviewable with exact preview, explicit apply, durable rollback revision, restore, and post-change latest-run canary. Evidence: `test/cympho_web/live/operations_live_test.exs`, `test/cympho_web/live/agent_live_test.exs`, and agent config-revision tests.

Exit criteria: an owner can explain why an agent score changed (compare + provenance) and record accept/reject feedback without mutating historical runs; Instruction Tuner remains the explicit apply path for instruction changes.

### Phase 5 — portability, onboarding, observability, and adoption

- [x] G9: add the pure import preview foundation, strict association remapping, secret-payload rejection, and transactional rollback. Evidence: portability/domain plus LiveView suites.
- [x] G13 foundation: PortablePackage selective `:includes`, path/json sources with fail-closed path checks, and collision-mode shell. Evidence: `test/cympho/companies_portability_test.exs` PortablePackage facade tests. This does not close G13.
- [x] G13: implement skip/replace/rename writers, dry-run merge against an existing company, GitHub/ref-pinned sources, and a documented portable directory format with secret/path scrubbing. Evidence: `test/cympho/companies/package_merge_test.exs` and `test/cympho/companies/package_source_test.exs`.
- [x] G10: persist allowlisted non-secret drafts and add Start vs Improve this company with company-pinned drafts, durable submission IDs, a locked transactional membership recheck, idempotent replay, no duplicate company, and matching-draft cleanup in the same transaction. Evidence: `test/cympho/onboarding_test.exs` and `test/cympho_web/live/onboarding_live_test.exs`.
- [x] G12: add optional fail-open OTLP trace export and allowlisted trace correlation. Evidence: `test/cympho/open_telemetry_test.exs` and configuration integration tests.
- [x] G12: add bootstrap/operator/security/contribution/roadmap documentation and executable command checks. Evidence: `test/cympho/documentation_surface_test.exs`.

Exit criteria: a new user can start, resume, observe, move, and improve a company without hidden destructive steps or undocumented operator knowledge. Selective package workflow remains the open portability residual (G13).

## First implementation tranche

The first coding wave starts only after this file exists. It deliberately contains three independent slices so they can be implemented and reviewed in parallel.

### T1 — checkout/run ownership (G1)

- Add an atomic `Issues.bind_checkout_run(issue_id, agent_id, run_id)` operation.
- Bind immediately after the pending run is created and before adapter start.
- If another non-terminal run owns the checkout, cancel/reject the duplicate before dispatch.
- Preserve compare-and-clear behavior so terminal/stale run A cannot clear successor run B.
- Add focused concurrency and recovery tests.

Definition of done: every executing issue names its owning run, and duplicate execution loses deterministically before provider spend.

### T2 — import preview foundation (G9)

- Add a pure, side-effect-free `Companies.preview_import/2` or `Companies.Portability.preview_import/2`.
- Validate package version and required associations.
- Return exact inventory, target slug/collision plan, warnings, and secret restore requirements without secret values.
- Make the import LiveView render this server-produced plan.
- Keep existing V1 import behavior compatible.

Definition of done: an operator can know exactly what the package would create or why it would fail before a transaction begins.

### T3 — Owner Decisions MVP (G3)

- Reuse the Inbox route and existing review/human-action sources.
- Add company-scoped pending approvals and failed/timed-out runs.
- Normalize rows, deduplicate, order urgent failures first, and use one unresolved count for desktop/mobile badges.
- Support inline resolution where an existing safe action already exists; link to the authoritative detail view otherwise.
- Defer budget alerts until G2 supplies one authoritative incident stream.

Definition of done: Simple mode shows one owner-facing queue for assigned human work, approvals, reviews, and failed execution.

## Verification gate for every tranche

1. Run the smallest focused tests while iterating.
2. Run `mix format --check-formatted`.
3. Run `mix test`.
4. Run `mix assets.deploy` for UI or asset changes.
5. For UI changes, use Ego Lite only and verify desktop plus 390x844 mobile.
6. Run a credential signature scan over changed/tracked files and relevant logs.
7. Update this plan with completed boxes, exact tests, and remaining risks.

## Explicit non-goals for the first wave

- No attempt to manufacture community size, download counts, ratings, or adoption claims.
- No multi-provider sandbox matrix before one driver contract is proven.
- No LLM-scored eval framework before deterministic saved runs and provenance exist.
- No SSO/SAML implementation without a separate identity threat model and deployment requirement.
- No framework migration or visual rewrite.
- No production deployment in the same change unless the completed tranche passes the full verification gate.

## Open residuals (2026-08-14)

No register gap remains open. `mix cympho.compare` reports zero gaps.

Known scope limits that are deliberate, not hidden:

- **G6** — `:ssh` is the only registered real provider. Vendor SaaS sandboxes (E2B, Daytona, Modal, Kubernetes) stay unregistered and fail closed; adding one is a new tranche, not a residual.
- **G13** — merge covers the blueprint collections (`labels`, `projects`, `goals`, `agents`). `users`, `memberships`, `issues`, and `secret_manifest` are reported as unsupported for merge and remain whole-company-import only.

Re-verify with:

```bash
mix cympho.compare --strict
mix test test/cympho/workspaces/drivers/ssh_test.exs \
  test/cympho/workspaces/environment_config_test.exs \
  test/cympho/workspaces/environment_driver_test.exs \
  test/cympho/workspaces/environment_lifecycle_test.exs \
  test/cympho/companies/package_merge_test.exs \
  test/cympho/companies/package_source_test.exs \
  test/cympho/mcp/tool_registry_grants_test.exs \
  test/cympho/evaluations_test.exs \
  test/cympho/companies_portability_test.exs \
  test/cympho/owner_attention_test.exs \
  test/cympho_web/live/inbox_live_test.exs \
  test/mix/tasks/cympho_compare_test.exs
```
