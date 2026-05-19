# Cympho Fire-and-Forget Gap Analysis

Goal: take Cympho from "agents react to issues humans file" to **"owner files one mission, the company runs itself."** Reviewed against the codebase as of `lib/cympho/` on the current branch.

The architecture is already strong — Orchestrator GenServers per issue, a DB-backed wake queue, a watchdog, role-based prompts, governance hooks, runtime preflight, budget gates. But the *autonomy spine* is incomplete in specific, fixable ways. Below is what I found, with file:line citations and concrete patches.

---

## Part 1 — The autonomy spine, end to end

### 1.1 The self-driving loop today

```
Owner files Issue → Dispatcher poll (every 30s) → Router.infer_role (keywords)
  → checkout_issue → Orchestrator GenServer → AgentRunner.run via adapter
  → cympho-actions JSON parsed → AgentActions.execute
    → submit_review / approve / handoff / create_issue / etc.
  → handoff/submit_review → Dispatcher.enqueue_wake → WakeupQueue
  → next agent's heartbeat (PubSub topic wakeups:<agent_id>) → triggers Dispatcher.poll_now
```

This works for a single in-flight issue. **Where it breaks down for fire-and-forget is between missions, between idle states, and at the company-level "what next" decision.**

### 1.2 The dispatcher only reacts to existing rows

`lib/cympho/orchestrator/dispatcher.ex:281` `fetch_candidate_issues/2` queries:

```elixir
Cympho.Issues.Issue
|> where([i, c], i.status in ^@active_states)   # [:todo, :in_review]
```

If no issue is `:todo` or `:in_review`, nothing happens — the dispatcher idles. There is no path that says "company has missions but no active issues — wake the CEO to plan." That is the central fire-and-forget defect.

### 1.3 The wake taxonomy never fires from "above"

`lib/cympho/wakes/agent_wake.ex:28-44` enumerates all valid wake reasons:

```
issue_commented, issue_comment_mentioned, issue_blockers_resolved,
issue_children_completed, execution_policy_stage_transition,
manual_dispatch, company_resumed, routine_triggered, agent_handoff,
runtime_retry, issue_created, child_created, child_status_changed,
final_review_required, review_nudge_re_emit, review_nudge_escalated
```

Every reason is **issue-scoped and bottom-up.** There is no `mission_idle`, `goal_progress_check`, `next_priority_review`, `manager_directive`, `escalation_from_subordinate`, or `routine_replan`. The wake system literally cannot represent "your company has nothing in flight — pick the next priority" because no such reason exists.

### 1.4 Goals are decorative

`lib/cympho/goals.ex` (213 lines) is pure CRUD over the `goals` table — `list_*`, `get_*`, `create_*`, `goal_progress/1`, `get_ancestors/1`. **Nothing in the codebase creates issues from goals.** Searching `lib/` for callers that turn a goal into work returns nothing. The `lineage_block` in `lib/cympho/agent_prompt.ex:131-142` *displays* goal ancestry to agents, but nothing wakes the CEO when a mission goal exists with zero `goal_id`-linked issues.

This is the single highest-leverage missing piece. A user types "make Cympho better than Linear" → it becomes a `:mission` Goal → ...nothing.

---

## Part 2 — Detailed gaps with file:line citations

### A) Missing capabilities (must add)

#### A1. `decompose_goal` / `seed_mission` action

**Today.** `lib/cympho/agent_actions.ex:46` — `@supported_types` allows agents to `create_issue` (line 430) but the *first* issue still has to exist before any agent runs. Goals are inert.

**Add.** A pseudo-action that runs *outside* an issue context. Either:

- A new `Cympho.Goals.Decomposer` GenServer that on goal creation enqueues a synthetic "planning issue" titled `Plan: <mission title>` assigned to `:ceo`, with `assigned_role: "ceo"`. The CEO agent's first turn on that issue produces `create_issue` actions for each initiative, populating `goal_id`.
- Or, a new agent action `seed_mission_issues` (CEO-only, `@governance_roles`) that takes `{goal_id, breakdown: [...]}` and creates N issues in a single transaction.

**Why this is not just "use create_issue."** `create_issue` requires an *existing* parent issue (it sets `parent_id: issue.id`, `request_depth: parent + 1`, and calls `find_recent_duplicate(company_id, title, goal_id)`). For mission decomposition the parent is the *goal*, not an issue.

**Patch surface.**
- `lib/cympho/agent_actions.ex:46` add `seed_mission_issues` to `@supported_types` and authorize for `[:ceo]` only.
- `lib/cympho/goals.ex` add `Goals.create_mission/2` that wraps `create_goal` + creates the planning issue.
- `lib/cympho/agent_prompt.ex:441` `action_contract_example(:ceo)` add example.

#### A2. `spawn_agent` action — function exists, agents can't call it

**Today.** `lib/cympho/agents.ex:373-415` already implements `spawn_agent/2` with `validate_spawn`, `execute_spawn`, and `maybe_require_spawn_hire_approval`. The role hierarchy in `agents.ex:336-365` (`role_rank`, `spawn_authorized?`, `spawnable_roles`) is fully wired.

**But.** This function is only called from elsewhere in the Elixir code; **it is not exposed in `agent_actions.ex` `@supported_types` (line 46) so the CEO agent literally cannot say "hire me an engineer."** When work backs up and there are no engineers, `routed_agent_for_issue` (dispatcher.ex:431) returns `:no_agent_available` and the issue retries with backoff up to `@max_retries=5`, then is abandoned (`record_dispatch_failure` at `dispatcher.ex:374`).

**Patch.**
- `agent_actions.ex` add `execute_action(issue, agent, %{"type" => "spawn_agent", "role" => role, "name" => name, ...})`. Authorize via `Agents.spawn_authorized?(agent, role_atom)`.
- Wake the new agent with `routine_triggered` reason once created.

#### A3. `delegate` action distinct from `handoff`

**Today.** `handoff` (`agent_actions.ex:571`) sets `assignee_id: nil` + `assigned_role: <role>` and lets the dispatcher router pick *anyone* with that role. It cannot say "specifically my engineer Alice." A CEO who hires multiple engineers cannot direct work to one over another.

**Patch.** Add `delegate` action with `to_agent_id` field, sets `assignee_id` directly, enqueues `manager_directive` wake. Authorize: caller must satisfy `role_rank(caller) > role_rank(target)` or be the target's `parent_id`.

#### A4. `escalate` action

**Today.** When an engineer hits `block_issue` (`agent_actions.ex:511`), the issue goes to `:blocked` with `assignee_id: nil`. **No one is notified upward.** The CTO/CEO will only learn about it via UI inspection or a periodic review. There is no `escalate` analog.

**Patch.** Add `escalate` action that:
- Sets `status: :blocked` + `assigned_role: <parent_role_or_ceo>`, `assignee_id` = `Agents.get_agent(agent.parent_id)` if matches role.
- Enqueues new wake reason `escalation_from_subordinate` (extend `lib/cympho/wakes/agent_wake.ex:28` `@reasons`).
- Different from `block_issue` because it explicitly *seeks* boss intervention rather than just stalling.

