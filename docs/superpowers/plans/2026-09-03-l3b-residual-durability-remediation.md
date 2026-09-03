# L3b Residual Durability Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining tenant, liveness, due-claim, governance-resolution, policy-restart, and crash-checkout gaps found after the first L3b whole-branch review.

**Architecture:** Upgrade source fingerprints to version 2 with one bounded durable liveness token, centralize exact case/source validation, and replace page-then-claim recovery with a one-row atomic `SKIP LOCKED` claim loop. Compose recovery-case resolution into the same BoardApprovals transaction, persist the effective retry policy at adapter boundaries, and order crash cleanup so exact run recovery precedes unbound checkout release.

**Tech Stack:** Elixir/Phoenix, Ecto/PostgreSQL, Phoenix PubSub, existing HeartbeatEngine/Issues/BoardApprovals/Recovery APIs, ExUnit DataCase/LiveCase.

**Spec:** `docs/superpowers/specs/2026-09-03-l3b-residual-durability-remediation-design.md`

## Global Constraints

- Run every project command through `mise x --`; use `ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]'` for test commands on the pinned OTP toolchain.
- All destructive recovery paths must revalidate exact case/company/issue/run/source/agent identity and a durable liveness token; nil or mismatched tenancy fails closed.
- Fingerprint version 2 may include only the bounded liveness CAS token specified by the design; never include credentials, prompts, full logs, arbitrary metadata, or other timestamps.
- Final run mutation must recheck durable age/freshness under the same run-row lock used for the terminal write. Registry/session state remains an advisory skip.
- Each due row must be selected and reserved in one short transaction using `FOR UPDATE SKIP LOCKED`; process callbacks only after commit and visit no row more than once per pass.
- Existing active cases keep their first persisted policy. Effective adapter policy is immutable for that lineage, bounded to three attempts and 600 seconds, and inherited by retry children.
- Denial, cancellation, and expiry update the approval and linked recovery case atomically; audit/PubSub/OwnerAttention occurs only after commit.
- Crash recovery must never ignore an active run. Recover exact run snapshots first, then release an unbound checkout only after no active run or successor owner remains.
- Ordinary dispatch-failure and wake-delivery lineage stay unchanged. Do not claim Paperclip parity, cluster-wide fencing, durable PubSub delivery, or low-resource proof.
- Add a focused regression test before each production behavior change and retain a fresh full serial suite as the final gate.

---

### Task 1: Add liveness-aware fingerprints and exact final source guards

**Files:**
- Modify: `lib/cympho/recovery/fingerprint.ex`
- Modify: `lib/cympho/recovery.ex`
- Modify: `lib/cympho/heartbeat_engine.ex`
- Modify: `test/cympho/recovery/fingerprint_test.exs`
- Modify: `test/cympho/recovery_test.exs`

**Interfaces:**
- `Fingerprint.version/0` returns `2`.
- `Fingerprint.for_run/2` includes string `liveness_at`: running uses `last_heartbeat_at || inserted_at`; pending/queued uses `inserted_at`.
- `Fingerprint.for_issue_checkout/1` includes string `checkout_liveness_at`: `checked_out_at || updated_at`.
- `HeartbeatEngine.recover_run_if_current/4` accepts an exact guard map and options containing `now`; it retains the existing 3-arity wrapper only if existing callers/tests require it, and the wrapper must fail closed without a complete guard.
- Recovery direct/due/exhaustion paths share an exact case/source predicate over company, issue, source, run, agent, fingerprint, status, and liveness token.

- [ ] **Step 1: Write failing fingerprint and freshness tests**

Add assertions equivalent to:

```elixir
assert snapshot["version"] == 2
assert snapshot["liveness_at"] == DateTime.to_iso8601(run.last_heartbeat_at)
assert snapshot["checkout_liveness_at"] == DateTime.to_iso8601(issue.checked_out_at)

{old_fp, _} = Fingerprint.for_run(run, issue)
{:ok, _} = HeartbeatEngine.record_heartbeat(run)
fresh = Repo.get!(Run, run.id)
{fresh_fp, _} = Fingerprint.for_run(fresh, issue)
refute fresh_fp == old_fp
```

Create a stale case, refresh its heartbeat before `Recovery.recover_stale_run/2` and before `Recovery.process_due/1`, then assert the run remains `running`, the case becomes `superseded`, and no approval/issue block is created. Add the equivalent checkout-liveness update test.

