---
spec_id: 01
feature_name: remaining_autonomy_polish
status: approved
created: 2026-05-19
last_updated: 2026-05-19
source_prompt: |
  Generate a spec covering the remaining roadmap items called out in
  REVIEWS/fire-and-forget-gaps.md after PR 1, 2, 2.5, 2.75, 3, the budget
  block, per-company concurrency caps, and the Decisions.Executor have
  shipped. Specifically: (a) replace the brittle keyword-driven router
  with an LLM-classified `assigned_role` set at issue creation,
  (b) promote the dormant ExecutionPolicies CRUD into a real autonomous
  stage advancer, and (c) add scripted mock-adapter integration tests
  that prove the full mission loop closes end to end without burning
  real LLM tokens. The agent must also keep a sensible fallback so a
  missing LLM key or dialed-down config does not regress today's
  keyword router.
assumptions:
  - The LLM classification call is best layered on top of the existing keyword router rather than replacing it; the keyword path remains as a deterministic fallback when the classifier returns nothing or errors. Reason: avoid regressing offline / API-key-less environments and keep tests fast.
  - The classifier uses the same Anthropic API key Cympho already pulls via `Cympho.AgentRunner.api_key/0` (env `ANTHROPIC_API_KEY` or app env `:cympho, :anthropic_api_key`). Reason: no new infrastructure or secret plumbing for the first cut.
  - ExecutionPolicies stage advancement is opt-in per stage via a new `auto_advance: true` field on `stage_configs`; the existing human-driven `Issues.execution_policy_decision/3` path keeps working unchanged. Reason: minimise blast radius and let teams roll the autonomous path out per policy.
  - Mock-adapter integration tests script `cympho-actions` JSON via a single in-process `Cympho.Adapters.MockAdapter` registered for tests instead of building a full `Cympho.AgentRunner` mock. Reason: the action contract is the public seam the rest of the autonomy loop sits on; mocking it gives the highest coverage for the lowest plumbing.
  - The classified role is persisted in the issue's existing `assigned_role` column rather than a new `inferred_role` column. Reason: avoid a schema migration; the field is already populated by handoff / submit_review / agent-driven create_issue flows and respected by the dispatcher.
---

# 01 — Remaining Autonomy Polish (LLM Router, Execution Policy Auto-Advance, Mock-Adapter Integration Tests)

## Requirements Document

### Introduction

This spec closes the remaining items in the fire-and-forget autonomy roadmap once PRs 1 through 3 plus budget, concurrency-cap, and decision-executor work have shipped. The audience is the Cympho engineering team. The main goals are: ship a smarter LLM-backed issue router so a misnamed ticket does not silently land on the wrong role, turn the dormant `ExecutionPolicies` CRUD into a real autonomous stage advancer, and add scripted mock-adapter integration tests that prove the autonomy loop closes end to end without burning real LLM tokens. The business value is fewer mis-routed issues, autonomous progression of multi-stage workflows, and high-confidence regression coverage so the loop stays healthy as the codebase keeps moving.

### Functional Requirements

#### REQ-001 — LLM-classified issue role at creation

**User Story**

> As a Cympho operator, the agent wants every owner-filed issue to be classified by an LLM into the right role at creation time, so that work routes correctly even when the title and description do not match the existing keyword lists.

**Acceptance Criteria**

1. **AC-001** — WHEN a top-level issue is created via `Cympho.Issues.create_issue/1` AND the resulting issue has no `assigned_role` set THEN the system SHALL invoke `Cympho.Routing.LlmClassifier.classify/2` with the issue title and description.
2. **AC-002** — WHEN the classifier returns a recognised role atom THEN the system SHALL persist it as the issue's `assigned_role` (string form) before the existing `maybe_auto_ignite/2` hook runs.
3. **AC-003** — IF the classifier returns `:error`, `nil`, or an unrecognised value THEN the system SHALL fall back to `Cympho.Orchestrator.Dispatcher.Router.infer_role/1` (current keyword behaviour) without raising.
4. **AC-004** — WHERE the application configuration `:cympho, :llm_router_enabled?` is `false` THE SYSTEM SHALL skip the classifier and use the keyword router only.
5. **AC-005** — WHEN classification finishes THEN the system SHALL emit a `[:cympho, :routing, :classified]` telemetry event with `%{duration_ms: integer, source: :llm | :keyword | :fallback}` measurements and `%{issue_id: binary, classified_role: atom | nil}` metadata.
6. **AC-006** — WHEN classification is requested while the classifier is disabled or no API key is configured THEN the system SHALL emit `source: :fallback` telemetry and return the keyword router result without making a network call.
7. **AC-007** — IF the same issue is re-saved via `update_issue/2` AND its title or description changes AND the existing `assigned_role` was set by the LLM classifier (recorded in `monitor_state["routing"]["source"] == "llm"`) THEN the system SHALL re-run classification; otherwise it SHALL leave `assigned_role` untouched.

#### REQ-002 — Autonomous execution-policy stage advancement

**User Story**

> As a CTO running an autonomous company, the agent wants execution policies to advance their own stages whenever a stage is configured `auto_advance: true`, so that policy-driven workflows progress without a human pressing a button.

**Acceptance Criteria**

