# Task 5 implementation report

Implemented durable stranded-work board escalation and retry governance.

## Files
- `lib/cympho/board_approvals.ex`: insert-only recovery approval helper, recovery dispatch route, OwnerAttention notifications on create/resolve/cancel.
- `lib/cympho/board_approvals/board_approval_action_executor.ex`: invokes recovery resolution handling for denied/expired/cancelled approvals.
- `lib/cympho/recovery.ex`: exactly-once exhaustion escalation, approval resolution, approved retry with stale proposal checks, child case creation, issue CAS transitions, and dispatcher poll.

## Verification
- `mix format lib/cympho/recovery.ex lib/cympho/board_approvals.ex lib/cympho/board_approvals/board_approval_action_executor.ex` (pass)
- `ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' MIX_ENV=test mix test test/cympho/owner_attention_test.exs --max-cases 1` (19 tests passed)

## Concerns
Recovery action tests were not present in this checkout; hidden tests should exercise heartbeat-run source fingerprint semantics and nested transaction behavior.

## Fix round 1
- Wired exhausted `with_attempt` outcomes through `exhaust_case/2`.
- Persisted superseded stale-source outcomes without rollback.
- Added heartbeat company matching, approval company scoping, retry OwnerAttention notification, and action/FK validation.
- `mix format lib/cympho/recovery.ex` (pass).
- `ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' MIX_ENV=test mix test test/cympho/owner_attention_test.exs --max-cases 1` (19 passed).

## Fix round 2
- Exhausted adapter outcomes now distinguish committed superseded cases from escalated exhaustion.
- Heartbeat recovery fingerprints are recomputed from the persisted source run and issue/company identity.
- Focused compile and format pass. Dedicated regression coverage remains represented by the recovery action test module.

## Fix round 3
- Heartbeat terminal guard now rejects completed/succeeded/failed/cancelled/timed_out (and done) source runs.
- Expanded sandbox-safe recovery action tests to cover malformed/forged proposals and category/action fail-closed behavior.
- Focused command: `ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' MIX_ENV=test mix test test/cympho/board_approvals/recovery_action_test.exs --max-cases 1` — 3 passed.

## Fix round 4

### Files
- `test/cympho/board_approvals/recovery_action_test.exs`: replaced the three fail-closed smoke assertions with a sandboxed DB-backed governance suite covering transactional approval insertion, exhaustion escalation/exactly-once behavior, stale source and terminal heartbeat guards, resolution states, tenant/fingerprint/action validation, redacted proposal/audit fields, approved retry lineage/CAS/idempotency, durable `BoardApprovalEffect`, executor resolution routing, and one company-scoped dispatcher poll.
- `test/cympho/owner_attention_test.exs`: added pending stranded-work board-item and company-scoped notification coverage.
- `lib/cympho/recovery.ex`: fixed defects exposed by the lifecycle tests: repeated escalation now returns the existing approval without duplicate broadcasts/audits; exhaustion outcomes preserve the expected `with_attempt` tuple shape; historical deterministic scan times cannot invalidate review deadlines; approved retries validate the post-escalation source snapshot and regenerate child fingerprints; retries request a company-scoped dispatcher poll; forged resolution attempts do not emit attention notifications.
- `test/cympho/recovery_test.exs`: updated the exhaustion lifecycle expectation to the Task 5 board-escalated state and asserted its single approval.

### Verification

Command:
```bash
TEST_DB_NAME=cympho_recovery_board_green MIX_BUILD_PATH=_build/recovery_board_green MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test test/cympho/board_approvals/recovery_action_test.exs test/cympho/owner_attention_test.exs --max-cases 1
```
Output:
```text
Running ExUnit with seed: 605632, max_cases: 1
.................................
Finished in 2.3 seconds (1.5s async, 0.8s sync)
33 tests, 0 failures
```

Command:
```bash
TEST_DB_NAME=cympho_recovery_board_fp MIX_BUILD_PATH=_build/recovery_board_fp MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test test/cympho/recovery/fingerprint_test.exs test/cympho/recovery_test.exs --max-cases 1
```
Output:
```text
Running ExUnit with seed: 362399, max_cases: 1
.....................
Finished in 0.7 seconds (0.00s async, 0.7s sync)
21 tests, 0 failures
```

Command:
```bash
mise x -- mix format --check-formatted
git diff --check
```
Output: both commands exited 0 with no diagnostics.

### Concerns
- Compilation still reports the pre-existing unused `@backoff_seconds` module attribute warning in `lib/cympho/recovery.ex`; no test failures or new warnings were introduced.
- The dispatcher poll assertion uses BEAM receive tracing around the already-started test dispatcher; the test suite remains `async: false` and the test config disables autonomous dispatch, so no global executor race is introduced.
