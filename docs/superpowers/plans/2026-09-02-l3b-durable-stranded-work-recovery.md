# L3b Durable Stranded-Work Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist and bound recovery of stale/orphan heartbeat runs and stranded issue checkouts, escalating exhausted recovery to one auditable board decision instead of retrying forever.

**Architecture:** Add a company-scoped `Cympho.Recovery` context backed by normalized `recovery_cases` and `recovery_attempts` tables. A lease/CAS workflow wraps the existing HeartbeatEngine and Issues recovery primitives; Dispatcher and Watchdog share the facade. Exhaustion blocks the issue and creates one `stranded_work_recovery` board approval whose only automatic action is an explicitly approved retry.

**Tech Stack:** Elixir/Phoenix, Ecto/PostgreSQL, UUID keys, `utc_datetime` timestamps, Phoenix PubSub, existing `HeartbeatEngine`, `Issues`, `BoardApprovals`, `OwnerAttention`, and ExUnit `DataCase` tests.

**Spec:** `docs/superpowers/specs/2026-09-02-l3b-durable-stranded-work-recovery-design.md`

## Global Constraints

- Keep all recovery rows company-scoped; nil or mismatched company IDs fail closed and never guess a tenant.
- Use existing exact source CAS helpers; never clear a successor checkout or terminalize a newer run.
- Automatic recovery is limited to `heartbeat_run` and `issue_checkout` sources in this tranche; dispatch-failure and wake-delivery lineage remain unchanged.
- Default policy is one immediate automatic attempt followed by bounded 60/120-second retry delays (three attempts total) and a ten-minute cap; tests may inject shorter delays through options.
- Exhaustion transitions a non-terminal issue to `:blocked`, preserves its assignee, and creates one pending board approval with action `retry`.
- Denied, expired, or cancelled recovery approval leaves the issue blocked; only approved `retry` reopens it to `:todo`.
- Proposal data and logs contain IDs, statuses, fingerprints, and bounded error families only; never provider credentials, prompts, or full logs.
- Every new behavior gets a focused regression test before implementation and the full serial suite remains the final gate.

## File Map

- Create `priv/repo/migrations/20260903000000_create_recovery_cases.exs`: recovery case/attempt tables, checks, indexes, and the board-approval foreign key.
- Create `lib/cympho/recovery/recovery_case.ex`: Ecto schema and state/field validations.
- Create `lib/cympho/recovery/recovery_attempt.ex`: append-only attempt schema and validations.
- Create `lib/cympho/recovery/fingerprint.ex`: deterministic versioned source snapshots and SHA-256 fingerprints.
- Create `lib/cympho/recovery.ex`: tenant validation, case deduplication, leases, result recording, exhaustion, and board retry API.
- Modify `lib/cympho/board_approvals/board_approval.ex`: recovery category, `recovery_case_id` association, and changeset casting.
- Modify `lib/cympho/board_approvals.ex`: recovery approval insertion/resolution notifications and dispatch branch.
- Modify `lib/cympho/board_approvals/board_approval_action_executor.ex`: route recovery approvals to `Cympho.Recovery.apply_board_action/1`.
- Modify `lib/cympho/orchestrator/dispatcher.ex`: route orphan run/checkout/stale-checkout recovery through `Cympho.Recovery` and honor exhausted outcomes.
- Modify `lib/cympho/heartbeat_engine/watchdog.ex`: use the same facade and only re-wake successfully recovered runs.
- Create `test/cympho/recovery/fingerprint_test.exs`: canonical hash and redaction tests.
- Create `test/cympho/recovery_test.exs`: case lifecycle, leases, deduplication, exhaustion, and board retry tests.
- Modify `test/cympho/heartbeat_engine/watchdog_test.exs`: assert durable case creation and no requeue after exhaustion.
- Modify `test/cympho/orchestrator/dispatcher_test.exs`: assert shared recovery facade and successor protection.
- Create `test/cympho/board_approvals/recovery_action_test.exs`: exactly-once proposal/action and denial behavior.
- Modify `paperclip_gap.md`: record the delivered L3b foundation and its explicit dispatch/wake residual.

---

### Task 1: Add durable recovery tables and schemas

**Files:**
- Create: `priv/repo/migrations/20260903000000_create_recovery_cases.exs`
- Create: `lib/cympho/recovery/recovery_case.ex`
- Create: `lib/cympho/recovery/recovery_attempt.ex`
- Modify: `lib/cympho/board_approvals/board_approval.ex`
- Test: `test/cympho/recovery_test.exs`