Add a direct-SQL corruption matrix that changes one case field at a time (`company_id`, `issue_id`, `source_id`, `source_run_id`, `agent_id`) and asserts due processing never mutates the run/issue.

- [ ] **Step 2: Run RED tests**

```bash
TEST_DB_NAME=cympho_l3b_liveness_red MIX_BUILD_PATH=_build/l3b_liveness_red MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test test/cympho/recovery/fingerprint_test.exs test/cympho/recovery_test.exs --max-cases 1 --seed 12345
```

Expected: version/liveness assertions fail and fresh sources are still recoverable.

- [ ] **Step 3: Implement fingerprint version 2**

Encode only the chosen liveness token as second-truncated ISO-8601. Require it in version-2 source snapshots. Leave legacy version-1 rows readable, but make mutation of a row without a complete current guard return `:superseded`.

- [ ] **Step 4: Implement exact source guard and locked age validation**

Centralize comparison so a heartbeat case must satisfy:

```elixir
case_row.company_id == issue.company_id and
case_row.company_id == run.company_id and
case_row.issue_id == issue.id and
case_row.source_id == run.id and
case_row.source_run_id == run.id and
case_row.agent_id == run.agent_id and
current_fingerprint == case_row.source_fingerprint
```

The final locked HeartbeatEngine transaction must additionally require the run's durable liveness value to be older than `now - 15 minutes` for the requested stale/orphan kind. Pending/queued orphan runs use `inserted_at`; running runs use `last_heartbeat_at || inserted_at`. Perform the age/fingerprint check after acquiring the run and issue row locks and immediately before the status update.

- [ ] **Step 5: Run GREEN tests and commit**

```bash
TEST_DB_NAME=cympho_l3b_liveness_green MIX_BUILD_PATH=_build/l3b_liveness_green MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test test/cympho/recovery/fingerprint_test.exs test/cympho/recovery_test.exs --max-cases 1 --seed 12345
mise x -- mix format --check-formatted
```

```bash
mise x -- git add lib/cympho/recovery/fingerprint.ex lib/cympho/recovery.ex lib/cympho/heartbeat_engine.ex test/cympho/recovery/fingerprint_test.exs test/cympho/recovery_test.exs
mise x -- git commit -m "fix: fence recovery with durable liveness"
```

---

### Task 2: Make due selection and lease claiming atomic

**Files:**
- Modify: `lib/cympho/recovery.ex`
- Modify: `test/cympho/recovery_test.exs`

**Interfaces:**
- Add internal `Recovery.claim_next_due_case/2` returning `{:ok, lease_or_escalation} | :none | {:error, term()}`.
- `Recovery.process_due/1` retains its public aggregate map.
- `claim_case/2` and `claim_due_case/2` retain their public return shapes.

- [ ] **Step 1: Write failing concurrency tests**

Using two separately checked-out SQL sandbox connections and a barrier, create at least three due cases. Assert two workers each reserve a different first row and insert exactly one claimed attempt per returned case. Hold the oldest row lock in one connection and assert another worker skips it without blocking and claims the next row.

Add a batch test with an escalation callback failure and `limit: 3`; assert the failed row is visited once and later due rows still process.

- [ ] **Step 2: Run RED tests**

```bash
TEST_DB_NAME=cympho_l3b_due_red MIX_BUILD_PATH=_build/l3b_due_red MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test test/cympho/recovery_test.exs --max-cases 1 --seed 12345
```

Expected: both workers select the same first page/row or the locked row blocks later work.

- [ ] **Step 3: Extract locked-claim state transition**

Refactor the current `claim_case/2` transaction body into a private function accepting an already locked `%RecoveryCase{}`. It must close expired attempts, enforce the persisted policy, insert the new attempt/token, or return a typed escalation item without publishing or mutating a source.

- [ ] **Step 4: Implement one-row `SKIP LOCKED` reservation loop**

Each loop iteration selects one due row, excluding the current pass's visited IDs, and completes its claim/escalation state transition before committing. Process the returned lease outside the transaction, add the ID to the visited set for every outcome, and stop after the bounded limit or `:none`.

Validate the exact source guard before escalation of expired-final/exhausted rows. Fresh/mismatched rows become superseded with no approval.

- [ ] **Step 5: Run GREEN tests and commit**