1. **AC-008** — WHEN an `ExecutionStageResult` row transitions to `status == "completed"` AND the next stage's `stage_configs` entry contains `auto_advance: true` THEN the system SHALL start the next stage and broadcast a `:stage_advanced` event on `company:{id}:execution_policies`.
2. **AC-009** — IF the next stage's `auto_advance` is `false` or absent THEN the system SHALL leave the stage in `pending` status and require an explicit `Cympho.Issues.execution_policy_decision/3` call to advance it.
3. **AC-010** — WHEN the final stage completes (no next stage exists) THEN the system SHALL transition the linked issue's `execution_state` to `completed` and emit a `[:cympho, :execution_policy, :completed]` telemetry event.
4. **AC-011** — WHEN auto-advance fires for a stage whose `auto_approve_below_cost` config is set AND the linked issue's accumulated runtime cost is below the configured threshold THEN the system SHALL approve the stage outcome automatically and skip the human approval gate.
5. **AC-012** — IF the auto-advance recipe encounters a missing or malformed `stage_configs` entry THEN the system SHALL log a warning at `:warning` level and leave the stage `pending` (no exception leaks to the caller).
6. **AC-013** — WHEN the application configuration `:cympho, :start_execution_policy_advancer?` is `false` THE SYSTEM SHALL not start the advancer GenServer (used by the test environment).

#### REQ-003 — Scripted mock-adapter end-to-end integration tests

**User Story**

> As a Cympho contributor, the agent wants integration tests that drive the full mission loop with a scripted mock adapter, so that regressions in the autonomy spine are caught without burning real LLM tokens.

**Acceptance Criteria**

1. **AC-014** — WHEN a test enables `Cympho.Adapters.MockAdapter` for a given agent_id and issue_id THEN every subsequent `Cympho.Orchestrator.start_and_run/2` for that pair SHALL pull a scripted `cympho-actions` payload from the mock without making any external HTTP call.
2. **AC-015** — WHILE the mock adapter is active for an agent THE SYSTEM SHALL deliver `:session_started`, `:turn_completed`, and `:session_ended` messages to the orchestrator in the same order a real adapter does.
3. **AC-016** — WHEN the integration test "make Cympho better than Linear" runs THEN the test SHALL pass with: a mission goal seeded, two initiatives materialised, two engineers spawned, both PRs merged, and the mission goal marked complete, all without external network calls.
4. **AC-017** — WHEN the integration test "stuck engineer" runs THEN the test SHALL pass with: an engineer's adapter set to `script: :silent` for >2 simulated hours, the patrol detecting the stall, the CTO emitting `intervene reassign`, and a different engineer completing the work.
5. **AC-018** — IF a mock adapter is asked for a payload it has no script entry for THEN the test SHALL fail with `:no_script_entry` and the test ExUnit message SHALL identify the missing key (agent_id + issue_id + invocation index).
6. **AC-019** — WHERE the test environment runs the integration suite THE SYSTEM SHALL gate the mock adapter behind `Cympho.Adapters.Registry.register/2` so production builds cannot accidentally route to it.

### Non-Functional Requirements

#### NFR-001 — Performance

1. **AC-020** — WHEN the LLM classifier runs in the issue-creation hot path THEN it SHALL not block the calling process: the call SHALL execute under `Cympho.TaskSupervisor` and persist the result via a follow-up `update_issue` so the original `create_issue/1` returns within 100 ms at the 95th percentile.
2. **AC-021** — WHEN execution-policy stage advancement runs THEN the per-tick work SHALL complete in under 50 ms at the 95th percentile per company.

#### NFR-002 — Security

1. **AC-022** — WHEN the LLM classifier composes its prompt THEN it SHALL include only the issue's title, description, project name (if any), and company name; no comments, secrets, or other agent context SHALL be sent.
2. **AC-023** — IF the configured `ANTHROPIC_API_KEY` is missing THEN the classifier SHALL not fall back to a hard-coded key and SHALL not raise; it SHALL emit `source: :fallback` and return the keyword result.

#### NFR-003 — Accessibility

None — all changes are server-side; no UI surface introduced.

#### NFR-004 — Observability

1. **AC-024** — WHEN the LLM classifier completes THEN the system SHALL emit `[:cympho, :routing, :classified]` telemetry as defined in AC-005.
2. **AC-025** — WHEN execution-policy stage advancement completes THEN the system SHALL emit `[:cympho, :execution_policy, :advanced]` telemetry with `%{stage_name: string, outcome: string}` metadata.
3. **AC-026** — WHEN any of the new mock-adapter integration tests fail THEN the failure message SHALL include the agent_id, issue_id, and the missing or unexpected action `type` so the offending script entry is unambiguous.

#### NFR-005 — Reliability

1. **AC-027** — IF the LLM classifier raises during a `Task.async_stream` call THEN the supervised task SHALL catch the exception, log a warning, emit telemetry with `source: :fallback`, and the issue SHALL retain its original (keyword-derived) `assigned_role`.
2. **AC-028** — IF the execution-policy advancer GenServer crashes THEN the supervisor SHALL restart it with `restart: :permanent` and SHALL not lose any pending stage transitions (the next sweep re-derives state from `ExecutionStageResult` rows).

#### NFR-006 — Compatibility

1. **AC-029** — WHEN this feature ships THEN existing callers of `Cympho.Orchestrator.Dispatcher.Router.infer_role/1` SHALL behave identically when `:llm_router_enabled?` is false.
2. **AC-030** — WHEN this feature ships THEN existing callers of `Cympho.Issues.execution_policy_decision/3` SHALL behave identically; no new required argument SHALL be introduced.

### Out of Scope

- Replacing the keyword router entirely; the keyword path remains as a fallback.
- Building a separate LLM cost ledger; this feature uses the existing `Cympho.Budgets.record_spend/4` path with the `:llm_router` scope.
- Adding a UI to inspect classification results; observability is via telemetry and the existing issue audit trail.
- Migrating `ExecutionPolicies` to a workflow-engine library; the autonomous advancer reuses the existing `stage_configs` JSON format.
- LLM-classified roles for *child* issues created by `cympho-actions` `create_issue`; those already carry an explicit `role` from the emitting agent and are out of scope for this spec.