**Interfaces:**
- Produces `%Cympho.Recovery.RecoveryCase{}` with `has_many :attempts` and `has_one :board_approval`.
- Produces `%Cympho.Recovery.RecoveryAttempt{}` with `belongs_to :recovery_case`.
- Adds nullable `BoardApproval.recovery_case_id` and category `"stranded_work_recovery"`.
- Exposes `RecoveryCase.active_states/0`, `states/0`, `source_types/0`, and `RecoveryAttempt.statuses/0`.

- [ ] **Step 1: Write failing schema tests**

Add tests that insert a company, issue, and recovery case and assert:

```elixir
assert {:ok, case_row} = RecoveryCase.changeset(%RecoveryCase{}, attrs) |> Repo.insert()
assert case_row.state == "detected"
assert case_row.company_id == company.id
assert {:error, changeset} = RecoveryCase.changeset(%RecoveryCase{}, %{state: "bogus"}) |> Repo.insert()
assert "is invalid" in errors_on(changeset).state
```

Also assert a second active row with the same `(company_id, source_type, source_id)` raises the named unique constraint, while a `superseded` row is allowed.

- [ ] **Step 2: Run the schema tests to verify the expected failure**

Run:

```bash
TEST_DB_NAME=cympho_recovery_schema_red MIX_BUILD_PATH=_build/recovery_schema_red MIX_ENV=test mise x -- mix test test/cympho/recovery_test.exs --max-cases 1
```

Expected: compilation fails because the recovery schemas and migration do not yet exist.

- [ ] **Step 3: Implement the migration**

Create `recovery_cases` with UUID primary key, required `company_id` and `issue_id`, nullable `agent_id`, `source_run_id`, `parent_case_id`, and `root_case_id`, string `source_type/source_id/source_status`, `source_fingerprint`, integer `fingerprint_version`, map `source_snapshot`, state/policy/lease/error/timestamp fields, and `attempt_count`/`max_attempts` defaults of `0`/`3`.

Create `recovery_attempts` with UUID primary key, `recovery_case_id` delete-all FK, attempt number, status/action/fingerprint, lease/result timestamps, error text, node, and map metadata. Add unique `(recovery_case_id, attempt_no)`.

Add `recovery_case_id` to `board_approvals` with a nilifying FK and a partial unique index where non-null. Add checks for allowed states, source types, non-negative attempts, positive max attempts, and claimed lease fields.

Add indexes:

```elixir
create index(:recovery_cases, [:company_id, :state, :next_attempt_at])
create index(:recovery_cases, [:state, :lease_expires_at])
create index(:recovery_cases, [:issue_id, :state])
create index(:recovery_cases, [:root_case_id])
create unique_index(:recovery_cases, [:company_id, :source_type, :source_id],
  where: "state IN ('detected','scheduled','claimed','exhausted','escalated')",
  name: :recovery_cases_active_source_index)
create unique_index(:board_approvals, [:recovery_case_id],
  where: "recovery_case_id IS NOT NULL",
  name: :board_approvals_recovery_case_index)
```

- [ ] **Step 4: Implement schemas and changesets**

Use `@foreign_key_type :binary_id`, `timestamps(type: :utc_datetime)`, explicit inclusion lists, `validate_number` for attempts, and `foreign_key_constraint` for every association. `RecoveryCase.changeset/2` must cast all persisted fields but reject caller-supplied lease/result timestamps from ordinary creation. `BoardApproval.changeset/2` must cast `:recovery_case_id` and accept the new category.

- [ ] **Step 5: Run the schema tests and migration checks**

Run:

```bash
TEST_DB_NAME=cympho_recovery_schema_green MIX_BUILD_PATH=_build/recovery_schema_green MIX_ENV=test mise x -- mix test test/cympho/recovery_test.exs --max-cases 1
```

Expected: schema/constraint tests pass.

- [ ] **Step 6: Commit the schema task**

```bash
mise x -- git add priv/repo/migrations/20260903000000_create_recovery_cases.exs lib/cympho/recovery/recovery_case.ex lib/cympho/recovery/recovery_attempt.ex lib/cympho/board_approvals/board_approval.ex test/cympho/recovery_test.exs
mise x -- git commit -m "feat: add durable recovery case storage"
```

---

### Task 2: Implement fingerprints and case/lease lifecycle

**Files:**
- Create: `lib/cympho/recovery/fingerprint.ex`
- Create: `lib/cympho/recovery.ex`
- Modify: `test/cympho/recovery_test.exs`
- Create: `test/cympho/recovery/fingerprint_test.exs`