```bash
TEST_DB_NAME=cympho_l3b_due_green MIX_BUILD_PATH=_build/l3b_due_green MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test test/cympho/recovery_test.exs --max-cases 1 --seed 12345
mise x -- mix format --check-formatted
```

```bash
mise x -- git add lib/cympho/recovery.ex test/cympho/recovery_test.exs
mise x -- git commit -m "fix: claim due recovery rows atomically"
```

---

### Task 3: Persist the effective adapter policy across restarts

**Files:**
- Modify: `lib/cympho/recovery.ex`
- Modify: `test/cympho/recovery_test.exs`

**Interfaces:**
- `with_attempt/3` normalizes one effective policy and merges all values into map sources before `ensure_case/1`.
- Run/checkout adapter options accept policy either at the outer level or under `:recovery_opts`; conflicting duplicates return `{:error, :invalid_policy}`.
- Claims never override an existing case policy; explicit conflicting values return `{:error, :invalid_policy}`.

- [ ] **Step 1: Write failing restart-policy tests**

For both run and checkout adapters, pass:

```elixir
recovery_opts: [max_attempts: 3, base_delay: 7, max_delay: 9, lease_seconds: 11]
```

After the first scheduled failure, reload the case and assert `policy_snapshot` stores `3/7/9/11`. Simulate restart by calling `claim_due_case/2` at `next_attempt_at` without policy overrides, assert the lease expires 11 seconds after claim, then record a second failure and assert the next delay is 9 seconds (exponential 14 capped at 9). Assert retry children inherit the same complete snapshot.

Add invalid/conflicting policy tests and confirm no case/attempt is inserted.

- [ ] **Step 2: Run RED tests**

```bash
TEST_DB_NAME=cympho_l3b_policy_red MIX_BUILD_PATH=_build/l3b_policy_red MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test test/cympho/recovery_test.exs --max-cases 1 --seed 12345
```

Expected: source rows contain default `60/600/300` despite current-call overrides.

- [ ] **Step 3: Implement immutable effective-policy propagation**

Normalize outer/nested inputs once, attach `max_attempts`, `base_delay`, `max_delay`, and `lease_seconds` to new source attrs, and persist the resulting snapshot in `ensure_case/1`. Treat an empty/incomplete legacy snapshot as invalid for mutation or normalize it once to the case's bounded defaults. Do not allow later calls to widen or replace an active case's snapshot.

- [ ] **Step 4: Run GREEN tests and commit**

```bash
TEST_DB_NAME=cympho_l3b_policy_green MIX_BUILD_PATH=_build/l3b_policy_green MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test test/cympho/recovery_test.exs --max-cases 1 --seed 12345
mise x -- mix format --check-formatted
```

```bash
mise x -- git add lib/cympho/recovery.ex test/cympho/recovery_test.exs
mise x -- git commit -m "fix: persist effective recovery policy"
```

---

### Task 4: Resolve recovery approvals transactionally

**Files:**
- Create: `priv/repo/migrations/20260903000002_add_recovery_resolution_note.exs`
- Modify: `lib/cympho/recovery/recovery_case.ex`
- Modify: `lib/cympho/recovery.ex`
- Modify: `lib/cympho/board_approvals.ex`
- Modify: `lib/cympho/board_approvals/board_approval_action_executor.ex`
- Modify: `test/cympho/board_approvals/recovery_action_test.exs`
- Modify: `test/cympho/board_approvals/transition_race_test.exs`
- Modify: `test/cympho/board_approvals/execution_claim_test.exs`

**Interfaces:**
- Add bounded nullable `RecoveryCase.resolution_note`.
- Add internal `Recovery.resolve_approval_case_locked/2`, which expects a locked persisted recovery approval and performs DB mutation only.
- Keep `Recovery.handle_approval_resolution/1` as an idempotent standalone reconciliation wrapper.
- `BoardApprovals.reconcile_recovery_resolutions/1` accepts `limit:` (default 100) and queries only terminal approvals whose linked case is still active.

- [ ] **Step 1: Write failing transaction tests**

For `resolve_board_approval(..., "denied", ...)`, `cancel_board_approval/2`, explicit late approval, and `check_expired_approvals/0`, assert the approval status and case `resolved` state are visible together after return and the issue remains blocked.

