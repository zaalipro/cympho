# Task 6 verification report — durable stranded-work recovery

Date: 2026-09-03 (Asia/Tbilisi)
Tree at start: `4894db0`

## Documentation changes

- `paperclip_gap.md`: L3b now reads **foundation delivered; dispatch/wake retry residual open**. It links the migration, recovery context/schemas, dispatcher/watchdog integration, and focused suites; records both source types (`heartbeat_run`, `issue_checkout`), default bounded policy, board escalation semantics, tenant/fail-closed and bounded-data guarantees, and explicitly does not claim Paperclip/low-resource/restart parity.
- `docs/OPERATIONS.md`: added the durable stranded-work recovery/escalation procedure, including source and lease model, default 3-attempt/60-120-second policy, Board/Owner Decisions review, approved Retry versus denial/expiry/cancellation behavior, health checks, dispatch/wake residual handling, and no-direct-table-mutation guidance.

## Verification commands and results

### Focused recovery suites

Command (with a dedicated DB/build path and the requested compiler warning setting):

```bash
TEST_DB_NAME=cympho_l3b_focused MIX_BUILD_PATH=_build/l3b_focused MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test --max-cases 1 --seed 12345 test/cympho/recovery/fingerprint_test.exs test/cympho/recovery_test.exs test/cympho/board_approvals/recovery_action_test.exs test/cympho/heartbeat_engine/watchdog_test.exs test/cympho/orchestrator/dispatcher_test.exs test/cympho/owner_attention_test.exs
```

Log: `.superpowers/sdd/2026-09-02-l3b-durable-stranded-work-recovery/logs/focused.log`

Exact summary: `Finished in 12.1 seconds (1.7s async, 10.4s sync)` and `115 tests, 0 failures` (exit 0).

### Formatting, shell syntax, and diff whitespace

Command log: `.superpowers/sdd/2026-09-02-l3b-durable-stranded-work-recovery/logs/static.log`

```text
$ mise x -- mix format --check-formatted
$ mise x -- bash -n deploy.sh install.sh test/shell/*.sh
$ git diff --check
```

All three commands exited 0 with no diagnostics.

### Complete serial suite (superseded historical attempt)

Command (dedicated random DB/build name, serial cases, fixed seed):

```bash
run_id=20260903040841-11584
name=20260903040841_11584
TEST_DB_NAME="cympho_l3b_full_${name}" MIX_BUILD_PATH="_build/l3b_full_${name}" MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test --max-cases 1 --seed 12345
```

Log: `.superpowers/sdd/2026-09-02-l3b-durable-stranded-work-recovery/logs/full-20260903040841_11584.log`

Exact summary: `Finished in 183.4 seconds (66.4s async, 116.9s sync)` and `4427 tests, 1 failure` (exit 2), therefore the required `N tests, 0 failures` gate was not met. The sole failure was:

```text
test explicit issue stop defers release when only an orphan worker remains
(Cympho.Orchestrator.DispatcherDbTest)
test/cympho/orchestrator/dispatcher_test.exs:785
Expected false or nil, got true
code: refute MapSet.member?(Dispatcher.state().running_issue_ids, issue.id)
```

The focused recovery run (which includes `test/cympho/orchestrator/dispatcher_test.exs`) passed; this full-suite failure occurred only in the complete serial run after unrelated test activity and no production code was changed in this task. This failed invocation is retained as evidence but is superseded by the fresh fix-round-1 serial run below, which is the authoritative current gate.

### Credential snapshot scan

A temporary snapshot copied every path from `git diff --name-only` and
`git ls-files --others --exclude-standard` while preserving relative paths. The
required command was run against that snapshot:

```bash
/opt/homebrew/bin/gitleaks dir --no-banner --redact --exit-code 1 "$SNAPSHOT_DIR"
```

Log: `.superpowers/sdd/2026-09-02-l3b-durable-stranded-work-recovery/logs/gitleaks.log`

Exact output:

```text
4:14AM INF scanned ~76034 bytes (76.03 KB) in 59.9ms
4:14AM INF no leaks found
GITLEAKS_EXIT=0
```

Credential scan passed.

## Residual limitations / concerns

- L3b is a durable recovery foundation only. Dispatch/wake retry lineage and broad restart evidence remain open; an approved retry must be observed through scheduling and dispatch, and operators should follow the documented residual procedure if it does not wake.
- The initial 4427-tests/1-failure invocation is a retained, superseded historical attempt. The authoritative current serial gate is the fresh fix-round-1 run below (`4427 tests, 0 failures`, exit 0); no tests or production files were altered to hide or fix the historical failure.
- No claim is made for Paperclip feature parity, low-resource performance parity, crash-proof containment, or restart guarantees beyond the focused source/tests and persisted recovery contracts.

## Fix round 1 (review findings)

### Wording correction

Corrected the L3b roadmap wording so unchanged sources are explicitly
**deduplicated as a no-op**; only stale or mismatched sources are superseded.

### Isolated dispatcher reproduction

Command:

```bash
TEST_DB_NAME=cympho_l3b_dispatch_iso MIX_BUILD_PATH=_build/l3b_dispatch_iso MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test test/cympho/orchestrator/dispatcher_test.exs:785 --max-cases 1 --seed 12345
```

Log: `.superpowers/sdd/2026-09-02-l3b-durable-stranded-work-recovery/logs/dispatcher-785-isolated-round1.log`

Exact summary: `Finished in 1.0 seconds (0.00s async, 1.0s sync)` and
`2 tests, 0 failures (46 excluded)` (exit 0). The orphan-worker cleanup test
passes in isolation.

### Fresh complete serial suite

Command:

```bash
run_id=20260903042031-8594
name=20260903042031_8594
TEST_DB_NAME="cympho_l3b_full_${name}" MIX_BUILD_PATH="_build/l3b_full_${name}" MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' mise x -- mix test --max-cases 1 --seed 12345
```

Log: `.superpowers/sdd/2026-09-02-l3b-durable-stranded-work-recovery/logs/full-round1-20260903042031_8594.log`

Exact summary: `Finished in 182.7 seconds (66.5s async, 116.2s sync)` and
`4427 tests, 0 failures` (exit 0). The complete serial gate now passes. The
prior failure was a non-deterministic/full-suite interaction; no L3b production
change was implicated, and no production or test files were changed in this
fix round.

### Fix-round checks

Log: `.superpowers/sdd/2026-09-02-l3b-durable-stranded-work-recovery/logs/static-round1.log`

```text
$ mise x -- mix format --check-formatted
$ mise x -- bash -n deploy.sh install.sh test/shell/*.sh
$ git diff --check
```

All three commands exited 0 with no diagnostics.

The final changed-file snapshot credential scan used:
`.superpowers/sdd/2026-09-02-l3b-durable-stranded-work-recovery/logs/gitleaks-round1.log`.
The snapshot contained `task-6-report.md` and `paperclip_gap.md`; exact scanner
output was `scanned ~60061 bytes (60.06 KB)` followed by `no leaks found`
(exit 0).

## Fix round 2 (report chronology clarification)

The initial complete-suite failure is now explicitly labeled a **superseded
historical attempt**. The fresh fix-round-1 serial run (`4427 tests, 0
failures`, exit 0) is identified as the authoritative current gate; the failed
run's evidence remains preserved above.

Checks run after this clarification (log:
`.superpowers/sdd/2026-09-02-l3b-durable-stranded-work-recovery/logs/static-round2.log`):

```text
$ mise x -- mix format --check-formatted
$ git diff --check
```

Both commands exited 0 with no diagnostics.