**Interfaces:**
- `Cympho.Recovery.Fingerprint.for_run/2 :: {String.t(), map()}`
- `Cympho.Recovery.Fingerprint.for_issue_checkout/1 :: {String.t(), map()}`
- `Cympho.Recovery.ensure_case/1 :: {:ok, RecoveryCase.t()} | {:error, term()}`
- `Cympho.Recovery.claim_case/2 :: {:ok, %{case: RecoveryCase.t(), attempt: RecoveryAttempt.t(), token: String.t()}} | {:error, atom()}`
- `Cympho.Recovery.record_success/2`, `record_superseded/2`, and `record_failure/3` return `{:ok, RecoveryCase.t()}` or a structured error.
- `Cympho.Recovery.with_attempt/3` accepts a case source and callback and returns `{:ok, result}` / `{:error, reason}` without invoking the callback when a lease is unavailable.

- [ ] **Step 1: Write failing fingerprint and lifecycle tests**

Cover:

```elixir
assert {first_hash, first_snapshot} = Fingerprint.for_issue_checkout(issue)
assert {^first_hash, ^first_snapshot} = Fingerprint.for_issue_checkout(issue)
refute inspect(first_snapshot) =~ "secret"

assert {:ok, first} = Recovery.ensure_case(%{source_type: "issue_checkout", issue: issue})
assert {:ok, same} = Recovery.ensure_case(%{source_type: "issue_checkout", issue: issue})
assert same.id == first.id

assert {:ok, lease} = Recovery.claim_case(first, now: now)
assert {:error, :already_claimed} = Recovery.claim_case(first, now: now)
assert {:ok, _} = Recovery.record_failure(lease, "temporary", now: now)
```

Add a changed `lock_version` case test that marks the first row `superseded` and creates a child with the same `root_case_id`, and a nil/mismatched company test that returns `{:error, :company_scope_required}` without inserting a row.

- [ ] **Step 2: Run the lifecycle tests to verify they fail**

```bash
TEST_DB_NAME=cympho_recovery_lifecycle_red MIX_BUILD_PATH=_build/recovery_lifecycle_red MIX_ENV=test mise x -- mix test test/cympho/recovery/fingerprint_test.exs test/cympho/recovery_test.exs --max-cases 1
```

Expected: modules/functions are undefined.

- [ ] **Step 3: Implement canonical fingerprints**

Build a version-1 map with sorted string keys, encode it through `Jason.encode!/1` after recursively sorting maps, and hash with `:crypto.hash(:sha256, json) |> Base.encode16(case: :lower)`. Include durable IDs/status/lock version/checkout run and a bounded error family; exclude prompt text, credentials, mutable timestamps, and arbitrary metadata. Return both hash and redacted snapshot.

- [ ] **Step 4: Implement `ensure_case/1`**

Validate that the source issue exists, has a non-empty company ID, and that an optional run belongs to the same issue/company. In one `Repo.transaction`, lock the active source row, return it for an identical fingerprint, mark it `superseded` for a changed fingerprint, then insert the new row. Set `root_case_id` to the inserted ID for a root and preserve the prior root for a child. Retry one unique-constraint race by reloading the active row.

- [ ] **Step 5: Implement lease claiming and result recording**

`claim_case/2` locks a due `detected`/`scheduled` case, takes over only an expired `claimed` lease, increments `attempt_count`, writes a UUID token and lease expiry, and inserts the unique attempt row. `record_success/2` and `record_superseded/2` update only matching token/attempt rows. `record_failure/3` marks the attempt failed, schedules deterministic backoff when attempts remain, and returns an `:exhausted` outcome at the cap. All updates use the claim token in the `WHERE` clause.

- [ ] **Step 6: Run lifecycle tests and inspect durable rows**

```bash
TEST_DB_NAME=cympho_recovery_lifecycle_green MIX_BUILD_PATH=_build/recovery_lifecycle_green MIX_ENV=test mise x -- mix test test/cympho/recovery/fingerprint_test.exs test/cympho/recovery_test.exs --max-cases 1
```

Expected: fingerprint, dedup, lease takeover, backoff, and lineage tests pass.

- [ ] **Step 7: Commit the lifecycle task**

```bash
mise x -- git add lib/cympho/recovery/fingerprint.ex lib/cympho/recovery.ex test/cympho/recovery/fingerprint_test.exs test/cympho/recovery_test.exs
mise x -- git commit -m "feat: add durable recovery leases and lineage"
```

