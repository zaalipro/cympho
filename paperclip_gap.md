# Closing the Paperclip gap

Status: active; historical G1-G13 delivered, latest-upstream gaps remain open
Created: 2026-07-30
Latest upstream refresh: 2026-08-26
Historical Cympho baseline: `44ed6c3`
Historical Paperclip baseline: `c62fa8d6a03377370c3a08ac49320cbba1c44227`, public `master` inspected on 2026-07-30
Current Paperclip master audit: `821573ede850441d5043ecd4860ee70a2a0374b1` (commit date 2026-08-25)
Current Paperclip stable audit: `v2026.824.1`, `8e6edcdfa911151adba26be49a41cf5017b3aade`

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
- Treat `mix cympho.compare` as a selected local regression audit. A zero count there is not proof of latest Paperclip parity or low-resource performance.

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

## Latest-upstream gap register (2026.824)

Upstream paths below are relative to the canonical
[`paperclipai/paperclip`](https://github.com/paperclipai/paperclip) checkout at
`~/dev/research/paperclip`. Stable behavior is summarized by
`releases/v2026.824.0.md` and the `v2026.824.1` release note; feature-flagged
master surfaces are evidence of implementation, not claims that every install
enables them by default.

| ID | Priority | Status | Gap and authoritative evidence | Exit evidence |
| --- | --- | --- | --- | --- |
| L1 | P0 | **In progress** | **Benchmark truth.** `mix cympho.benchmark_idle_agents` now provides a rollback-safe idle-fleet workload, and `benchmarks/results/` retains matched delegated/direct development artifacts. No reproducible side-by-side low-VPS Paperclip workload exists yet; local structure checks do not prove RAM, CPU, latency, or production reliability. | A pinned workload reports app + Postgres + child-process RSS/CPU, DB query rate, throughput, p95 latency, and correctness for idle 100/500/1,000-agent fleets and bounded active-run levels on a documented low-resource VPS. |
| L2 | P0 | **Delivered for dispatcher-delegated agents** | **Event-driven idle heartbeats.** Delegated heartbeat processes start without timers, ignore stale timer messages, and touch/poll only on durable/explicit events (`lib/cympho/agent_heartbeat.ex`; `test/cympho/agent_heartbeat_test.exs`). The retained 100-agent development workload observed 0 idle queries/timers versus 800 queries and 100 timers in legacy direct mode over the same 5.1-second window. | Keep wake/recovery coverage green and reproduce the zero-idle-query result at 100/500/1,000 agents in L1. Legacy direct-dispatch mode intentionally retains timers. |
| L3 | P0 | **In progress; node-local gate delivered** | **Capacity admission.** Checkout serializes per-agent capacity in PostgreSQL. Named profiles now separately bound total sessions, local OS-process runs, Repo, and Finch pools. `Cympho.RuntimeAdmission` classifies the concrete resolved adapter, fails unknown adapters into the local lane, atomically grants monitored total/local slots, and in production rejects new local starts when effective host/cgroup headroom is at or below the configured floor or cannot be measured. Every built-in worker registers and adopts its claim before provider work. Worker-bound admission and bounded PID-tree cleanup cover normal completion, cooperative cancellation, controller death while the worker remains schedulable, and manager recovery. They do not yet provide an independent Port custodian or per-run cgroup/container: brutal adapter-worker death can release a node-local claim before OS descendants are confirmed gone, and descendants surviving the direct Port child remain a portability residual. Gateway adapters consume a total slot but not the local sub-limit. Dispatcher advisory checks avoid doomed checkouts, while the Orchestrator gate covers manual, heartbeat, retry, and fallback paths. Company Operations exposes only a tenant-neutral delay signal; doctor and bounded telemetry retain node-level posture for instance operators. Limits remain per node, not cluster-wide, and the low-VPS evidence still belongs to L1. | Reproduce enforcement and gateway progress under L1's matched low-VPS workload. Move Port ownership and the claim into a supervised per-session custodian, then add cgroup-v2 containment on supported Linux deployments. Do not claim crash-proof containment, per-process ceilings, or cluster-wide admission. |
| L4 | P0 | **Delivered for the navigation/entry-point slice** | **Reliability and Tasks information architecture.** One Simple-visible Tasks item now owns List (`/issues`) and Board (`/kanban`), both views share an accessible switch, and mobile uses the same Tasks destination. Focused tests and Ego Lite desktop/390×844 smoke are recorded in `docs/MOBILE_QA.md`; the task space was closed without wiping sessions. Conversation/document completeness remains honestly open as L8. | Preserve one Tasks entry point and its browser/accessibility coverage while L8 brings live conversation and anchored review into the same owner workflow. |
| L5 | P1 | **In progress** | **Install, service, and repair UX.** `Cympho.Diagnostics` and `mix cympho.doctor` now provide a stable human/JSON, non-destructive source-checkout diagnostic contract for toolchain, configuration, read-only DB/migration state, endpoint configuration, local-storage path/writability posture, BEAM/resource caps, and aggregate adapter health without starting agents or providers. The only transient write is an exclusive zero-byte local-storage probe that is immediately removed; the doctor rejects known temporary/release paths without claiming it can prove mount durability. Release deploys reconcile the required preview host and persistent upload directory. Paperclip stable still has the broader onboard/install/update/service/status/logs/backup flows (`cli/src/commands/`; `git show v2026.824.1:releases/v2026.824.1.md`). | Add a versioned managed Cympho CLI for install/onboard/status/logs/update/backup and a real service readiness/version contract; preserve the delivered doctor and secret-leak regression coverage. |
| L6 | P1 | **In progress** | **Large, resumable portability.** Cympho now persists actor/company-bound transfer and part ledgers, verifies 64 KiB raw reads through fsynced atomic part installs, resumes missing parts, binds immutable import policy, limits actor/global reservations and concurrent apply, and uses leased claim tokens plus one transaction for the imported graph and completed receipt (`Cympho.Companies.ImportTransfers`; transfer controller/domain/browser tests). Browser and raw transport memory are bounded, but V1 still materializes one decoded map within the 50 MB cap. Export is not resumable, and documents/history, routines, and skills still do not round-trip. Paperclip persists verified progress (`packages/db/src/schema/company_transfer_runs.ts`) and stable 2026.824 streams roughly 32 MB parts. | Add a staged record-stream V2 for constant-memory validation/apply, resumable export, full object fidelity, and explicit cross-version compatibility; keep actor/tenant, integrity, admission, and exactly-once tests green. |
| L7 | P1 | Open | **Managed execution and provider login.** Paperclip ships multiple sandbox-provider plugins (`packages/plugins/sandbox-providers/`), a verified capability contract, in-product Claude/Codex login sessions, and Tailscale HTTPS runtime exposure. Cympho intentionally registers only Fake and SSH (`lib/cympho/workspaces/environment_drivers.ex`). | Preserve SSH, then prove one vendor provider against the same fail-closed capability/lifecycle contract; add owner-bound, one-time provider login and a durable secure remote-preview lifecycle. |
| L8 | P1 | Open | **Conversation and document review completeness.** Cympho has Simple thread, Plan/Ask interactions, revisioned documents, review gates, and artifacts. Paperclip additionally persists document annotation threads/comments/anchors and injects them into review context (`packages/db/src/schema/document_annotation_*`; `releases/v2026.824.0.md`). | Live task conversation and anchored document/artifact feedback share one auditable thread, survive revision changes, reach the acting agent, and keep raw diagnostics out of Simple mode. |
| L9 | P1 | Open | **Apps, skills, and secret lifecycle.** Paperclip implements governed application connections/gateways (`packages/db/src/schema/tool_access.ts`), Skill Studio/release policy (`ui/src/pages/SkillStudio.tsx`), provider vaults, proposals, access events, and user-secret declarations (`packages/db/src/schema/*secret*`). Cympho has useful MCP grants, skill CRUD, and scoped encrypted secrets, but not those complete operator lifecycles. | Deliver the smallest coherent connection/profile approval flow, skill create-test-pin-fork flow, and audited secret proposal/version/access flow without weakening tenant boundaries. |
| L10 | P2 | Open | **Breadth and mobile installability.** Paperclip packages Gemini, Grok, Hermes, Kimi, OpenCode, Pi and additional adapters (`packages/adapters/`) and ships a web manifest/service worker (`ui/public/site.webmanifest`, `ui/public/sw.js`). Cympho lacks those first-class adapters and is responsive but not a PWA. | Prioritize adapters by verified demand and contract tests; ship installable/offline-safe shell behavior only with update/recovery tests. |

Additional reliability evidence in this tranche: newly created routine webhooks
default to strict raw-body HMAC-SHA256 with a bounded timestamp window,
encrypted company-scoped key storage, and a durable per-trigger replay fence.
Migrated legacy bearer hooks remain explicitly replayable until operators
migrate them, so this does not close the broader L9 secret/application
lifecycle.

### Current first tranche

- [ ] **L1 benchmark truth — in progress.** Do not publish a “10x,” low-RAM, or
  high-agent-count claim until the workload and results are reproducible.
- [x] **L2 event-driven heartbeats — delivered for the default delegated path.**
  Focused tests are green and retained local artifacts show zero idle queries
  and timers for the matched 100-agent window. Cross-product/VPS proof remains
  L1, and legacy direct mode remains available for compatibility.
- [ ] **L3 capacity admission — enforcement delivered, evidence in progress.**
  The node-local gate is authoritative for registered live-worker paths and
  typed; independent Port custody/OS containment and L1's matched low-VPS
  resource evidence remain open before this gap is closed.
- [x] **L4 reliability and Tasks IA — delivered for the entry-point slice.**
  Desktop/mobile tests and Ego Lite smoke are green, and the Ego Lite task
  space was closed without wiping sessions. Deeper task conversation and
  document review remain L8 rather than being hidden under this closure.

## Historical 2026-07-30 gap register

G1-G13 below record work delivered against the older pinned baseline. Their
focused evidence remains useful, but their closure does **not** establish parity
with Paperclip 2026.824 or current master.

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

## Runtime hardening tranche (2026-08-14)

Closing G6 and G13 finished the *feature* register. It did not make Cympho the
better product on its own — parity on a feature list is worth little if the
runtime underneath drops work. This tranche came out of an adversarial audit of
the BEAM/OTP layer: 66 candidate findings, 36 refuted on inspection, 30
confirmed against code. Each fix below has a regression test that was verified
to fail when the fix is reverted.

Correctness and spend:

- **Adapter workers were not tied to their orchestrator.** A brutal kill skips
  `terminate/2`, and every recovery path from there is a database write — so a
  live CLI kept writing into the workspace the next dispatch reuses. Workers now
  monitor their owner and close their port when it dies.
- **`AgentRunner` abandoned a live `claude` process** on the mid-run parse-error
  branch, the only terminal branch that skipped `close_port/1`. Shell preamble on
  the first chunk triggers it milliseconds after spawn.
- **Codex, Cursor and Process adapters had no wall-clock cap.** Their timeout
  reset on every chunk, so a chatty CLI never died: it pinned a dispatch slot and
  billed indefinitely.
- **`PortKiller` was a silent no-op** wherever PATH lacked `kill`/`pgrep`, and
  snapshotted the process tree *after* closing the port, contradicting its own
  documented invariant.
- **The Agrenting adapter's paid remote hiring was uncancellable** — unregistered
  and sleeping between polls — and stopping locally left the remote side billing.
- **Approved governance actions could be dropped silently.** `executed_at` was
  both the claim and the success marker, so a claimed-then-failed approval was
  invisible to recovery forever.
- **The delivery receipt gate was a coin flip.** Second-precision timestamps tied
  within one action batch, so which comment counted as the handoff depended on
  row order.

Availability:

- **The dispatcher's poll timer multiplied.** `poll_now/0` delivers the same
  message the periodic timer uses and runs on issue launch, dashboard actions and
  heartbeats, so the poll rate grew for a node's whole life.
- **A budget hard stop froze the global dispatcher** for ~15s against the very
  orchestrator that triggered it, and skipped the enforcement steps after it.
- **`Orchestrator.stop/2` waited `:infinity`**, so one orchestrator wedged in
  `terminate/2` blocked all dispatch permanently.
- **Blocking `git clone` and remote environment acquisition ran inside the
  dispatcher process**, because `dispatchable?/3` set a `:phase` flag nothing
  read and ran the full preflight the orchestrator runs again anyway.
- **A permanent atom was minted per routine trigger.** Atoms are never collected
  and the VM aborts at the limit.
- **MCP plugin tools had a 5s call whose timeout is an exit**, uncatchable by the
  surrounding `rescue`, so the request 500'd instead of returning a structured
  error.
- **RuntimePreflight forked a login shell per board card**, serially, inside the
  LiveView process.

Scale and multi-tenancy:

- **Dispatch was hardcoded to 3 concurrent agents platform-wide**, compile-time
  only, with no runtime knob and no relation to machine resources.
- **The per-company cap defaulted to the global cap**, which made it dead code.
- **One tenant's backlog starved every other tenant**: candidates came from a
  single globally priority-ordered window, so other companies' issues were never
  loaded and the freed slots went unused.
- **Paused issues at the head of that window froze dispatch entirely** — and a
  budget hard stop sets that flag automatically.

Observability, which is where the BEAM should be an advantage rather than a
missed one:

- `Cympho.Telemetry` emitted domain events that nothing consumed;
  `telemetry_metrics` and `telemetry_poller` were declared dependencies with no
  metrics module and no poller.
- Phoenix LiveDashboard was a dependency whose RequestLogger plug was installed
  but whose route was never mounted. It is now at `/beam`, gated as an
  instance-operator surface rather than a tenant one.
- Logger dropped every structured metadata key the codebase attaches — the
  convention in CLAUDE.md was documented, followed at hundreds of call sites, and
  never rendered.
- Mailbox depth on the singleton processes every dispatch and broadcast passes
  through, and saturation of the two `DynamicSupervisor`s with hard ceilings, are
  now measured.
- Adapters buffered all output, so an owner saw nothing between "running" and a
  finished comment. Runs now publish progress — including to the
  `orchestrator:<issue_id>` topic the moduledoc had always advertised and nothing
  had ever published to.
- Tool-call traces, a hash-chained governance surface, had no production
  producer at all. MCP calls now feed it.

## Historical residuals recorded on 2026-08-14

The older G1-G13 register was considered closed at that time. The current L1-L10
register above supersedes any inference that the historical closure meant
current Paperclip parity. `mix cympho.compare --strict` now includes bounded
latest-audit checks and must remain non-zero while those checks are open.

Known scope limits that are deliberate, not hidden:

- **G6** — `:ssh` is the only registered real provider. Vendor SaaS sandboxes (E2B, Daytona, Modal, Kubernetes) stay unregistered and fail closed; adding one is a new tranche, not a residual.
- **G13** — merge covers the blueprint collections (`labels`, `projects`, `goals`, `agents`). `users`, `memberships`, `issues`, and `secret_manifest` are reported as unsupported for merge and remain whole-company-import only.

Open items from the runtime audit, deliberately not attempted here:

1. **Single-node only.** `:dns_cluster` is a declared dependency that is never
   started, and every registry, rate limiter, ETS cache, and singleton GenServer
   is node-local. Orphan recovery is node-blind — `heartbeat_runs` has no owner
   node — so a second node would terminate healthy peer-node runs, and Quantum
   cron would fire once per node. Clustering is a design tranche of its own, not
   a fix; nothing here pretends otherwise.
2. **CLI-internal tool use is still not captured.** MCP calls are traced, but
   recording what the agent CLI does inside a run needs `--output-format
   stream-json` and a parser for envelopes that cannot be verified without the
   real binary.
3. **Company stop changed after this residual was written.** Current code moves
   cleanup out of the dispatcher GenServer and uses bounded parallel tasks with
   a deadline (`lib/cympho/orchestrator/dispatcher.ex:672-731`). Retain focused
   stop/recovery tests; do not cite the old serial-teardown note as current.

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