### User Journeys

1. **Happy path — LLM-classified routing:**
   1. Owner creates "Migrate auth schema to Postgres" with no explicit role.
   2. `Cympho.Issues.create_issue/1` returns `{:ok, issue}` immediately.
   3. Background task calls the LLM classifier; classifier returns `:cto`.
   4. Issue's `assigned_role` is updated to `"cto"` and `maybe_auto_ignite/2` re-fires.
   5. Dispatcher routes to the company CTO instead of falling through to `:engineer`.
2. **Alternate path — fallback when no API key:**
   1. Owner creates "Fix flaky CI build".
   2. `:cympho, :llm_router_enabled?` is `false` (or no API key configured).
   3. Background task records `source: :fallback` telemetry without making a network call.
   4. Keyword router runs synchronously inside `maybe_auto_ignite/2`; the issue lands with the same role it would have today.
3. **Happy path — autonomous execution-policy advance:**
   1. CTO assigns a 4-stage execution policy to an issue, all four stages flagged `auto_advance: true`.
   2. Engineer completes stage 1 via `Cympho.Issues.execution_policy_decision(issue, :approve, decided_by)`.
   3. Advancer GenServer notices stage 1 `completed`, starts stage 2 immediately.
   4. Stages 2–3 advance the same way without any human button press; stage 4 completes; the issue's `execution_state` flips to `completed`.

---

## Plan Document

### Introduction

The plan introduces three independent but related modules: `Cympho.Routing.LlmClassifier` (a thin wrapper around the existing Anthropic adapter machinery with an aggressive timeout and a deterministic fallback), `Cympho.ExecutionPolicies.Advancer` (a `GenServer` modelled after `Cympho.Orchestrator.BacklogPlanner` that subscribes to execution-stage events), and `Cympho.Adapters.MockAdapter` (an in-process adapter registered via the existing `Cympho.Adapters.Registry` for tests only). The technical constraint is that all three must respect the existing supervision-tree gating pattern (`:start_*?` env flags) and must not regress today's deterministic behaviour when their flags are off. The expected outcome is that the autonomy loop becomes both smarter at routing and self-driving across multi-stage policies, while regression coverage rises dramatically. Integration points include `Cympho.Issues.create_issue/1`, the dispatcher router, the execution policy decision pipeline, and the agent runner protocol. Performance and scalability targets are specified in §5.3 NFRs. No new external libraries are introduced beyond what `Cympho.Github` and `Cympho.AgentRunner` already use (`Finch`, `Jason`, `Task.Supervisor`).

### Understanding

The user wants the spec for the leftover roadmap items: smarter routing, autonomous execution-policy advancement, and high-confidence integration tests. Key objectives: (a) every change must be opt-in via configuration so the existing deterministic behaviour stays available; (b) every new module must follow the supervision-tree gating pattern already used by `BacklogPlanner`, `Oversight.Patrol`, and `Decisions.Executor`; (c) integration tests must drive the autonomy loop without external network calls. No clarifying questions remain — the assumptions in the metadata header capture the open decisions.

### Solution Design

**High-level approach.** Layer the LLM classifier on top of `Cympho.Issues.create_issue/1` via `maybe_auto_ignite/2`, run it inside `Cympho.TaskSupervisor` so the caller is not blocked, and persist the result in the issue's existing `assigned_role` column. Add a `Cympho.ExecutionPolicies.Advancer` GenServer that subscribes to a new `system:execution_policies` PubSub topic and applies stage transitions whose `auto_advance` flag is set. Introduce `Cympho.Adapters.MockAdapter` registered into `Cympho.Adapters.Registry` for tests; scripts are stored in an ETS table keyed by `{agent_id, issue_id, invocation_index}` and consumed in FIFO order.

**Data flow & architecture.**
- Classifier: `Issues.create_issue/1` → `maybe_classify_role/1` → `Task.Supervisor.start_child(Cympho.TaskSupervisor, fn -> classify_and_persist(issue) end)` → `Cympho.Routing.LlmClassifier.classify/2` → `Issues.update_issue/2` (`assigned_role`, `monitor_state["routing"]`).
- Advancer: existing `Issues.execution_policy_decision/3` → broadcast on `company:{id}:execution_policies` AND `system:execution_policies` → `Cympho.ExecutionPolicies.Advancer.handle_info({:stage_completed, stage_result}, state)` → `do_advance/1` → `Issues.execution_policy_decision/3` for the next stage if `auto_advance: true`.
- Mock adapter: `Cympho.Adapters.Registry.register/2` registers `Cympho.Adapters.MockAdapter` under name `:mock`; tests call `Cympho.Adapters.MockAdapter.script(agent_id, issue_id, list_of_payloads)`; orchestrator calls `module.run/4` which pops the next script entry from ETS and pushes synthetic `:turn_completed` messages.

**Step-by-step execution plan.**
1. Add the `:llm_router_enabled?`, `:llm_classifier_timeout_ms`, `:start_execution_policy_advancer?` application env keys with conservative defaults (`true`, `1500`, `true`).
2. Build `Cympho.Routing.LlmClassifier.classify/2` using `Finch` directly (no adapter abstraction) with a single Anthropic Messages API call, JSON response shape `{"role": "..."}`.
3. Hook the classifier into `Cympho.Issues.create_issue/1` via `maybe_classify_role/1`.
4. Persist classifier source (`"llm"` or `"keyword"`) in `monitor_state["routing"]["source"]` so re-classification on edit can be triggered.
5. Build `Cympho.ExecutionPolicies.Advancer` GenServer; subscribe at boot; emit telemetry on advance.
6. Add a global broadcast in `Issues.execution_policy_decision/3` so the advancer can subscribe without per-company subscriptions.
7. Build `Cympho.Adapters.MockAdapter` with an ETS-backed script store and the `Cympho.AgentAdapters` behaviour shape.
8. Register the mock adapter in `Cympho.Adapters.Registry.register_builtin/0` only when `Mix.env() == :test` or via test helper.
9. Write the two scripted integration tests (`mission_better_than_linear_test.exs`, `stuck_engineer_recovery_test.exs`).
10. Update `REVIEWS/fire-and-forget-gaps.md` to mark the three items shipped.