---

### Task 3: Add source-specific recovery adapters

**Files:**
- Modify: `lib/cympho/recovery.ex`
- Modify: `lib/cympho/orchestrator/dispatcher.ex`
- Modify: `test/cympho/recovery_test.exs`
- Modify: `test/cympho/orchestrator/dispatcher_test.exs`

**Interfaces:**
- `Recovery.recover_stale_run/1` and `Recovery.recover_orphaned_run/1` return `{:ok, %{run: Run.t(), outcome: atom(), case: RecoveryCase.t()}}` or `{:error, reason}`.
- `Recovery.recover_orphaned_issue/1` returns `{:ok, %{issue: Issue.t(), outcome: atom(), case: RecoveryCase.t()}}` or `{:error, reason}`.
- `Recovery.recover_stale_checkouts/1` returns `%{checked: n, released: n, failed: n, exhausted: n}`.

- [ ] **Step 1: Write failing adapter tests**

Create stale/orphan runs and old checked-out issues, then assert the adapter creates a case and delegates source mutation only once. Add a race test where the run is completed or the issue binds a successor before the callback; assert the case is `superseded` and the successor remains untouched. Add a callback-failure test using `Recovery.with_attempt/3` options to force three failures and assert `outcome: :exhausted`.

- [ ] **Step 2: Run adapter tests to verify failure**

```bash
TEST_DB_NAME=cympho_recovery_adapter_red MIX_BUILD_PATH=_build/recovery_adapter_red MIX_ENV=test mise x -- mix test test/cympho/recovery_test.exs test/cympho/orchestrator/dispatcher_test.exs --max-cases 1
```

Expected: adapter functions are undefined or direct recovery bypasses the case ledger.

- [ ] **Step 3: Implement run adapters**

Load the issue for company validation, ensure/claim a run case, and call the existing `HeartbeatEngine.recover_stale_run/1` or `recover_orphaned_run/1`. Map `{:error, {:invalid_status, _}}` to `superseded`; map successful terminalization to `recovered`; map transient errors through `record_failure/3`. Never call the callback for `:already_claimed`, future `next_attempt_at`, or terminal case states.

- [ ] **Step 4: Implement issue-checkout adapter**

Move the existing live-orchestrator/adapter-session checks into a private callback in `Recovery`. Recheck liveness immediately before `Workspaces.cancel_and_release_for_issue/2` and immediately before `Issues.clear_checkout_lock/2`. Use the issue lock snapshot and preserve the assignee. A checkout conflict becomes `superseded`, not a broad release.

- [ ] **Step 5: Implement stale-checkout batch adapter**

Query the existing stale checked-out issue scope, pass each row through `recover_orphaned_issue/1`, and aggregate `checked/released/failed/exhausted` without raising on a transient DB error. Duplicate rows encountered by Dispatcher and Watchdog must return a non-mutating case outcome.

- [ ] **Step 6: Run adapter tests and commit**

```bash
TEST_DB_NAME=cympho_recovery_adapter_green MIX_BUILD_PATH=_build/recovery_adapter_green MIX_ENV=test mise x -- mix test test/cympho/recovery_test.exs test/cympho/orchestrator/dispatcher_test.exs --max-cases 1
```

```bash
mise x -- git add lib/cympho/recovery.ex lib/cympho/orchestrator/dispatcher.ex test/cympho/recovery_test.exs test/cympho/orchestrator/dispatcher_test.exs
mise x -- git commit -m "feat: route orphan recovery through durable cases"
```

---

### Task 4: Integrate Watchdog/Dispatcher and durable exhaustion policy

**Files:**
- Modify: `lib/cympho/orchestrator/dispatcher.ex`
- Modify: `lib/cympho/heartbeat_engine/watchdog.ex`
- Modify: `lib/cympho/recovery.ex`
- Modify: `test/cympho/heartbeat_engine/watchdog_test.exs`
- Modify: `test/cympho/orchestrator/dispatcher_test.exs`

**Interfaces:**
- Both scanners call `Cympho.Recovery` for stale/orphan run and checkout sources.
- Watchdog result maps add `recovery_cases_created`, `recovery_attempts`, and `recovery_exhausted` while retaining existing keys.
- Dispatcher recovery helpers retain their existing aggregate return shapes, adding `exhausted` only where a map already exists.

- [ ] **Step 1: Write failing integration tests**