#### A5. `mission_idle` wake + BacklogPlanner

**Today.** `lib/cympho/orchestrator/dispatcher.ex:228` `do_poll/2` calls `reconcile_running` then `fetch_and_dispatch`. If `fetch_candidate_issues` returns `[]`, the dispatcher quietly waits for the next 30s tick. Nothing wakes the CEO.

**Patch.** Add a sibling supervisor child `Cympho.Orchestrator.BacklogPlanner`:

```elixir
# Every N minutes per company:
# if count(active issues) == 0
#    and exists?(active mission goal)
#    and last CEO wake > 1h ago
# then Wakes.do_wake_agent(ceo_id, nil, "mission_idle", "system", nil, %{})
```

Add `mission_idle` to `@reasons` in `lib/cympho/wakes/agent_wake.ex:28`. Add a CEO-only entry in `agent_prompt.ex` for `mission_idle` context: "no work is currently in flight — choose the next initiative from the mission tree, or report mission complete."

The CEO's response should produce `create_issue` actions; the wake `issue_id` is `nil` so we'd need to allow `nil` issue context (currently the orchestrator runs *per issue*, so an issue-less wake also needs an issueless run path or a synthetic "company planning" issue).

**Sub-decision.** Synthetic "Mission planning" issue per company (created lazily, status `:in_review` and re-used) is simpler than refactoring the orchestrator to handle issueless runs.

#### A6. `yield_for_replan` action

**Today.** No way for an agent to say "I've done what I can; please replan." The orchestrator's `turn_count` is tracked at `lib/cympho/orchestrator.ex:183` but invisible to the agent. A long-running agent that realizes the issue is too big either spams `create_issue` (which trips `@max_active_child_issues_per_parent = 12`, line 38) or burns out.

**Patch.** Add `yield_for_replan` action that:
- Calls `submit_review` semantics (transitions to `:in_review`) but tags the comment `[replan]`.
- Wakes the parent with `escalation_from_subordinate`.

#### A7. `propose_decision` / `execute_decision` actions

**Today.** `lib/cympho/decisions.ex:97` `create_decision/2` and `:240` `reverse_decision/3` exist. `record_governance_decision` (line 211) is called from `Cympho.AgentGovernance` but **decisions have no auto-side-effect.** A decision like "kill project X" is just a database row — the project's issues keep running.

**Patch.** A `Cympho.Decisions.Executor` (sibling to `BoardApprovalActionExecutor` at `lib/cympho/board_approvals/board_approval_action_executor.ex`) that listens on `Decisions.subscribe(company_id)` and applies side effects per `decision_key`:
- `cancel_project` → cancel all open issues
- `pivot_initiative` → cancel some, create others
- `pause_engineer` → set agent governance status

Then expose `propose_decision` as an agent action (CEO only) so agents can record + execute strategy.

#### A8. `set_priority` / `reprioritize` agent action

**Today.** Issues have `priority` (`lib/cympho/issues/issue.ex`), but agents cannot change it post-creation. `do_create_issue` (`agent_actions.ex:626`) sets priority on creation only. The CEO cannot reorder backlog.

**Patch.** Add `set_priority` action authorized for `:ceo` and `:cto`.

#### A9. Routines have no system-seeded defaults

**Today.** `lib/cympho/routines.ex` is CRUD-only (76 lines). Routine triggers (`lib/cympho/routine_triggers.ex:296` `schedule_all_triggers`) wire enabled routines into Quantum on boot — so the *mechanism* works. But `priv/repo/seeds.exs` doesn't create any default routines, and there's no path for a new company to get e.g. "CEO weekly review every Monday 9am." Self-driving cron is only as autonomous as the user remembers to configure it.

**Patch.**
- `Cympho.Companies.create_company/1` (or onboarding path) seeds 3 default routines: CEO weekly priority review, CTO daily standup pull, mission-progress digest.
- Each routine targets `assignee_id = nil` + `assigned_role` so dispatcher routes it.

---

### B) Tightening existing flows

#### B1. Router is keyword-based and brittle — ✅ shipped (spec `.specs/01_remaining_autonomy_polish_spec.md`)

The LLM-classified `assigned_role` now runs at issue creation via
`Cympho.Routing.classify_and_persist/1` (fan-out under `Cympho.TaskSupervisor`)
with the keyword router as a deterministic fallback. Re-classification on
edit only fires when the prior role was LLM-derived; manual / keyword
labels stay pinned. Toggle via `:cympho, :llm_router_enabled?`.



`lib/cympho/orchestrator/dispatcher/router.ex:7-12` uses static keyword lists:

```elixir
@strategic_keywords ~w[strategic vision funding market partnership acquisition ceo]
@product_keywords ~w[product roadmap customer ...]
@technical_keywords ~w[technical architecture plan review refactor ...]
@implementation_keywords ~w[implement build fix test code feature bug ...]
```

`infer_role_from_text` (line 33) does first-match-wins on these. An issue titled "Refactor the marketing landing page CSS" hits `@technical_keywords` first → CTO, when it's really design work. An issue with no keywords falls through to `:engineer` (line 48).

**Patch.** Either:
- Add an LLM-classified `inferred_role` field set when the issue is created (one-shot call), persisted on the row. Re-classify on title/description edit.
- Or: add `assigned_role` to `Cympho.Issues.create_issue/1` and have the *creating agent* (or owner UI) pick role at creation time. Currently `assigned_role` is only set by `handoff` / `submit_review` / `request_changes` / agent-driven `create_issue`.

A hybrid: keep the keyword router as fallback, but trust `assigned_role` when set, which `Router.assigned_role/1` (line 50) already does — so the patch is to ensure issue creation paths set it. Owner intake (`lib/cympho_web/controllers` and the LiveView issue form) doesn't set `assigned_role`, so owner-filed issues default to keyword routing.

#### B2. `AutoAssignmentReassigner` only fires on idle

`lib/cympho/issues/auto_assignment_reassigner.ex:30-37` subscribes to `system:agent_heartbeats` and only triggers on `hb_state.status == :idle`. This means:
- A queued backlog issue waits for *some* agent to go idle before reassignment is considered, even when a different role becomes idle and there is matching work.
- If no agent ever goes from non-idle → idle (e.g. they were all idle at boot), nothing reassigns.

**Patch.**
- Subscribe to `Phoenix.PubSub` `agents:created` so newly hired agents trigger a reassignment scan.
- Subscribe to `agent_actions` results — when a `block_issue` happens, run reassignment for that company.
- Run a periodic timer (every 5 min) regardless of events as belt-and-suspenders.

#### B3. `AutoAssignment.assign_issue/1` only handles `:backlog`, not `:todo`

