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