Add tests that run the same stale row through Watchdog then Dispatcher and assert one case/attempt and one source transition. Add a restart-style test that reloads the case and verifies a future `next_attempt_at` is not claimed. Add an exhaustion test that leaves the issue `:blocked`, keeps the assignee, and does not trigger a heartbeat.

- [ ] **Step 2: Run integration tests to verify failure**

```bash
TEST_DB_NAME=cympho_recovery_integration_red MIX_BUILD_PATH=_build/recovery_integration_red MIX_ENV=test mise x -- mix test test/cympho/heartbeat_engine/watchdog_test.exs test/cympho/orchestrator/dispatcher_test.exs --max-cases 1
```

Expected: duplicate direct recovery calls and in-memory retries still occur.

- [ ] **Step 3: Replace direct run recovery calls**

In Dispatcher and Watchdog, handle `Recovery` outcomes explicitly: re-wake only `:recovered`, log `:superseded` as benign, and leave `:scheduled`/`:exhausted` without a wake. Keep existing result counters and include new durable counters.

- [ ] **Step 4: Replace orphaned-checkout direct calls**

Have `recover_orphaned_in_progress/0` and stale-checkout aggregation call the Recovery adapter. Preserve all existing live-session and successor checks; a case claim must be acquired before environment cancellation or checkout clearing.

- [ ] **Step 5: Implement exhaustion transition**

Within the final `record_failure/3` transaction, lock the issue, verify its current fingerprint still matches and its status is non-terminal, update status to `:blocked` with `lock_version` increment, and create the board approval through the changeset insert described in Task 5. If the source changed, mark the case superseded instead. Do not clear assignee or runtime data.

- [ ] **Step 6: Run integration tests and commit**

```bash
TEST_DB_NAME=cympho_recovery_integration_green MIX_BUILD_PATH=_build/recovery_integration_green MIX_ENV=test mise x -- mix test test/cympho/heartbeat_engine/watchdog_test.exs test/cympho/orchestrator/dispatcher_test.exs --max-cases 1
```

```bash
mise x -- git add lib/cympho/orchestrator/dispatcher.ex lib/cympho/heartbeat_engine/watchdog.ex lib/cympho/recovery.ex test/cympho/heartbeat_engine/watchdog_test.exs test/cympho/orchestrator/dispatcher_test.exs
mise x -- git commit -m "feat: bound watchdog recovery and park exhausted work"
```

---

### Task 5: Add exactly-once board escalation and retry action

**Files:**
- Modify: `lib/cympho/board_approvals.ex`
- Modify: `lib/cympho/board_approvals/board_approval_action_executor.ex`
- Create: `test/cympho/board_approvals/recovery_action_test.exs`
- Modify: `test/cympho/owner_attention_test.exs`

**Interfaces:**
- `BoardApprovals.create_recovery_approval/2` inserts a pending approval inside the caller transaction and returns the row; publication/audit occurs after commit.
- `Recovery.apply_board_action/1` accepts an approved recovery approval and returns `:ok`, `{:ok, child_case}`, or `{:error, :stale_recovery_proposal}`.
- `Recovery.handle_approval_resolution/1` marks denied/expired/cancelled cases resolved without reopening the issue.

- [ ] **Step 1: Write failing board-action tests**

Cover:

```elixir
assert {:ok, approval} = Recovery.exhaust_case(case_row, reason: "test")
assert approval.category == "stranded_work_recovery"
assert Repo.aggregate(from(a in BoardApproval, where: a.recovery_case_id == ^case_row.id), :count) == 1

assert :ok = Recovery.handle_approval_resolution(%{approval | status: "denied"})
assert Repo.get!(Issue, issue.id).status == :blocked

approved = %{approval | status: "approved"}
assert :ok = Recovery.apply_board_action(approved)
assert {:error, :stale_recovery_proposal} = Recovery.apply_board_action(approved)
```

Assert OwnerAttention includes one pending board item, notification broadcasts are company-scoped, and a forged case ID/fingerprint cannot reopen another company's issue.

- [ ] **Step 2: Run board tests to verify failure**

```bash
TEST_DB_NAME=cympho_recovery_board_red MIX_BUILD_PATH=_build/recovery_board_red MIX_ENV=test mise x -- mix test test/cympho/board_approvals/recovery_action_test.exs test/cympho/owner_attention_test.exs --max-cases 1
```

Expected: category/association/action functions are missing.

- [ ] **Step 3: Implement transactional escalation**

