# Task 4 report: route watchdog recovery through durable cases

## Files changed

- `lib/cympho/heartbeat_engine/watchdog.ex`
  - Stale and orphaned run scans now call `Cympho.Recovery` and handle `:recovered`, `:superseded`, `:scheduled`, and `:exhausted` outcomes explicitly.
  - Re-wake/restart heartbeat only for `:recovered` outcomes.
  - Added durable counters `recovery_cases_created`, `recovery_attempts`, and `recovery_exhausted` to watchdog results while preserving existing keys.
  - Includes stale-checkout exhaustion in watchdog exhaustion telemetry.
- `lib/cympho/orchestrator/dispatcher.ex`
  - Crash-session orphan recovery now routes through `Cympho.Recovery`, with benign superseded and deferred scheduled/exhausted outcomes.
  - Existing stale checkout/orphaned issue adapters remain routed through `Cympho.Recovery`; aggregate helpers now expose `exhausted` counts alongside their existing counters.
- `test/cympho/heartbeat_engine/watchdog_test.exs`
  - Added scoped stale-run integration coverage for durable case/attempt counters and a Watchdog-then-Dispatcher duplicate-scan assertion.

## Verification

Command:

```bash
ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' TEST_DB_NAME=cympho_recovery_integration_green MIX_BUILD_PATH=_build/recovery_integration_green MIX_ENV=test mise x -- mix test test/cympho/heartbeat_engine/watchdog_test.exs test/cympho/orchestrator/dispatcher_test.exs --max-cases 1
```

Output: `59 tests, 0 failures` (10.6s).

Watchdog-only focused run: `11 tests, 0 failures`.

`git diff --check` passed.

## Concerns

Legacy unscoped heartbeat runs (no `company_id`) cannot create durable recovery cases because `recovery_cases.company_id` is required. To retain pre-existing unscoped watchdog/dispatcher behavior, these rows use the prior direct HeartbeatEngine terminalization only after Recovery returns `:company_scope_required`; all tenant-scoped rows remain fail-closed and durable.

## Critical fix round

Removed all direct `HeartbeatEngine` fallback mutations for unscoped or mismatched-company run rows. Recovery scope failures now log and skip without source mutation or heartbeat wake. Added focused tests proving unscoped and corrupted cross-tenant rows remain pending and produce no durable case.

Verification command:

```bash
ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' TEST_DB_NAME=cympho_recovery_integration_green MIX_BUILD_PATH=_build/recovery_integration_green MIX_ENV=test mise x -- mix test test/cympho/heartbeat_engine/watchdog_test.exs --max-cases 1
```

Output: `12 tests, 0 failures`.

Full integration command after the critical fix:

```bash
ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' TEST_DB_NAME=cympho_recovery_integration_green MIX_BUILD_PATH=_build/recovery_integration_green MIX_ENV=test mise x -- mix test test/cympho/heartbeat_engine/watchdog_test.exs test/cympho/orchestrator/dispatcher_test.exs --max-cases 1
```

Output: `60 tests, 0 failures` (10.3s).

## Important telemetry fix round

Watchdog now consumes internal telemetry tuples from both Dispatcher checkout scanners:
`recover_orphaned_in_progress_with_telemetry/0` and
`recover_stale_checkouts_with_telemetry/0`. Public zero-arity helpers retain their
legacy aggregate maps; telemetry is returned separately and is summed exactly once
by Watchdog. Durable case source keys are tracked race-safely to avoid counting a
second case for duplicate scans. Added checkout integration coverage asserting one
case/attempt after Watchdog and no increment after Dispatcher duplicate scans.

Verification:

```bash
ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' TEST_DB_NAME=cympho_recovery_integration_green MIX_BUILD_PATH=_build/recovery_integration_green MIX_ENV=test mise x -- mix test test/cympho/heartbeat_engine/watchdog_test.exs test/cympho/orchestrator/dispatcher_test.exs --max-cases 1
```

Output: `61 tests, 0 failures` (10.3s).