**Edge cases & failure handling.**
- Classifier timeout: caught in the supervised task, telemetry emitted with `source: :fallback`, issue keeps its keyword-derived role.
- Classifier returns junk JSON: caught with `Jason.decode/1` failure, same fallback as timeout.
- Advancer race: if two stage_completed events arrive for the same `execution_policy_id + resource_id` simultaneously, the advancer uses `Repo.transaction` with a `FOR UPDATE` lock on the `execution_stage_results` row to serialise.
- Mock-adapter script exhausted: returns `{:error, :no_script_entry}` and the test fails immediately.

**Scalability & performance considerations.** Classifier cost is bounded by Anthropic API latency (typically <2 s); we wrap the call in a 1.5 s `Task.await` with on-timeout fallback so a stalled API never holds an issue. Advancer's per-tick work is `O(stages_completed)` and runs off PubSub, not a polling loop, so it scales with throughput rather than company count.

**Decisions.**
- **DES-001** — Layer the classifier on top of the keyword router with a fallback path. Satisfies: REQ-001, NFR-005.
- **DES-002** — Run classification under `Cympho.TaskSupervisor` so `create_issue/1` stays under 100 ms. Satisfies: REQ-001, NFR-001.
- **DES-003** — Persist classifier source in `monitor_state["routing"]["source"]` to keep re-classification cheap. Satisfies: REQ-001 (AC-007).
- **DES-004** — Store classifier metadata inline rather than introducing a new table. Satisfies: REQ-001, NFR-006.
- **DES-005** — Build `Cympho.ExecutionPolicies.Advancer` as a `GenServer` subscribed to a new `system:execution_policies` topic, mirroring the existing `Decisions.Executor` pattern. Satisfies: REQ-002.
- **DES-006** — Use a `Repo.transaction` with row lock to serialise stage advancement. Satisfies: REQ-002 (AC-008, NFR-005).
- **DES-007** — Gate every new GenServer behind a `:start_*?` application env flag. Satisfies: REQ-002 (AC-013), REQ-003 (AC-019), NFR-006.
- **DES-008** — Build `Cympho.Adapters.MockAdapter` with an ETS-backed script store keyed by `{agent_id, issue_id, invocation_index}`. Satisfies: REQ-003.
- **DES-009** — Register the mock adapter via the existing `Cympho.Adapters.Registry.register/2` API only in test env. Satisfies: REQ-003 (AC-019).
- **DES-010** — Emit telemetry events on classify and advance so operators can observe both seams in production. Satisfies: NFR-004.
- **DES-011** — Re-classify only when `monitor_state["routing"]["source"] == "llm"` to avoid clobbering manually edited assigned_role values. Satisfies: REQ-001 (AC-007).

### Components & Interfaces

- **`Cympho.Routing.LlmClassifier`** — Wraps the Anthropic Messages API to classify an issue's role. API: `classify(issue, opts \\ []) :: {:ok, atom} | {:error, term}`. Path: `lib/cympho/routing/llm_classifier.ex`.
- **`Cympho.Routing`** — Thin context module exposing `classify_role/2` and `should_classify?/1`. API: `classify_role(issue, opts) :: {:ok, atom, source} | {:error, term}` where `source ∈ {:llm, :keyword, :fallback}`. Path: `lib/cympho/routing.ex`.
- **`Cympho.ExecutionPolicies.Advancer`** — `GenServer` that listens on `system:execution_policies` and advances stages flagged `auto_advance: true`. API: `start_link/1`, `handle_info/2`, public helper `advance_now/2 :: :ok | {:error, term}`. Path: `lib/cympho/execution_policies/advancer.ex`.
- **`Cympho.Adapters.MockAdapter`** — Test-only adapter implementing the `Cympho.AgentAdapters` behaviour, backed by an ETS script table. API: `run/4` (behaviour callback), `script/3 :: :ok`, `clear/0 :: :ok`. Path: `lib/cympho/adapters/mock_adapter.ex`.
- **`Cympho.Issues`** — Modified to invoke `Cympho.Routing.classify_role/2` from `maybe_auto_ignite/2` and to broadcast on `system:execution_policies` from `execution_policy_decision/3`. Path: `lib/cympho/issues.ex`.
- **`Cympho.Application`** — Modified to register the advancer GenServer behind `:start_execution_policy_advancer?`. Path: `lib/cympho/application.ex`.
- **`Cympho.Adapters.Registry`** — Modified `register_builtin/0` to register the mock adapter when `Mix.env() == :test`. Path: `lib/cympho/adapters/registry.ex`. (The high-level public `Cympho.Adapters.register/3` lives at `lib/cympho/adapters.ex` and stays unchanged.)

### Dependencies

- **finch** `~> 0.13` — already present, reused for the Anthropic call. No new addition.
- **jason** `~> 1.4` — already present, reused for request/response encoding. No new addition.

No new third-party dependencies are introduced.

### Integration Points