`lib/cympho/issues/auto_assignment.ex:88` filters `where: i.status == :backlog and is_nil(i.assignee_id)`. But issues created by `create_issue` action default to `:todo` (`agent_actions.ex:646`) and may be unassigned (if `role` was given without explicit assignee). These never get reassigned by the idle path — the dispatcher poll is their only chance.

**Patch.** Either include `:todo` in the reassign query, or change `do_create_issue` to set `:backlog` until routed. The first is safer.

#### B4. Quality gates can dead-end runs

`agent_actions.ex:729-774` `ensure_submit_review_quality` and `ensure_approval_quality` reject with `{:error, {:quality_gate_failed, action_type, gaps}}`. The rejection emits a system comment via `maybe_emit_rejection_comment` (line 222) which wakes the same agent via the comment-wake path. **If the agent cannot satisfy the gap (e.g. `runtime_verification` because there's no workspace, or `code_reference` because the work doesn't involve code), this loops forever.**

There's no max-retry counter on quality gate failures specifically. The orchestrator's `@max_retries = 5` (`dispatcher.ex:42`) only counts dispatch failures, not quality-gate bounces.

**Patch.**
- Add `quality_retry_count` field on Issue (or in `monitor_state` JSON).
- Increment on each `:quality_gate_failed`. After 3 retries, auto-escalate via the new `escalation_from_subordinate` wake reason to the parent role with metadata `{reason: :quality_unsatisfiable}`.

#### B5. Handoff to a missing role silently stalls

`agent_actions.ex:571` `handoff` sets `assigned_role` and calls `Dispatcher.enqueue_wake(issue.id, "agent_handoff", ...)`. The wake calls `WakeupQueue.enqueue` only if `assignee_id` is set; otherwise it just `poll_now()` and returns `:queued_for_dispatch` (`dispatcher.ex:104`).

If no agent of the requested role exists, the dispatcher's `routed_agent_for_issue` (line 431) walks the fallback chain (`Router.fallback_chain` — engineer→cto→ceo, designer→pm→ceo). If even the fallback chain has no agents, `record_dispatch_failure` (line 374) backs off exponentially up to `@max_retries=5` then *gives up*. The issue sits in `:todo` with `assigned_role` set, with a `[telemetry] stalled_wakeup` log line (line 396) but no UI signal.

**Patch.** When `record_dispatch_failure` reason is `:no_agent` for the *full* fallback chain, auto-escalate by calling the new `spawn_agent` mechanism (request a CEO wake with `mission_idle` + `metadata: %{reason: :no_agent_for_role, role: requested_role}`) so the CEO can hire one. Today there's no recovery path.

#### B6. Dispatcher concurrency cap is global

`dispatcher.ex:32` `@max_concurrent` defaults to **3**, *globally* across all tenants. For a fire-and-forget multi-mission company that's a hard ceiling. Three companies all running missions = each gets ~1 active issue.

**Patch.** Make it per-company (read from `Company.runtime_config` or new column `max_concurrent_runs`). The `running_issue_ids` MapSet would become `%{company_id => MapSet}`.

#### B7. CEO root issue auto-completion is opt-in to review

`lib/cympho/issues.ex:907` `maybe_complete_parent` does the right thing for CEO-rooted issues — promotes parent to `:in_review` and wakes the CEO via `wake_for_final_review` (line 939). Good.