Add `BoardApprovals.create_recovery_approval/2` as an insert-only helper usable inside an existing `Repo.transaction`; do not call the standalone broadcasting `create_board_approval/2` from the recovery transaction. Store proposal data with `action: "retry"`, case ID, issue/run IDs, fingerprint, attempt count, max attempts, last error, and a bounded restart packet. After the outer transaction commits, log `recovery_exhausted`, broadcast the normal approval events, and call `OwnerAttention.notify_changed/1`.

- [ ] **Step 4: Implement resolution and retry**

On denial/expiration/cancellation, lock the linked case, set `resolved`, and leave the issue blocked. On approved retry, lock the case and issue, verify category/action/company/fingerprint/state, mark the old case resolved, insert a child scheduled case with the same root, transition only a still-blocked matching issue to `:todo`, and dispatch one company poll. A second execution sees the durable `BoardApprovalEffect` or stale case and performs no work.

- [ ] **Step 5: Wire the executor and notifications**

Add the recovery category to `BoardApprovals.dispatch_approved_action/1` and route it through `Recovery.apply_board_action/1` in `BoardApprovalActionExecutor`. Add `OwnerAttention.notify_changed/1` alongside create, resolve, cancel, and recovery-resolution broadcasts; do not add raw diagnostics to Simple-mode item text.

- [ ] **Step 6: Run board tests and commit**

```bash
TEST_DB_NAME=cympho_recovery_board_green MIX_BUILD_PATH=_build/recovery_board_green MIX_ENV=test mise x -- mix test test/cympho/board_approvals/recovery_action_test.exs test/cympho/owner_attention_test.exs --max-cases 1
```

```bash
mise x -- git add lib/cympho/board_approvals.ex lib/cympho/board_approvals/board_approval_action_executor.ex lib/cympho/owner_attention.ex test/cympho/board_approvals/recovery_action_test.exs test/cympho/owner_attention_test.exs
mise x -- git commit -m "feat: escalate exhausted recovery to the board"
```

---

### Task 6: Documentation, full verification, and roadmap update

**Files:**
- Modify: `paperclip_gap.md`
- Modify: `docs/OPERATIONS.md` if operator recovery instructions are absent
- Test: all recovery-focused tests and the full repository suite

- [ ] **Step 1: Update the roadmap honestly**

Mark L3b as “foundation delivered; dispatch/wake retry residual open,” link the new migration/context/tests, and document the default behavior: exhausted work is blocked and needs an explicit Retry approval; denial leaves it blocked.

- [ ] **Step 2: Run focused tests**

```bash
TEST_DB_NAME=cympho_l3b_focused MIX_BUILD_PATH=_build/l3b_focused MIX_ENV=test mise x -- mix test --max-cases 1 --seed 12345 test/cympho/recovery/fingerprint_test.exs test/cympho/recovery_test.exs test/cympho/board_approvals/recovery_action_test.exs test/cympho/heartbeat_engine/watchdog_test.exs test/cympho/orchestrator/dispatcher_test.exs test/cympho/owner_attention_test.exs
```

Expected: all focused recovery tests pass with zero failures.

- [ ] **Step 3: Run formatting, syntax, and static checks**

```bash
mise x -- mix format --check-formatted
mise x -- bash -n deploy.sh install.sh test/shell/*.sh
git diff --check
```

- [ ] **Step 4: Run the complete serial suite**

```bash
run_id=$(date +%Y%m%d%H%M%S)-$RANDOM
name=$(printf '%s' "$run_id" | tr -c '[:alnum:]' '_')
TEST_DB_NAME="cympho_l3b_full_${name}" MIX_BUILD_PATH="_build/l3b_full_${name}" MIX_ENV=test mise x -- mix test --max-cases 1 --seed 12345
```

Require the exact `N tests, 0 failures` summary and retain the log path.

- [ ] **Step 5: Scan changed files for credentials**

Create a temporary directory, copy every path from `git diff --name-only` and `git ls-files --others --exclude-standard` into its matching relative path, then run `/opt/homebrew/bin/gitleaks dir --no-banner --redact --exit-code 1 "$SNAPSHOT_DIR"`. Require `no leaks found`.

- [ ] **Step 6: Request a whole-diff review and commit the roadmap update**

After tests pass, dispatch a fresh reviewer against the current tree, address Critical/Important findings, then:

```bash
mise x -- git add paperclip_gap.md docs/OPERATIONS.md
mise x -- git commit -m "docs: record durable stranded-work recovery"
```

Do not claim full L3b closure, low-resource parity, or Paperclip feature parity until dispatch/wake lineage and the documented exit evidence are delivered.