```elixir
# lib/cympho/issues.ex — inside maybe_auto_ignite/2 (existing function)
defp maybe_auto_ignite(%Issue{} = issue, attrs) do
  if auto_ignite?(issue, attrs) do
    Task.Supervisor.start_child(Cympho.TaskSupervisor, fn ->
      Cympho.Routing.classify_and_persist(issue)
    end)
  end

  :ok
end
```

```elixir
# lib/cympho/issues.ex — inside execution_policy_decision/3, after persisting result
Phoenix.PubSub.broadcast(
  Cympho.PubSub,
  "system:execution_policies",
  {:stage_completed, stage_result}
)
```

```elixir
# lib/cympho/execution_policies/advancer.ex — handle_info skeleton
@impl true
def handle_info({:stage_completed, %ExecutionStageResult{} = result}, state) do
  Task.Supervisor.start_child(Cympho.TaskSupervisor, fn -> advance_now(result, []) end)
  {:noreply, state}
end
```

```elixir
# lib/cympho/adapters/mock_adapter.ex — behaviour callback
@impl Cympho.AgentAdapters
def run(issue, agent_id, recipient_pid, opts) do
  session_id = make_ref()
  send(recipient_pid, {:session_started, session_id})
  payload = next_script_entry!(agent_id, issue.id)
  send(recipient_pid, {:turn_completed, session_id, payload})
  send(recipient_pid, {:session_ended, session_id, :normal})
  session_id
end
```

```json
{
  "stages": [
    {"name": "draft", "auto_advance": true, "require_role": "engineer"},
    {"name": "review", "auto_advance": false, "require_role": "cto"},
    {"name": "merge", "auto_advance": true}
  ]
}
```

### Testing Strategy

- **Unit:** **TEST-001** — verifies: AC-001, AC-002, AC-003 — covers `Cympho.Routing.classify_role/2` happy-path, fallback, and invalid-result paths with `Finch` request injection.
- **Unit:** **TEST-002** — verifies: AC-004, AC-006, AC-022, AC-023 — toggles `:llm_router_enabled?` and missing API key, asserts no network call and `:fallback` telemetry.
- **Unit:** **TEST-003** — verifies: AC-005, AC-024 — asserts `[:cympho, :routing, :classified]` telemetry shape and metadata using `:telemetry_test`.
- **Unit:** **TEST-004** — verifies: AC-007, DES-011 — re-classify behaviour when `monitor_state["routing"]["source"] == "llm"` versus other sources.
- **Unit:** **TEST-005** — verifies: AC-008, AC-009, AC-012, AC-025, NFR-005 (AC-028) — `Cympho.ExecutionPolicies.Advancer.advance_now/2` happy path and malformed-stage path.
- **Unit:** **TEST-006** — verifies: AC-010, AC-011 — final-stage completion and `auto_approve_below_cost` skip.
- **Integration:** **TEST-007** — verifies: AC-014, AC-015, AC-018, AC-019 — `Cympho.Adapters.MockAdapter` dispatches messages in the right order and surfaces missing-script errors.
- **Integration:** **TEST-008** — verifies: AC-016 — full "make Cympho better than Linear" mission run.
- **Integration:** **TEST-009** — verifies: AC-017 — full "stuck engineer" recovery run.
- **End-to-end:** None — the integration tests above exercise the full loop in-process; no UI flow exists for this spec.
- **Regression:** **TEST-010** — verifies: AC-029, AC-030 — the existing `dispatcher_test.exs` and `execution_policy_lifecycle_test.exs` keep passing with the flags turned off.
- **Manual QA:** None — coverage is fully automated.

### Rollout Plan

- **Migration steps:** None — no schema migration; the new fields piggy-back on `monitor_state` and existing `stage_configs` JSON. Set `:cympho, :llm_router_enabled?` to `false` at first deploy and flip to `true` once the API key is provisioned.
- **Backwards compatibility:** Existing keyword router and human-driven `execution_policy_decision/3` keep working unchanged when their flags are off.
- **Rollback procedure:** Set `:cympho, :llm_router_enabled?` to `false` and `:cympho, :start_execution_policy_advancer?` to `false`, redeploy, restart the Cympho release. The system reverts to the deterministic keyword router and the human-driven stage advancement.
- **Observability:** New telemetry events `[:cympho, :routing, :classified]` and `[:cympho, :execution_policy, :advanced]`. New log lines from the advancer GenServer prefixed `[ExecutionPolicies.Advancer]`.
- **Feature flags:** Two boolean app-env flags as above. Per-company overrides are out of scope for v1.

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Anthropic API outage causes classification timeouts on every issue creation | Medium | Low | 1.5 s timeout, telemetry on `:fallback`, keyword router still runs deterministically |
| LLM mis-classifies and routes to the wrong role | Medium | Medium | `monitor_state["routing"]["source"]` lets agents (or operators) override and pin the role; keyword router remains as floor |
| Advancer thunders on a stage that never settles | Low | Medium | `auto_advance` is opt-in per stage; advancer logs warnings instead of looping |
| Mock adapter accidentally registered in production | Low | High | Registration only inside `Mix.env() == :test`; a build-time assertion in `Cympho.Adapters.Registry.register_builtin/0` raises if `:mock` adapter is registered in prod |
| Concurrent stage transitions collide on the same `execution_stage_results` row | Low | Low | `Repo.transaction` with `FOR UPDATE` lock serialises advancement |

### Research