**But.** `root_with_ceo_review?` (referenced at line 935) — verify it returns true only for `assignee.role == :ceo`. If the root has no assignee (e.g. a goal-seeded root that hasn't been picked up), the CEO never gets the wake. The wake_for_final_review function (`wakes.ex:182`) returns `{:error, :no_assignee}` if `assignee_id` is nil.

**Patch.** When `wake_for_final_review` returns `:no_assignee`, fall back to enqueuing a `final_review_required` wake to **any** company CEO via `Agents.get_company_ceo/1` (which already exists, `agents.ex:46`).

#### B8. `agent_wake` `metadata` field is opaque

The metadata field carries `comment_id`, `blocker_id`, `child_id`, etc. but there's no typed contract. New wake reasons (mission_idle, escalation_from_subordinate) will pile on more keys. Future changes will be hard.

**Patch (low priority).** Either: use embedded schemas per reason; or document the schema in `wakes/agent_wake.ex` moduledoc.

#### B9. Heartbeat tick interval is 60s default

`agent_heartbeat.ex:32` `@default_heartbeat_interval :timer.seconds(60)` — every agent process polls every minute. With wakes piped via PubSub this is fine, but the orchestrator's own heartbeat tick at `orchestrator.ex:60` `@heartbeat_tick_interval 30_000` adds another 30s cadence per active session. Consider making these explicitly back off when wakes are flowing.

#### B10. Final-review CEO wake doesn't prompt-feed the digest

`wakes.ex:wake_for_final_review` enqueues a wake with `reason: "final_review_required"` and empty metadata. The CEO agent runs and sees the issue with the standard prompt (`agent_prompt.ex:42`). **The prompt has no special branch for "this is the final mission review" vs "you got tagged on a comment."** The CEO might just comment instead of approving.

**Patch.** `agent_prompt.ex` should detect the wake reason from `opts` (currently it doesn't take wake context) and append a "Why you're here" preamble: "This is the terminal review for this mission. Either `approve_issue` or `request_changes` — do not just comment."

The plumbing exists: `consume_pending_wakes/2` (`orchestrator.ex:478`) marks them consumed but doesn't pass them to the prompt. Pass the most-recent pending wake's reason+metadata into `AgentPrompt.build/3` opts.

---

### C) Governance / policy levers

#### C1. `ExecutionPolicies` is a 41-line CRUD with a powerful schema unused — ✅ shipped (spec `.specs/01_remaining_autonomy_polish_spec.md`)

`Cympho.ExecutionPolicies.Advancer` is a GenServer subscribed to
`system:execution_policies` (broadcast by `Issues.execution_policy_decision/3`)
that auto-advances stages whose `auto_advance: true` config is set. Emits
`[:cympho, :execution_policy, :advanced]` / `:completed` telemetry. Gated
by `:cympho, :start_execution_policy_advancer?` (defaults `true`; tests
opt out).



`lib/cympho/execution_policies.ex` is `list/get/create/update/delete`. **There is no `evaluate/2`, `next_stage/1`, or stage advancement.** The schema (`execution_policies/execution_policy.ex`) has `stage_configs :: {:array, :map}` and a sibling `execution_stage_result.ex` tracks per-stage outcomes — these tables exist but nothing drives them autonomously.

`lib/cympho/issues.ex:1467` `assign_execution_policy/3` and `:1505` `execution_policy_decision/3` write rows. `lib/cympho/runtime.ex:128` `verify_stage_gate/2` reads policies during preflight. So the runtime *checks* gates but nothing *advances* them autonomously — humans drive `execution_policy_decision`.

**Patch.** Add a `Cympho.ExecutionPolicies.AutoAdvancer` GenServer that on `issue_completed` PubSub events checks if the issue has a policy and auto-advances stages whose `auto_advance: true` config is set. Expose policy DSL like:

```json
{
  "stages": [
    {"name": "draft", "auto_advance": true, "require_role": "engineer"},
    {"name": "review", "auto_advance": false, "require_approval_from": "cto"},
    {"name": "merge", "auto_advance": true}
  ]
}
```

#### C2. Board approval is mandatory for hire/role/budget — no per-company opt-out

`lib/cympho/board_approvals.ex:312` `governance_required?/2` reads `company.governance_config["categories"]`. Default is empty list — so by default *no* board approval is required, agents can hire, change roles, change budgets. **That is the right default for fire-and-forget**, so this is actually fine. But:

`lib/cympho/agents.ex:175` `maybe_require_role_change_approval` is called inside `update_agent` and bypasses the company governance config (it has its own check). Read the function to confirm — the config-driven path is in `propose_role_change` (`board_approvals.ex:361`), but if `Agents.update_agent` is called directly (e.g. from Liveview), it goes through the local check. **Inconsistent two paths.**

**Patch.** Unify on `governance_required?/2` everywhere.

#### C3. No cost-aware autonomy

`lib/cympho/budgets.ex:283` `check_budget_constraint/3` exists and the runtime preflight (`lib/cympho/runtime.ex:270`) returns `:budget_blocked` if exceeded. **But agents are not told their remaining budget.** `agent_prompt.ex` has no budget block.

**Patch.** Add a `budget_block` to `agent_prompt.ex` between `runtime_block` and `action_contract_block` showing remaining budget for the company/agent scope. Then agents can self-pace — "I have $0.20 of token budget left, time to hand off and let the next agent inherit."

#### C4. No "auto_approve_below_X" policy switch

For fire-and-forget, the CEO should be able to auto-approve subordinate work when stakes are low. Today `approve_issue` requires the CEO agent to actually run a turn and emit it.

**Patch.** Add to `ExecutionPolicy.stage_configs` a `auto_approve_if: %{cost_under: "5.00", risk_level: "low"}` — applied in `Issues.transition_issue_with_review_gates`.

#### C5. Decision execution and reversal is one-way today

`lib/cympho/decisions.ex:240` `reverse_decision` is well-designed — captures `parent_decision_id` chain and supersedes prior decisions. **But the *original* decision had no side effects to reverse.** Without C7 (Decision Executor), reversal is also decorative.

#### C6. No `runaway_protection` per company

Cympho protects against agent loops via `@max_request_depth = 5` (`agent_actions.ex:34`) and `@max_active_child_issues_per_parent = 12` (line 38). Both are global compile-time. A company with a complex mission may need 8 levels deep; another may want max 3 to limit cost.

**Patch.** Read both from `Company.runtime_config` with the compile-time as fallback.

---

## Part 3 — Prioritized roadmap

If I had to ship this in three pull requests:

### PR 1 — "Mission has a heartbeat" (1 week)
- Add `mission_idle` to `wakes/agent_wake.ex:28` `@reasons`.
- Add `Cympho.Orchestrator.BacklogPlanner` GenServer in `application.ex` supervision tree.
- Add synthetic "Mission Planning" issue per company (lazy-created) for issueless CEO runs.
- Add wake-context preamble to `agent_prompt.ex` so CEO sees "no active work — choose next initiative."
- Add CEO-side example to `agent_prompt.ex:441` showing decompose response.

### PR 2 — "Agents can build their own team and direct it" (1 week)
- Expose `spawn_agent` as agent action (`agent_actions.ex:46`).
- Add `delegate` and `escalate` actions.
- Add `escalation_from_subordinate` wake reason.
- Auto-spawn fallback when `routed_agent_for_issue` exhausts the fallback chain.
- Add `mission_idle` wake when no engineers exist for a hot backlog.

### PR 3 — "Self-driving with guardrails" (1.5 weeks)
- Add `Cympho.Decisions.Executor` for autonomous decision side effects.
- Promote `ExecutionPolicies` to an active stage advancer.
- Expose `propose_decision`, `set_priority`, `seed_mission_issues` actions.
- Make `@max_concurrent`, `@max_request_depth`, `@max_active_child_issues_per_parent` per-company.
- Add budget block to agent prompt.
- Fix `AutoAssignment.assign_issue` to include `:todo` and subscribe to more events (B2, B3).
- Quality-gate retry counter with auto-escalation (B4).
- LLM-classified `assigned_role` at issue creation (B1).

After PR 1 alone, a user can type a mission and walk away. After PR 2, the company hires its way out of capacity gaps. After PR 3, the loop is robust against quality-gate stalls, role-mismatched routing, and budget-blind spending.

---

## Part 4 — Specific call sites worth re-reading

These are the files where most of the changes land:

- `lib/cympho/orchestrator/dispatcher.ex:281` (`fetch_candidate_issues`) — extend to also detect company-level idleness.
- `lib/cympho/orchestrator/dispatcher.ex:374` (`record_dispatch_failure`) — add no-agent escalation.
- `lib/cympho/orchestrator/dispatcher/router.ex:33` (`infer_role_from_text`) — replace or augment with persisted role.
- `lib/cympho/agent_actions.ex:46` (`@supported_types`) — extend with new actions.
- `lib/cympho/agent_actions.ex:430-595` (`execute_action` clauses) — add `spawn_agent`, `delegate`, `escalate`, `propose_decision`, `set_priority`, `seed_mission_issues`, `yield_for_replan`.
- `lib/cympho/agent_prompt.ex:42` (`build/3`) — accept wake context, add budget block, update role guidance.
- `lib/cympho/wakes/agent_wake.ex:28` (`@reasons`) — extend taxonomy.
- `lib/cympho/wakes.ex` — add `wake_for_mission_idle/1`, `wake_for_escalation/2`.
- `lib/cympho/goals.ex` — add `Decomposer` integration; auto-create planning issue on mission creation.
- `lib/cympho/issues/auto_assignment.ex:88` — include `:todo` status.
- `lib/cympho/issues/auto_assignment_reassigner.ex` — subscribe to more events.
- `lib/cympho/execution_policies.ex` — add `evaluate/2`, `auto_advance/2`, an executor GenServer.
- `lib/cympho/decisions.ex` — add an executor GenServer subscribing to its own PubSub.

---

## Part 5 — What Cympho already does well (preserve these)

So nothing gets refactored that shouldn't be:

- **Coalescing wake queue** (`heartbeat_engine/wakeup_queue.ex`): per-agent pending cap, dedup on `agent_id+issue_id+reason`, broadcast topic `wakeups:<agent_id>`. The single most important plumbing for autonomy — keep it.
- **Watchdog** (`heartbeat_engine/watchdog.ex`): recovers stale + orphaned runs every 5 min, requeues via heartbeat. Already provides the safety net for fire-and-forget.
- **Orphan recovery** in `dispatcher.ex:135` `recover_orphaned_in_progress` — releases stranded `:in_progress` issues on boot.
- **Graceful terminate** at `dispatcher.ex:212` releases in-flight issues on SIGTERM.
- **Quality gates** (`agent_actions.ex:729-774`) — keep, just add retry escape hatch.
- **Role-typed action authorization** (`agent_actions.ex:297` `@governance_roles`) — fundamentally right, just expand the action set.
- **`maybe_complete_parent`** (`issues.ex:907`) with row lock + `EXISTS` check — race-safe parent rollup, keep.
- **Lineage block** in prompts (`agent_prompt.ex:131`) — already feeds mission/initiative/milestone IDs into the agent.
- **Coalesced child wakes** (`wakes.ex:notify_child_in_review`) with 60s dedup — keep.
- **Adapter health checking** + **runtime preflight** — fire-and-forget needs both.

---

## Bottom line

Cympho has built ~80% of an autonomous company OS. The missing 20% is **a level above the issue.** Today the system is brilliant at running a single issue end-to-end and decomposing it once; it's blind when no issue exists, when a mission is in flight but stalled at the goal level, and when the team needs to grow or re-prioritize without a human poking it. Three concrete additions — `mission_idle` wake + `BacklogPlanner` + `seed_mission_issues` action — collapse the gap and turn Cympho from a great agent runner into a true Paperclip-style autonomous company.

---

# Part 6 — Oversight, decomposition efficiency, and the PR lifecycle

The report above maps the spine. This section drills into four specific user-asked concerns: (1) supervisor oversight of stuck/in-progress issues, (2) decomposition quality and efficient engineer fan-out, (3) post-PR merge & conflict handling, (4) PR review feedback loops.

## 6.1 Supervisor oversight — CEO/CTO over stuck and in-progress work

### What exists today

- **`HeartbeatEngine.Watchdog`** (`lib/cympho/heartbeat_engine/watchdog.ex:1`) sweeps every 5 min, finds runs whose `last_heartbeat_at` is older than `@stale_threshold = 15 min`, marks them failed, re-triggers heartbeat. **Run-level only — not issue-level.** A run can complete cleanly while the *issue* sits stuck for days.
- **`ReviewNudges.StaleScanner`** (`lib/cympho/review_nudges/stale_scanner.ex:1`) is the closest thing to escalation: T1 re-emit, T2 escalate to a different agent in the same role, then walk `Router.fallback_chain/1`, then drop to Inbox. **But it only operates on review-nudge wakes, not on an issue's age in `:in_progress`.** If an engineer takes the issue and silently makes no progress for 6 hours, no scanner notices.
- **`Cympho.Orchestrator.Dispatcher.recover_orphaned_in_progress`** (`dispatcher.ex:135`) only runs at boot. It doesn't periodically scan during normal operation.
- **Per-issue activity log** exists (`Activities`), but no agent ever *reads* it to decide "this issue is stuck."

### The gap — there is no "supervisor patrol"

A CEO or CTO should periodically scan their team's in-flight issues and intervene. That doesn't happen anywhere. Concretely:

- No GenServer queries `where: i.status == :in_progress and i.checked_out_at < now() - interval '2 hours'`.
- No wake reason `issue_stalled_in_progress` exists in `lib/cympho/wakes/agent_wake.ex:28`.
- No CEO routine seeds e.g. "every 30 min, review in-flight work."
- The orchestrator's per-session `@heartbeat_tick_interval = 30_000` (`orchestrator.ex:60`) only writes a heartbeat row; nothing analyzes the rate of new comments / tool calls / commits to detect a flatlining issue.

### Specific patches

**P6.1-A: `Issues.list_stuck_issues/2`** — query helper:

```elixir
# lib/cympho/issues.ex (add)
def list_stuck_issues(company_id, opts \\ []) do
  in_progress_threshold = Keyword.get(opts, :in_progress_threshold_minutes, 120)
  in_review_threshold   = Keyword.get(opts, :in_review_threshold_minutes, 60)
  blocked_threshold     = Keyword.get(opts, :blocked_threshold_minutes, 30)
  cutoff_in_progress = DateTime.utc_now() |> DateTime.add(-in_progress_threshold * 60, :second)
  cutoff_in_review   = DateTime.utc_now() |> DateTime.add(-in_review_threshold   * 60, :second)
  cutoff_blocked     = DateTime.utc_now() |> DateTime.add(-blocked_threshold     * 60, :second)

  from(i in Issue,
    where: i.company_id == ^company_id,
    where: (i.status == :in_progress  and i.checked_out_at < ^cutoff_in_progress)
        or (i.status == :in_review    and i.updated_at < ^cutoff_in_review)
        or (i.status == :blocked      and i.updated_at < ^cutoff_blocked)
  )
  |> Repo.all()
end
```

**P6.1-B: `Cympho.Oversight.Patrol` GenServer** (new module).

```
- Runs every 5 min per company.
- Calls Issues.list_stuck_issues/2.
- For each stuck issue, computes "who is the right supervisor":
   - blocked or no-progress in_progress → CTO of the assignee
   - in_review > 60 min → the reviewer the work was submitted to
   - root issue (no parent) → CEO
- Enqueues wake with new reason `issue_stalled_in_progress` (extend wakes/agent_wake.ex:28 @reasons).
- Dedups via existing wake coalescing (already in wakeup_queue.ex).
```

**P6.1-C: New supervisor agent action `intervene`.**
The CEO/CTO, on receiving an `issue_stalled_in_progress` wake, gets a new prompt branch (in `agent_prompt.ex` — see PR-1 wake-context preamble) and can emit `intervene` with sub-types:

```json
{ "type": "intervene", "issue_id": "...",
  "action": "reassign" | "decompose" | "unblock" | "cancel" | "force_handoff",
  "reason": "...", "to_role": "engineer" }
```

`reassign` clears `assignee_id` + sets `assigned_role`; `decompose` triggers a `submit_review`-like split; `unblock` flips `:blocked` → `:todo` and removes a blocker. Today an *engineer* can `block_issue` but a CTO can't *un*-block; this is a missing inverse.

**P6.1-D: Add `Issue` velocity signals in `IssueDigest`.**
`lib/cympho/issue_digest.ex:248` already counts `tagged_review_comments`. Add:
- `last_meaningful_event_at` — most recent comment / work_product / tool_call / status_change.
- `progress_velocity` — events / hour over last 6h.
- Surface in agent prompts so CTO/CEO can judge "stuck" themselves.

**P6.1-E: Per-agent WIP limit enforcement.**
`Cympho.Companies.create_company` sets `settings: %{"wip_limits" => %{"in_progress" => engineer_count + 2}}` (`companies.ex:245`) but **nothing reads this.** `Agents.is_agent_at_capacity?/1` (`agents.ex:305`) uses `count_active_assignments` against a hardcoded threshold, not the company WIP setting. Wire this through; otherwise an engineer can be stuffed with 50 issues.

---

## 6.2 Decomposition quality and efficient engineer fan-out

### What exists today

- **`do_create_issue`** (`agent_actions.ex:626`) — one action creates one child. The CEO/CTO must emit multiple `create_issue` actions in one `cympho-actions` block to fan out. Hard cap of `@max_actions = 10` (line 28) per response, `@max_active_child_issues_per_parent = 12` (line 38) per parent.
- **Each `create_issue`** triggers `Dispatcher.enqueue_wake(child.id, "child_created", %{parent_id: ...})` so children dispatch immediately.
- **Prompt** (`agent_prompt.ex:362-371`) tells CEO/CTO: "Split conservatively. Prefer 2–5 focused sub-issues with acceptance criteria over a broad fan-out."
- **`find_recent_duplicate`** (`agent_actions.ex:852`) prevents 24h same-title duplicates within a goal.

### Gaps

1. **No dependency declaration on creation.** `do_create_issue` doesn't accept a `blocked_by` or `depends_on` list, so the CTO can't say "issue B depends on issue A finishing first." All three children are dispatched in parallel even when ordering matters. This causes engineers to step on each other's work.

   The Issue schema *has* `blocked_by` (many-to-many, `lib/cympho/issues/issue.ex:61`) — the join table `issue_blockers` exists. But no agent action populates it.

   **Patch.** Extend `create_issue` action shape to accept `"depends_on": ["<sibling_title_or_id>"]`. Resolve sibling titles to IDs after the create-issue batch is committed. Insert into `issue_blockers`. The dispatcher's existing `Enum.reject(&Issues.is_blocked?/1)` (`dispatcher.ex:319`) will hold dependent children until predecessors finish; `Wakes.notify_blockers_resolved/1` (`wakes.ex:80`) already wakes them.

2. **No "estimate" or "complexity" field used for routing.** A 30-minute task and a 3-day task look identical to the dispatcher. Engineers all go through the same router which load-balances by `count_active_assignments` (`router.ex:107`). This means the most-loaded engineer gets the next big task with the same probability as the next quick task.

   **Patch.** Add `estimated_minutes` (or `t_shirt_size: :xs|:s|:m|:l|:xl`) to `Issue` schema. `Router.select_agent/2` weighs by sum of estimated work, not raw count.

3. **No "swarm" pattern — one engineer per child.** In Cympho today, parallel decomposition sends one engineer per sub-issue. There's no concept of two engineers pairing on a hard problem, or one engineer doing parallel exploration. For fire-and-forget on hard problems this matters.

   **Patch.** Add `assignees` list (or `secondary_assignees`) on Issue. Or simpler: `clone_issue` action that creates two parallel attempts and the CTO picks the best PR.

4. **Engineer pool is opaque to CTO.** When the CTO emits `create_issue` with `"role": "engineer"`, they don't know how many engineers exist or how loaded they are. **They could spam 12 issues to a team of 1.**

   **Patch.** `agent_prompt.ex` for `:cto` should include a "Team status" block:
   ```
   Engineers: 3 active (alice 2 in-flight, bob 1 in-flight, carol idle)
   ```
   Built from `Agents.list_eligible_agents(:engineer, company_id)` + `count_active_assignments`. With this, the CTO can decide "spawn another engineer" vs. "queue more work" vs. "split into sequential phases."

5. **No re-decomposition path.** If the CTO decomposed badly (e.g., 5 children, 4 are blocked on each other and only 1 makes progress), there's no `redecompose` or `merge_children` action. The CTO must `cancel` children manually (and `cancel_issue` isn't even an agent action — only the human UI can cancel).

   **Patch.** Add `cancel_issue` action (governance role only, requires `reason`). Optionally `merge_children` that moves work products from canceled siblings onto a new combined issue.

6. **Decomposition prompt discourages fan-out without telling the model when fan-out is right.** `agent_prompt.ex:373` literally says *"Split conservatively. Prefer 2–5 focused sub-issues."* For a "build a complete feature" mission this under-decomposes; for a "fix this typo" issue it over-decomposes. Better to give explicit heuristics: "Decompose if any child's success criterion is independently verifiable AND each child fits in <2 engineer-hours."

7. **`@max_request_depth = 5`** (`agent_actions.ex:36`) is enforced at child creation, but not surfaced to the agent. The CEO can keep emitting `create_issue` actions that fail with `:request_depth_exceeded` (line 436) and never know to stop. Today this fails silently to the agent (the rejection comment in `maybe_emit_rejection_comment` `agent_actions.ex:251` does mention it, but only after a wasted turn).

   **Patch.** Inject current depth + remaining depth into the prompt:
   `"Sub-issue depth: 3 of 5 max. Two more levels possible before depth is exhausted."`

---

## 6.3 Post-PR — merge, conflict resolution, release engineering

### What exists today

- **`set_pr_url` action** (`agent_actions.ex:553`) records the PR URL on the issue, runs `PullRequestContract.check_url`, posts a system comment.
- **`PullRequestContract.check_url` / `audit_metadata`** (`pull_request_contract.ex:213` and earlier) inspect title, branch name, body sections. **It does *not* check mergeability, conflicts, CI status, or review approvals.**
- **Webhook handler** (`lib/cympho_web/controllers/github_controller.ex:108`):
  - `opened` → transition issue to `:in_review`.
  - `closed` + `merged: true` → transition to `:done`.
  - `closed` + `merged: false` → transition to `:blocked`.
  - `synchronize` → just adds a "PR updated on branch X" comment.

### Critical gaps

1. **There is NO release-engineer role and NO merge automation.** `Agent` schema enum at `lib/cympho/agents/agent.ex:13`:
   ```elixir
   field :role, Ecto.Enum, values: [:engineer, :product_manager, :designer, :ceo, :cto]
   ```
   No `:release_engineer`, no `:devops`, no merge bot. Nothing in the codebase merges PRs. The system *waits* for GitHub to deliver a `closed`+`merged` webhook, then transitions the issue to `:done`. **Who actually clicks merge?** Today: a human, via GitHub UI. For fire-and-forget that's a gating step.

2. **No conflict detection at all.** `synchronize` webhook is a no-op aside from posting a comment. GitHub's `mergeable: false` payload isn't inspected. There's no Cympho-side concept of "this PR has conflicts; wake an engineer to rebase."

3. **No CI status awareness.** GitHub's `check_run` and `status` webhook events aren't routed. `lib/cympho_web/controllers/github_controller.ex` only handles `pull_request` events. CI failures don't wake anyone. An engineer can declare delivery, the CTO can approve, the PR can sit broken in CI for hours.

4. **No "release" or "deploy" issue type.** Once 3 engineers each merge a feature, there's no agent that bundles them, runs tests, deploys, and reports back.

5. **Webhook auto-transitions to `:done` skip `ensure_approval_quality` gate.** `github_controller.ex:140` directly calls `Issues.transition_issue(issue, :done)` on merge. This bypasses the quality gates in `agent_actions.ex:763` `ensure_approval_quality` (which checks `runtime_verification`, `code_reference`). A CEO never reviews the actual deliverable on PRs that auto-merge.

### Patches

**P6.3-A: Add `:release_engineer` role.**
- Update `Agent.role` enum (`agents/agent.ex:13`) and `role_options` (line 147).
- Update `role_rank/1` (`agents.ex:336`) — slot between `:engineer` (3) and `:cto` (4); call it 3 too or insert a new tier.
- Update `Router.infer_role` (`router.ex:7`) keyword list with `merge`, `rebase`, `release`, `deploy`, `ship`, `version`, `tag`.
- Update `Router.fallback_chain` to point `:release_engineer` → `[:engineer, :cto, :ceo]`.
- Add a default release engineer to `Cympho.Companies.create_company`'s seed agents.

**P6.3-B: New agent actions for the merge phase.**

| Action | Caller | Effect |
|---|---|---|
| `merge_pr` | release_engineer, cto | Calls GitHub API to merge; only allowed if CI=green and `mergeable=true` and at least one approve_issue comment |
| `rebase_pr` | release_engineer, engineer | Spawns a worker that rebases the branch, force-pushes |
| `resolve_conflict` | engineer | Wake reason `merge_conflict_detected`; agent edits files, commits |
| `cut_release` | release_engineer | Tags repo, drafts release notes, opens deploy issue |

The `merge_pr` and `rebase_pr` actions need a real Octokit client — `lib/cympho/github.ex` only does GETs (`fetch_pull_request` line 139). Add `Cympho.Github.merge_pr/3` and `update_branch_to_main/3`.

**P6.3-C: Webhook routing for PR review and CI events.**

`lib/cympho_web/controllers/github_controller.ex` should also handle:

- `pull_request_review` event with `action: "submitted"`:
  - `state: "approved"` → comment on issue tagged `[review]`, no transition (let CTO agent decide)
  - `state: "changes_requested"` → wake assignee with new reason `pr_changes_requested`, transition issue to `:in_progress`, post comment with the GitHub review body
  - `state: "commented"` → comment on issue (don't transition), wake reason `pr_review_commented`
- `pull_request_review_comment` (line-level review comments) — fetch the diff context, post each as an issue comment with `[pr-comment]` tag, wake assignee with `pr_line_comments_added` reason and metadata listing the file:line refs.
- `check_run` / `status` events:
  - `conclusion: "failure"` → wake assignee with `ci_failed` reason, post failing logs URL.
  - `conclusion: "success"` AND PR is approved AND `mergeable: true` → wake the release engineer with `pr_ready_to_merge` reason.
- `pull_request` `synchronize` should *also* check `mergeable` field — if `false`, wake the engineer with `merge_conflict_detected`.

Each new wake reason must be added to `lib/cympho/wakes/agent_wake.ex:28` `@reasons`.

**P6.3-D: Background `PullRequestPoller`.**

Webhooks miss events sometimes. Add a Quantum job (`Cympho.Scheduler`) running every 5 min that, for every issue with `github_pr_url` set and status in `[:in_review, :in_progress]`, calls `Github.fetch_pull_request` and reconciles state. This is what catches conflicts that arose from a merge-into-main on a *different* PR.

**P6.3-E: Deploy/release issue templates.**

When N engineering issues under a mission goal hit `:done` with merged PRs, the CTO should auto-fire a `cut_release` issue against `:release_engineer`. Implement as a routine seeded per project: "every Friday, if any merged-but-undeployed issues exist, create a release issue."

**P6.3-F: Don't auto-transition to `:done` on merge — go to `:in_review` for CEO sign-off.**

Today `github_controller.ex:140` does `Issues.transition_issue(issue, :done)` on merge. Change it to `Issues.transition_issue(issue, :in_review)` and `Wakes.wake_for_final_review/1`. The CEO emits `approve_issue` after seeing PR shipped + acceptance criteria met. This routes through `ensure_approval_quality` (`agent_actions.ex:763`) and respects the existing root-CEO sign-off rule (`issues.ex:907`).

---

## 6.4 PR review feedback loop — CTO → engineer → fix → re-review

### What exists today

- **`submit_review`** (`agent_actions.ex:455`) — engineer flips issue to `:in_review`, sets `assignee_id` to parent (the CTO), `assigned_role: "cto"`. Wakes CTO via `agent_handoff`.
- **`request_changes`** (`agent_actions.ex:495`) — CTO flips back to `:todo`, clears assignee, sets `assigned_role: "engineer"`. Posts a tagged comment via `tagged_review_note`.
- **`approve_issue`** (`agent_actions.ex:473`) — CTO approves; runs `ensure_approval_quality`, transitions to `:done`, releases.
- **GitHub webhook** detects external review (e.g. a human reviewer typed comments on the PR) and posts a comment, but doesn't connect it to `request_changes`.

### Gaps that prevent autonomous PR review iteration

1. **CTO agent never reads PR review comments.** When `pull_request_review` arrives with `state: "changes_requested"`, the GitHub controller has *no handler* — it falls through to the default and does nothing. The CTO doesn't see the file:line review comments because:
   - Webhook handler ignores `pull_request_review` events entirely.
   - Even if it posted them as issue comments, the CTO's `agent_prompt.ex:241` `comments_section` shows comments but doesn't distinguish PR-line-comments from issue chat.
   - There's no fetch of review comments into the issue digest.

2. **`request_changes` posts a generic note — engineer doesn't know *what* to fix.** The action's `reason` field (`agent_actions.ex:496`) is free-text. There's no structured field listing files/lines/specific issues, no link to the PR review.

3. **No tracking of "fix iteration count."** An engineer can be sent back 50 times. There's no counter and no escalation. Compare to `quality_retry_count` we proposed in part B4 — same problem, different gate.

4. **No requirement that engineer re-pushes a new commit before re-submitting.** An engineer can `submit_review` again immediately without changing code. `submit_review_quality` checks `agent_note`, `work_product`, `delivery_comment`, `code_reference` (`agent_actions.ex:743`) — but doesn't compare against the *previous* `submit_review` to ensure the head commit changed.

5. **CTO has no "look at the actual diff" capability.** The agent prompt includes work products, comments, runs, but doesn't include the PR diff or specific files changed since last review. The CTO's review is on summary text the engineer wrote, not actual code.

### Patches

**P6.4-A: Wire `pull_request_review` events.**
(See P6.3-C above.) On `state: "changes_requested"`:
1. Fetch the review's body and review-comments via `Github.fetch_pull_request_reviews/2` (new helper).
2. For each review comment, create an issue Comment tagged `[pr-review]` with the file path, line number, and body.
3. Use existing `request_changes` agent action *programmatically*: transition `:in_review` → `:todo`, set `assignee_id` to original delivery agent, set `assigned_role: "engineer"`, post a system comment listing every PR review comment.
4. Wake engineer with new reason `pr_review_changes_requested`.

This means the CTO doesn't have to manually echo PR review comments back to the issue — it happens automatically when a human OR another agent leaves a `changes_requested` review on GitHub.

**P6.4-B: Add `force_fix_pr` action.**

The CTO agent should also be able to drive the loop *without* GitHub. After reviewing the PR (via `Github.fetch_pull_request_files`), the CTO emits:

```json
{
  "type": "force_fix_pr",
  "issue_id": "...",
  "comments": [
    {"file": "lib/x.ex", "line": 42, "body": "this is wrong because Y"},
    {"file": "lib/x.ex", "line": 88, "body": "missing test for edge case Z"}
  ],
  "reason": "Found 2 blocking issues. Fix and re-submit."
}
```

`force_fix_pr` is a stricter `request_changes`:
- Posts each comment with `[pr-review]` tag.
- Optionally posts the comments to the GitHub PR via `Github.create_review/3`.
- Increments `pr_iteration_count` on the issue (new field on Issue schema or on `monitor_state`).
- Transitions to `:in_progress`, assigns to the original delivery agent.
- Wakes engineer with reason `pr_review_changes_requested`.

**P6.4-C: Quality gate on resubmission — head commit must change.**

`submit_review` (`agent_actions.ex:455`) should additionally check: if previous `submit_review` exists for this issue, fetch current PR head SHA from GitHub; reject with `:no_changes_since_last_review` if SHA matches.

```elixir
defp ensure_head_commit_changed(issue) do
  with {:ok, current_pr} <- Github.fetch_pull_request(issue.github_pr_url),
       %{"head_sha" => last_sha} <- last_review_metadata(issue),
       true <- current_pr.head_sha != last_sha do
    :ok
  else
    _ -> {:error, :no_code_changes_since_last_review}
  end
end
```

This stops "I'll just resubmit and hope" loops.

**P6.4-D: Iteration counter + escalation.**

After `pr_iteration_count >= 3`, auto-escalate via the new `escalation_from_subordinate` wake reason (proposed in part A4) to the CEO with metadata `{reason: :pr_loop, count: 3}`. The CEO can either:
- Reassign to a different engineer (via the new `intervene` action's `reassign` mode).
- Hire a more senior engineer (via the new `spawn_agent` action).
- Decompose the issue further.
- `cancel_issue` the work entirely.

**P6.4-E: PR diff in the CTO's prompt.**

Extend `agent_prompt.ex` (around line 232 `pull_request_contract_block`) to also include:
- The `files_changed` list (paths + +N/-M from `pull_request.changed_files` / `additions` / `deletions`).
- For each previously-flagged file (from prior `[pr-review]` comments), whether it was changed in the latest push.
- A "since last review" delta — files touched after last `submit_review` timestamp.

This lets the CTO actually verify "did the engineer fix what I asked?"

**P6.4-F: Convert tagged comments into structured "review feedback panel."**

`lib/cympho/issue_digest.ex:248` already counts `tagged_review_comments`. Add a `pr_review_feedback` section to the digest:

```elixir
%{
  open: [%{file: "lib/x.ex", line: 42, body: "...", from_review_id: 1}, ...],
  resolved: [...],
  iteration_count: 2
}
```

Surface this in the engineer's prompt so they see the open list, not just a wall of comments.

**P6.4-G: New wake reasons (extend `wakes/agent_wake.ex:28` `@reasons`).**

```
pr_review_changes_requested,
pr_review_commented,
pr_line_comments_added,
ci_failed,
merge_conflict_detected,
pr_ready_to_merge,
pr_approved_by_external,
issue_stalled_in_progress,
escalation_from_subordinate
```

---

## 6.5 Updated PR roadmap

Insert these between PR 2 and PR 3 of the original roadmap:

### PR 2.5 — "Supervisors actually supervise" (1 week)
- `Cympho.Oversight.Patrol` GenServer + `issue_stalled_in_progress` wake reason.
- `Issues.list_stuck_issues/2` query.
- `intervene` agent action with `reassign | decompose | unblock | cancel | force_handoff` modes.
- WIP-limit enforcement in `Agents.is_agent_at_capacity?` reading `Company.settings["wip_limits"]`.
- Velocity signals in `IssueDigest`.
- Engineer pool status block in CTO prompt.

### PR 2.75 — "Decomposition with dependencies" (3-4 days)
- `create_issue` action accepts `depends_on: [...]` populating `issue_blockers`.
- `cancel_issue` and `redecompose`/`merge_children` actions.
- `estimated_minutes` on Issue + load-balancer weighting in `Router.select_agent/2`.
- Sub-issue depth surfaced in prompt.

### PR 3 — "PR lifecycle owned by Cympho" (2 weeks)
- `:release_engineer` role added to `Agent.role` enum, role_rank, router keywords, fallback chain.
- `pull_request_review`, `check_run`, `status` webhook handlers.
- `merge_pr`, `rebase_pr`, `resolve_conflict`, `cut_release`, `force_fix_pr` actions.
- `Cympho.Github.merge_pr/3` (GitHub mutation API).
- `Cympho.PullRequestPoller` periodic Quantum job.
- New wake reasons (P6.4-G).
- Stop auto-`:done` on merge — promote to `:in_review` for CEO sign-off.
- `pr_iteration_count` field, head-SHA check on resubmit, escalation at 3 iterations.
- PR review feedback panel in `IssueDigest` and engineer/CTO prompts.

After PR 2.5 the team self-corrects when work stalls. After PR 2.75 the CTO decomposes with real dependency graphs and weighted load. After PR 3 the company merges, deploys, reviews, and re-iterates without a human ever touching GitHub.

---

## 6.6 Two specific failure modes to test against — ✅ shipped (spec `.specs/01_remaining_autonomy_polish_spec.md`)

`Cympho.Adapters.MockAdapter` (test-env-only, gated by
`Cympho.Adapters.Registry.register/2`'s `:mock` guard) is scriptable per
`{agent_id, issue_id}`. The integration tests
`test/cympho/integration/mission_better_than_linear_test.exs` and
`test/cympho/integration/stuck_engineer_recovery_test.exs` exercise the
full autonomy spine end-to-end without external network calls.



A useful litmus test for any of these patches:

**Mission test 1 — "Make Cympho better than Linear."**
Owner files one mission goal. 24 hours later, the system should have:
- Decomposed into ≥3 initiatives, each with sub-issues.
- Hired engineers if existing capacity insufficient.
- Engineers opened ≥1 PR each.
- CTO reviewed and either approved or sent back specific comments.
- CEO approved finished work; merged PRs; cut a release.
- Zero human interventions in the chat or UI.

**Mission test 2 — "Stuck engineer."**
Set an engineer's adapter command to a 30-minute sleep. The system should:
- Detect via Patrol within 10 min.
- CTO reassigns issue to a different engineer (or hires one).
- Original engineer is quarantined (governance status `paused`) by the CEO.
- Mission progresses without the stuck agent.

If either test still requires a human, that's the next gap to file.