Create a deliberately cross-tenant linked case through direct SQL, then resolve its pending recovery approval. The transaction-only helper must return a scope error after the approval row is locked; assert the approval status and case state both roll back and no approval/OwnerAttention message is received.

Subscribe to company approval/OwnerAttention topics and assert emitted recovery event contains `%RecoveryCase{state: "resolved"}`. Re-run bounded reconciliation twice and assert the second run changes/publishes nothing.

- [ ] **Step 2: Run RED tests**

```bash
TEST_DB_NAME=cympho_l3b_resolution_red MIX_BUILD_PATH=_build/l3b_resolution_red MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test test/cympho/board_approvals/recovery_action_test.exs test/cympho/board_approvals/transition_race_test.exs test/cympho/board_approvals/execution_claim_test.exs --max-cases 1 --seed 12345
```

Expected: approval status commits before the linked case and events contain the pre-update case.

- [ ] **Step 3: Add resolution note and transaction-only mutation**

Create the migration/schema validation with a 1,000-character maximum. The transaction-only helper must validate category/FK/company/status, lock the linked active case, update it to `resolved`, clear lease/schedule fields, persist the bounded human reason, and return `:unchanged` or an effect descriptor containing the reloaded resolved case.

- [ ] **Step 4: Compose BoardApprovals transitions**

Call the helper inside the same existing Repo transaction for denial, cancellation, and expiry. Return its descriptor and publish audit, system/company approval events, recovery event, and OwnerAttention only after the outer transaction succeeds. Remove post-commit second mutations. Keep bounded startup reconciliation for legacy/crash-window rows and make it query only unresolved active links.

- [ ] **Step 5: Run GREEN tests and commit**

```bash
TEST_DB_NAME=cympho_l3b_resolution_green MIX_BUILD_PATH=_build/l3b_resolution_green MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test test/cympho/board_approvals/recovery_action_test.exs test/cympho/board_approvals/transition_race_test.exs test/cympho/board_approvals/execution_claim_test.exs --max-cases 1 --seed 12345
mise x -- mix format --check-formatted
```

```bash
mise x -- git add priv/repo/migrations/20260903000002_add_recovery_resolution_note.exs lib/cympho/recovery/recovery_case.ex lib/cympho/recovery.ex lib/cympho/board_approvals.ex lib/cympho/board_approvals/board_approval_action_executor.ex test/cympho/board_approvals/recovery_action_test.exs test/cympho/board_approvals/transition_race_test.exs test/cympho/board_approvals/execution_claim_test.exs
mise x -- git commit -m "fix: resolve recovery approvals atomically"
```

---

### Task 5: Order crash cleanup and deduplicate Operations recovery

**Files:**
- Modify: `lib/cympho/orchestrator/dispatcher.ex`
- Modify: `lib/cympho/recovery.ex`
- Modify: `lib/cympho/runtime_operations.ex`
- Modify: `lib/cympho_web/live/operations_live/index.ex`
- Modify: `test/cympho/orchestrator/dispatcher_test.exs`
- Modify: `test/cympho/recovery_test.exs`
- Modify: `test/cympho_web/live/operations_live_test.exs`

**Interfaces:**
- Remove the unused `allow_unbound_active_runs` recovery option.
- Add internal `Recovery.recover_unbound_checkout_after_run/2 :: :ok | {:error, term()}`.
- Preserve Dispatcher and Operations public aggregate/result shapes.

- [ ] **Step 1: Write failing crash-order tests**

Create an `in_progress`, unbound checkout and one pre-crash active run with no live owner. Trigger the Dispatcher crash cleanup path and assert the run is recovered first, then exactly one checkout recovery case clears the issue to `todo`. Make the run recovery transiently schedule, assert the checkout stays locked, then process the run due and assert conservative follow-up clears it.

Bind a successor between run recovery and checkout follow-up and assert the successor binding/status survives.

For Operations, create one old pending run returned by both orphan and waiting scopes; assert the aggregate counts it once and creates one recovery case/attempt.

- [ ] **Step 2: Run RED tests**

```bash
TEST_DB_NAME=cympho_l3b_crash_red MIX_BUILD_PATH=_build/l3b_crash_red MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test test/cympho/orchestrator/dispatcher_test.exs test/cympho/recovery_test.exs test/cympho_web/live/operations_live_test.exs --max-cases 1 --seed 12345
```