- Anthropic Messages API — https://docs.anthropic.com/en/api/messages — version `2023-06-01`, accessed 2026-05-19 — endpoint, headers, and JSON schema reused unchanged from `Cympho.AgentRunner`.
- Phoenix.PubSub broadcast/subscribe semantics — https://hexdocs.pm/phoenix_pubsub/Phoenix.PubSub.html — version 2.1.3, accessed 2026-05-19 — confirms ordering guarantees we rely on for advancer event delivery.
- Ecto `FOR UPDATE` row locking — https://hexdocs.pm/ecto/Ecto.Query.html#lock/3 — version 3.13, accessed 2026-05-19 — pattern used in `Cympho.Issues.maybe_complete_parent` already; reused by the advancer.
- Telemetry conventions — https://hexdocs.pm/telemetry/readme.html — version 1.4, accessed 2026-05-19 — used to standardise the new events.

### Codebase Analysis

- **Patterns:** GenServers for sweeping background concerns (`BacklogPlanner`, `Oversight.Patrol`, `Decisions.Executor`) gated by `:start_*?` env flags; PubSub broadcasts for cross-process events; agent action validation in `Cympho.AgentActions` mirrors patterns used in `Cympho.GovernanceAuditLogs`.
- **Conventions:** Snake_case file names, contexts in `lib/cympho/`, web LiveViews in `lib/cympho_web/`, schemas under `lib/cympho/{context}/{schema}.ex`. Tests are co-located by context under `test/cympho/`.
- **Testing approach:** `ExUnit.DataCase` with `async: false` for tests touching global state (rate limiter, registry, mock adapter); `async: true` for pure data-only tests. Integration tests use `Cympho.Companies.create_autonomous_company/1` to seed a full company graph.
- **Similar implementations:** `lib/cympho/decisions/executor.ex` is the closest analogue to the advancer; `lib/cympho/orchestrator/backlog_planner.ex` is the closest analogue for env-gated sweeps; `lib/cympho/agent_runner.ex` is the closest analogue for HTTP-driven outbound calls.
- **Reusable utilities:** `Cympho.AgentRunner.api_key/0` for the Anthropic key resolution, `Cympho.Repo.transaction/1` with `FOR UPDATE`, `Cympho.AgentAdapters.Registry.register/2` for adapter registration, `Cympho.TaskSupervisor` for fire-and-forget classification.

---

## Task List Document

