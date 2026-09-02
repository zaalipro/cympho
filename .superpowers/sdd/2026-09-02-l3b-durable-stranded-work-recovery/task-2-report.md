# Task 2 Report — Durable recovery fingerprints and lifecycle

## Scope
Implemented canonical source fingerprints and the durable recovery case/lease lifecycle facade on top of the Task 1 schemas.

## TDD evidence
- **RED:** Initial focused run was attempted before production implementation; the requested facade/fingerprint modules were undefined. The default test build also hit the repository's OTP 28/29 `meck` deprecation compile issue.
- **GREEN:** After implementation, focused lifecycle/fingerprint suites pass with `ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]'`:
  `MIX_ENV=test mix test test/cympho/recovery/fingerprint_test.exs test/cympho/recovery_test.exs --max-cases 1`
  Result: **10 tests, 0 failures**.
- Changed files were formatted and syntax/compilation checks completed (`mix format --check-formatted`, `mix compile`).

## Implementation
- `lib/cympho/recovery/fingerprint.ex`
  - Versioned canonical snapshots for heartbeat runs and issue checkouts.
  - Sorted-key JSON encoding through `Jason.OrderedObject`, SHA-256 lowercase hashes.
  - Bounded error-family classification and redacted snapshots (no prompts/credentials/timestamps except checkout time truncated to seconds).
- `lib/cympho/recovery.ex`
  - Company/issue/run tenant validation and source-type allow-list.
  - Transactional active-case deduplication, superseding and root/child lineage creation.
  - Lease claim with expiry takeover, attempt row insertion and bounded attempt count.
  - Token-guarded success, superseded and failure recording with deterministic 60/120 second backoff and exhaustion state.
  - `with_attempt/3` callback orchestration returning result, outcome and updated case; callback is not invoked when claim is unavailable.
- Tests cover stable/redacted fingerprints, deduplication, lease contention, failure scheduling, changed lock-version lineage, and nil company rejection.

## Concerns
- The repository's stock test command requires `ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]'` on this OTP toolchain because `meck` emits a deprecated catch warning treated as an error.
- Board escalation, issue blocking, scanner integration and approval execution remain Task 3 scope.

## Review fix round 1
Addressed reviewer findings in commit `6adffbd` (plus test adjustment): callback exceptions/exits now finalize failed attempts; mutable checkout timestamps were removed from fingerprints; error persistence is bounded to safe families; retry delay is configurable/deterministic with cap; atom/string-key source maps are supported; result updates validate case/attempt/token and unexpired leases. Focused suites now report 12 passing tests.

## Review fix round 2
Commit `ca43931` hardens callback result normalization, custom retry delay/cap handling, string-key source maps, malformed run validation, strict affected-attempt checks, and lease expiry guards. Focused suites: 12 passing tests.

## Review fix round 3
Hardened completion CAS to require exactly one matching claimed attempt before transitioning a case, and validated heartbeat source maps (atom/string keys, required IDs/status and tenant linkage) with structured errors. Command: `ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' MIX_ENV=test mix test test/cympho/recovery/fingerprint_test.exs test/cympho/recovery_test.exs --max-cases 1`; output: **12 tests, 0 failures**. Formatting check passes.

## Review fix round 4
Added focused regression coverage for round-3 CAS hardening and malformed heartbeat source validation, plus round-2 callback normalization and deterministic retry delay/cap behavior.

- `test/cympho/recovery_test.exs`
  - forged token, mismatched case, nonexistent attempt, and mismatched attempt-number completions are rejected by both `record_success/2` and `record_superseded/2`; durable case/attempt rows remain claimed/unchanged;
  - callback return normalization covers `{:ok, value}`, bare values, and `{:error, :superseded}`;
  - retry delay assertions use explicit timestamps and verify the configured cap on the second attempt;
  - atom- and string-key heartbeat run maps with missing/empty required fields return stable structured errors and do not insert rows.
- `lib/cympho/recovery.ex`
  - fixed `attrs_issue_id/1` to safely read issue IDs from Ecto structs and maps; malformed run validation no longer raises `UndefinedFunctionError` when the issue is a struct.

Focused command:
`ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' MIX_ENV=test mise x -- mix test test/cympho/recovery_test.exs test/cympho/recovery/fingerprint_test.exs --max-cases 1`

Result: **16 tests, 0 failures**.
Formatting: `mise x -- mix format test/cympho/recovery_test.exs lib/cympho/recovery.ex`.