Expected: the ignored option leaves the unbound checkout `in_progress` or Operations double-counts the run.

- [ ] **Step 3: Reorder and follow through crash recovery**

Snapshot exact pre-crash runs, recover them through Recovery, then re-read the issue and release an unbound checkout only when no active run/live owner exists. After a successful due run recovery, invoke the same conservative follow-up so a transient initial run recovery does not wait for the age threshold. Do not treat an active run as ignorable; a new active/successor run always wins.

- [ ] **Step 4: Deduplicate Operations run sets**

Build a `MapSet` of orphan run IDs and exclude them from the waiting-run pass before mutation/aggregation. Continue routing every source through Recovery and retain existing user-facing result fields.

- [ ] **Step 5: Run GREEN tests and commit**

```bash
TEST_DB_NAME=cympho_l3b_crash_green MIX_BUILD_PATH=_build/l3b_crash_green MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test test/cympho/orchestrator/dispatcher_test.exs test/cympho/recovery_test.exs test/cympho_web/live/operations_live_test.exs --max-cases 1 --seed 12345
mise x -- mix format --check-formatted
```

```bash
mise x -- git add lib/cympho/orchestrator/dispatcher.ex lib/cympho/recovery.ex lib/cympho/runtime_operations.ex lib/cympho_web/live/operations_live/index.ex test/cympho/orchestrator/dispatcher_test.exs test/cympho/recovery_test.exs test/cympho_web/live/operations_live_test.exs
mise x -- git commit -m "fix: order stranded checkout recovery safely"
```

---

### Task 6: Update evidence and run final gates

**Files:**
- Modify: `paperclip_gap.md`
- Modify: `docs/OPERATIONS.md`
- Create/update: `.superpowers/sdd/2026-09-03-l3b-residual-durability-remediation/task-6-report.md`

- [ ] **Step 1: Update documentation precisely**

Document fingerprint version 2 liveness tokens, atomic one-row due claims, transactional resolution, immutable policy snapshots, and ordered crash cleanup. Retain the explicit dispatch/wake, cluster-fencing, PubSub-outbox, low-resource, and Paperclip-parity residuals.

- [ ] **Step 2: Run focused suites**

```bash
TEST_DB_NAME=cympho_l3b_remediation_focused MIX_BUILD_PATH=_build/l3b_remediation_focused MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test --max-cases 1 --seed 12345 test/cympho/recovery/fingerprint_test.exs test/cympho/recovery_test.exs test/cympho/board_approvals/recovery_action_test.exs test/cympho/board_approvals/transition_race_test.exs test/cympho/board_approvals/execution_claim_test.exs test/cympho/heartbeat_engine/watchdog_test.exs test/cympho/orchestrator/dispatcher_test.exs test/cympho_web/live/operations_live_test.exs test/cympho/owner_attention_test.exs
```

Require exact `N tests, 0 failures`.

- [ ] **Step 3: Run static and credential gates**

```bash
mise x -- mix format --check-formatted
mise x -- bash -n deploy.sh install.sh test/shell/*.sh
git diff --check
```

Snapshot every changed/untracked path preserving its relative path and run:

```bash
/opt/homebrew/bin/gitleaks dir --no-banner --redact --exit-code 1 "$SNAPSHOT_DIR"
```

Require `no leaks found`.

- [ ] **Step 4: Run a fresh complete serial suite**

```bash
run_id=$(date +%Y%m%d%H%M%S)-$RANDOM
name=$(printf '%s' "$run_id" | tr -c '[:alnum:]' '_')
TEST_DB_NAME="cympho_l3b_remediation_full_${name}" MIX_BUILD_PATH="_build/l3b_remediation_full_${name}" MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test --max-cases 1 --seed 12345
```

Retain the log and require the exact zero-failure summary.

- [ ] **Step 5: Browser decision and commit**

If Task 5 changes rendered UI text/layout, smoke `/operations` with Ego Lite only, do not wipe sessions/cookies, and close the Ego Lite task space. If no rendered behavior changed, record that browser smoke was not necessary.

```bash
mise x -- git add paperclip_gap.md docs/OPERATIONS.md .superpowers/sdd/2026-09-03-l3b-residual-durability-remediation/task-6-report.md
mise x -- git commit -m "docs: record L3b durability remediation"
```

Do not mark the overarching Paperclip-parity goal complete; this closes only the documented L3b residual safety pass.