- [ ] **TASK-001** [setup] Add `:llm_router_enabled?` (default `true`), `:llm_classifier_timeout_ms` (default `1500`), and `:start_execution_policy_advancer?` (default `true`) to `config/config.exs`; mirror them as `false` in `config/test.exs`. Paths: `config/config.exs`, `config/test.exs`. Implements: `REQ-001`, `REQ-002`, `DES-007`. Verifies: `N/A`. Depends: `None`. Done when: `mix test --only config_smoke` shows all three keys readable with the documented defaults.
- [ ] **TASK-002** [model] Document the `monitor_state["routing"]` shape (`%{"source" => "llm" | "keyword" | "fallback", "classified_at" => iso8601, "model" => string}`) in `Cympho.Issues.Issue` schema moduledoc. Paths: `lib/cympho/issues/issue.ex`. Implements: `REQ-001`, `DES-003`. Verifies: `N/A`. Depends: `TASK-001`. Done when: moduledoc renders the JSON shape verbatim and `mix compile --warnings-as-errors` is clean.
- [ ] **TASK-003** [service] Build `Cympho.Routing.LlmClassifier.classify/2` that calls the Anthropic Messages API with the issue title, description, and project/company name only, returning `{:ok, atom}` or `{:error, reason}`. Paths: `lib/cympho/routing/llm_classifier.ex`. Implements: `REQ-001`, `DES-001`, `DES-002`. Verifies: `N/A`. Depends: `TASK-001`. Done when: a manual `Cympho.Routing.LlmClassifier.classify(%Issue{title: "Refactor auth", description: ""})` returns `{:ok, atom}` against a real key, and `{:error, :missing_api_key}` when the key is absent.
- [ ] **TASK-004** [service] Build `Cympho.Routing` context with `classify_role/2` and `classify_and_persist/1`; the latter wraps `LlmClassifier`, falls back to `Router.infer_role/1`, persists `assigned_role` and `monitor_state["routing"]` via `Issues.update_issue/2`, and emits `[:cympho, :routing, :classified]` telemetry. Paths: `lib/cympho/routing.ex`. Implements: `REQ-001`, `DES-001`, `DES-002`, `DES-003`, `DES-010`. Verifies: `N/A`. Depends: `TASK-003`. Done when: `iex> Cympho.Routing.classify_and_persist(issue)` updates the row and emits telemetry observable via `:telemetry_test`.
- [ ] **TASK-005** [integration] Hook `Cympho.Routing.classify_and_persist/1` into `Cympho.Issues.maybe_auto_ignite/2` so it runs under `Cympho.TaskSupervisor` only when `auto_ignite?` is true and the issue has no explicit `assigned_role`. Paths: `lib/cympho/issues.ex`. Implements: `REQ-001`, `DES-001`, `DES-002`. Verifies: `N/A`. Depends: `TASK-004`. Done when: `Issues.create_issue(%{title: "..."})` returns `{:ok, issue}` and a logged classify event lands on the topic within 2 s.
- [ ] **TASK-006** [integration] Re-classify on `Issues.update_issue/2` when title/description changed AND `monitor_state["routing"]["source"] == "llm"`. Paths: `lib/cympho/issues.ex`. Implements: `REQ-001` (AC-007), `DES-011`. Verifies: `N/A`. Depends: `TASK-005`. Done when: editing an LLM-classified issue's title triggers re-classification; editing a keyword-classified issue's title does not.
- [ ] **TASK-007** [test] Write `test/cympho/routing/llm_classifier_test.exs` covering the happy path with an injected `Finch` stub returning a fake JSON response. Paths: `test/cympho/routing/llm_classifier_test.exs`. Implements: `REQ-001`, `DES-001`. Verifies: `TEST-001` covering `AC-001`, `AC-002`, `AC-003`. Depends: `TASK-003`. Done when: `mix test test/cympho/routing/llm_classifier_test.exs` is green.
- [ ] **TASK-008** [test] Write `test/cympho/routing_disabled_test.exs` toggling `:cympho, :llm_router_enabled?` to `false` and asserting the keyword router runs synchronously. Paths: `test/cympho/routing_disabled_test.exs`. Implements: `REQ-001`. Verifies: `TEST-002` covering `AC-004`, `AC-006`, `AC-022`, `AC-023`. Depends: `TASK-005`. Done when: the suite is green AND no Finch request is made (asserted with a counting stub).
- [ ] **TASK-009** [test] Write `test/cympho/routing_telemetry_test.exs` using `:telemetry_test` to assert event name + measurements + metadata for both `:llm` and `:fallback` paths. Paths: `test/cympho/routing_telemetry_test.exs`. Implements: `REQ-001`, `NFR-004`. Verifies: `TEST-003` covering `AC-005`, `AC-024`. Depends: `TASK-005`. Done when: the suite is green.
- [ ] **TASK-010** [test] Write `test/cympho/routing_reclassify_test.exs` covering `monitor_state["routing"]["source"]` branches on `update_issue/2`. Paths: `test/cympho/routing_reclassify_test.exs`. Implements: `REQ-001`, `DES-011`. Verifies: `TEST-004` covering `AC-007`. Depends: `TASK-006`. Done when: the suite is green.
- [ ] **TASK-011** [service] Build `Cympho.ExecutionPolicies.Advancer` `GenServer`: subscribes to `system:execution_policies` at boot; `handle_info({:stage_completed, %ExecutionStageResult{}}, state)` calls `advance_now/2`; `advance_now/2` reads `stage_configs`, applies the next stage's `auto_advance`, optionally `auto_approve_below_cost`, broadcasts `:stage_advanced`, and emits `[:cympho, :execution_policy, :advanced]` telemetry. Paths: `lib/cympho/execution_policies/advancer.ex`. Implements: `REQ-002`, `DES-005`, `DES-006`, `DES-010`. Verifies: `N/A`. Depends: `TASK-001`. Done when: `iex> Cympho.ExecutionPolicies.Advancer.advance_now(stage_result, [])` returns `:ok` and the next stage row is created.
- [ ] **TASK-012** [integration] Add a `Phoenix.PubSub.broadcast/3` call inside `Cympho.Issues.execution_policy_decision/3` (after the result is persisted) on the `system:execution_policies` topic with `{:stage_completed, stage_result}`. Paths: `lib/cympho/issues.ex`. Implements: `REQ-002`, `DES-005`. Verifies: `N/A`. Depends: `TASK-011`. Done when: the existing `execution_policy_lifecycle_test.exs` still passes AND a manual `Phoenix.PubSub.subscribe/2` call sees the event.
- [ ] **TASK-013** [integration] Register `Cympho.ExecutionPolicies.Advancer` in `Cympho.Application.start/2` behind `:start_execution_policy_advancer?` (mirrors the planner / patrol pattern). Paths: `lib/cympho/application.ex`. Implements: `REQ-002`, `DES-007`. Verifies: `AC-013`. Depends: `TASK-011`. Done when: `mix test` boots the app without starting the advancer (test config flag is false), and `mix run -e "Application.ensure_all_started(:cympho)"` does start it.
- [ ] **TASK-014** [test] Write `test/cympho/execution_policies/advancer_test.exs` covering the happy path, the malformed-stage path, the `auto_advance: false` no-op, the final-stage completion, and the `auto_approve_below_cost` branch. Paths: `test/cympho/execution_policies/advancer_test.exs`. Implements: `REQ-002`, `DES-005`. Verifies: `TEST-005` covering `AC-008`, `AC-009`, `AC-012`, `AC-025`, `AC-028`; `TEST-006` covering `AC-010`, `AC-011`. Depends: `TASK-013`. Done when: the suite is green.
- [ ] **TASK-015** [service] Build `Cympho.Adapters.MockAdapter`: ETS table `:cympho_mock_adapter_scripts`, public `script(agent_id, issue_id, [payloads])` and `clear/0`, behaviour callback `run/4` that pops the next entry and pushes `:session_started` / `:turn_completed` / `:session_ended`. Paths: `lib/cympho/adapters/mock_adapter.ex`. Implements: `REQ-003`, `DES-008`. Verifies: `N/A`. Depends: `TASK-001`. Done when: a manual `script/3` call followed by `MockAdapter.run/4` drives the orchestrator's protocol end-to-end.
- [ ] **TASK-016** [integration] Register `:mock` in `Cympho.Adapters.Registry.register_builtin/0` only when `Mix.env() == :test`; raise on registration if not in test env. Paths: `lib/cympho/adapters/registry.ex`. Implements: `REQ-003`, `DES-009`. Verifies: `AC-019`. Depends: `TASK-015`. Done when: `MIX_ENV=test iex -S mix` returns `{:ok, MockAdapter, _}` from `Adapters.Registry.resolve(%{adapter: :mock, config: %{}})`, and `MIX_ENV=prod` raises.
- [ ] **TASK-017** [test] Write `test/cympho/adapters/mock_adapter_test.exs` covering message ordering, missing-script error, and clear/3. Paths: `test/cympho/adapters/mock_adapter_test.exs`. Implements: `REQ-003`, `DES-008`. Verifies: `TEST-007` covering `AC-014`, `AC-015`, `AC-018`, `AC-019`. Depends: `TASK-016`. Done when: the suite is green.
- [ ] **TASK-018** [test] Write `test/cympho/integration/mission_better_than_linear_test.exs` scripting CEO → CTO → engineer x2 → release_engineer → CEO sign-off, asserting all wakes, transitions, and the final mission goal completion. Paths: `test/cympho/integration/mission_better_than_linear_test.exs`. Implements: `REQ-003`, `DES-008`. Verifies: `TEST-008` covering `AC-016`. Depends: `TASK-017`. Done when: the test asserts mission goal `status: "completed"`, both PRs merged, no human interventions logged.
- [ ] **TASK-019** [test] Write `test/cympho/integration/stuck_engineer_recovery_test.exs` scripting an engineer adapter as `:silent`, advancing simulated time past the patrol threshold, asserting CTO `intervene reassign`, and a different engineer completing. Paths: `test/cympho/integration/stuck_engineer_recovery_test.exs`. Implements: `REQ-003`, `DES-008`. Verifies: `TEST-009` covering `AC-017`. Depends: `TASK-017`. Done when: the test asserts the original engineer is paused (or unassigned) and the work completes via the new engineer.
- [ ] **TASK-020** [test] Add a regression smoke test asserting today's keyword router behaviour is unchanged when `:cympho, :llm_router_enabled?` is `false`. Paths: `test/cympho/router_keyword_floor_test.exs`. Implements: `NFR-006`. Verifies: `TEST-010` covering `AC-029`, `AC-030`. Depends: `TASK-008`. Done when: the suite is green.
- [ ] **TASK-021** [docs] Update `REVIEWS/fire-and-forget-gaps.md`: mark the LLM router (§B1), execution-policy autonomy (§C1), and end-to-end integration tests (§6.6) items as shipped; reference this spec by id (`01_remaining_autonomy_polish_spec.md`). Paths: `REVIEWS/fire-and-forget-gaps.md`. Implements: `REQ-001`, `REQ-002`, `REQ-003`. Verifies: `N/A`. Depends: `TASK-019`. Done when: the report's three "remaining items" are visibly marked shipped.
- [ ] **TASK-022** [verification] Run `mix format && mix test` and confirm a clean run. Paths: `N/A — verification only`. Implements: `N/A`. Verifies: `TEST-001`, `TEST-002`, `TEST-003`, `TEST-004`, `TEST-005`, `TEST-006`, `TEST-007`, `TEST-008`, `TEST-009`, `TEST-010` covering every `AC-NNN` in this spec. Depends: `TASK-021`. Done when: `mix test` reports `0 failures` and `mix format --check-formatted` exits 0.

---

## Short Summary

- This spec closes the last three roadmap items in the fire-and-forget autonomy work: smarter routing, a real autonomous execution-policy advancer, and high-confidence integration tests.
- The audience is the Cympho engineering team. The business value is fewer mis-routed issues, autonomous progression of multi-stage workflows, and regression coverage that catches autonomy-spine regressions before they reach production.
- Approach: layer an Anthropic LLM classifier on top of the existing keyword router with a deterministic fallback; add an `ExecutionPolicies.Advancer` GenServer that mirrors the existing `Decisions.Executor` pattern; add a test-only `Cympho.Adapters.MockAdapter` and two scripted integration tests that drive the entire mission loop without external network calls.
- Every new module is opt-in via `:start_*?` application env flags, and every change preserves today's deterministic behaviour when its flag is off — rollback is a config flip and a redeploy.
- Out of scope: replacing the keyword router entirely, classifying child issues, building a UI for classification results, and migrating execution policies to a workflow-engine library.

---

## Traceability Matrix

| REQ-ID | AC-IDs | DES-IDs | TASK-IDs | TEST-IDs |
| --- | --- | --- | --- | --- |
| REQ-001 | AC-001, AC-002, AC-003, AC-004, AC-005, AC-006, AC-007 | DES-001, DES-002, DES-003, DES-004, DES-010, DES-011 | TASK-001, TASK-002, TASK-003, TASK-004, TASK-005, TASK-006, TASK-007, TASK-008, TASK-009, TASK-010, TASK-021, TASK-022 | TEST-001, TEST-002, TEST-003, TEST-004 |
| REQ-002 | AC-008, AC-009, AC-010, AC-011, AC-012, AC-013 | DES-005, DES-006, DES-007, DES-010 | TASK-001, TASK-011, TASK-012, TASK-013, TASK-014, TASK-021, TASK-022 | TEST-005, TEST-006 |
| REQ-003 | AC-014, AC-015, AC-016, AC-017, AC-018, AC-019 | DES-007, DES-008, DES-009 | TASK-001, TASK-015, TASK-016, TASK-017, TASK-018, TASK-019, TASK-021, TASK-022 | TEST-007, TEST-008, TEST-009 |
| NFR-001 | AC-020, AC-021 | DES-002, DES-006 | TASK-005, TASK-011, TASK-022 | TEST-001, TEST-005 |
| NFR-002 | AC-022, AC-023 | DES-001 | TASK-008, TASK-022 | TEST-002 |
| NFR-004 | AC-024, AC-025, AC-026 | DES-010 | TASK-004, TASK-009, TASK-011, TASK-014, TASK-022 | TEST-003, TEST-005, TEST-007 |
| NFR-005 | AC-027, AC-028 | DES-001, DES-005, DES-006 | TASK-004, TASK-011, TASK-014, TASK-022 | TEST-005 |
| NFR-006 | AC-029, AC-030 | DES-007 | TASK-001, TASK-013, TASK-016, TASK-020, TASK-022 | TEST-010 |
