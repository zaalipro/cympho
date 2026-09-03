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

## Final whole-branch hardening wave (C1-C8, I1-I6)

Date: 2026-09-03 (Asia/Tbilisi)
Base: `0e7d2f3`

### Finding disposition

- **C1 — persisted approval authority:** resolved. Recovery retry execution now reloads and locks the persisted approval and requires persisted `approved` status, recovery category/FK/company, an unexpired review deadline, exact proposal IDs/fingerprint/source fields, and an `escalated` case. Forged or stale caller structs are only locators and cannot reopen work. Executor entry points also reload persisted approval state.
- **C2 — canonical retry identity:** resolved. Retry children retain canonical run/issue source IDs, the same root/parent lineage, and the active-source uniqueness fence; conflicting children fail closed rather than acquiring alternate UUID-suffixed identities.
- **C3 — concurrent ensure-case race:** resolved. Insert constraint conflicts are normalized, the active/exact historical row is reloaded and compared, and bounded retry returns a structured conflict rather than raising. A real two-connection sandbox regression test asserts one active row/result identity.
- **C4 — durable due processor:** resolved. `Recovery.process_due/1` performs a bounded `FOR UPDATE SKIP LOCKED` selection across detected/scheduled/expired-claimed/exhausted rows, claims through the normal lease API, applies final source checks, records outcomes, and reports DB scan errors fail-closed. Watchdog boot/ticks and Dispatcher boot/polls invoke it.
- **C5 — exhaustion dead ends:** resolved. Exhaustion failure propagates as `{:exhaustion_failed, reason}`; expired final leases close their claimed attempt, transition to exhausted, and create the single pending recovery approval. Focused due/restart/final-lease tests cover the behavior.
- **C6 — final run CAS/liveness:** resolved. Heartbeat recovery locks current run and issue, recomputes the exact fingerprint, checks tenant/identity/active state, rejects a live orchestrator or adapter owner and an active successor, then rechecks ownership immediately before the terminal write. Tests cover post-scan fingerprint changes and newly registered liveness.
- **C7 — facade routing:** resolved for the in-scope stranded-source paths. OperationsLive, RuntimeOperations stale-checkout mutation, Watchdog/Dispatcher scans, stale waiting runs, and crash-time unbound checkout cleanup now route through `Cympho.Recovery`. Ordinary dispatch-failure and wake-delivery retry lineage remains the explicit L3b residual boundary.
- **C8 — recovery approval category/linkage:** resolved. The helper owns category/status even for string-key params, requires same-company recovery linkage, and only reuses a same-company pending recovery approval. Schema and DB constraints reject recovery FKs on other categories.
- **I1/I2 — actual resume and retry guards:** resolved. Approved retry uses the existing runtime-resume API with deferred effects, then the exact checkout CAS while preserving assignee semantics. Heartbeat retries require complete source fields and recompute run fingerprint/error family; missing/changed data is stale. Tests cover paused-runtime/failed-checkout cleanup and canonical children.
- **I3 — durable expiry/denial/cancel:** resolved. Late approval expires instead of executing; cancellation, denial publication, expiry sweeps, and executor startup reconciliation drive the linked recovery case to resolved while leaving its issue blocked. Resolution notifications/audits occur after commit and are idempotent.
- **I4 — post-commit governance effects/history:** resolved. Retry publication/audit/OwnerAttention/poll and resolution effects run outside the mutation/effect transaction. Escalation proposals contain bounded attempt history/restart packet. Superseded sources cancel stale pending approvals and publish the durable resolution.
- **I5 — schema/tenant/metadata invariants:** resolved. The hardening migration adds source identity/history indexes, fingerprint/version/attempt/policy/status/JSON-size checks, and the recovery-category constraint. Changesets enforce lowercase SHA-256, bounded payloads, source identity, and same-company associations.
- **I6 — policy bounds:** resolved. Automatic attempts are capped at three, backoff at 600 seconds, lease at 600 seconds, invalid callers fail closed, and the effective policy snapshot is persisted and reused after restart (bounded explicit test overrides remain available).

### Focused verification

Command:

```bash
TEST_DB_NAME=cympho_l3b_final_20260903_final3_78511 \
MIX_BUILD_PATH=_build/l3b_final_20260903_final3_78511 \
MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' \
mise x -- mix test --max-cases 1 --seed 12345 \
  test/cympho/recovery/fingerprint_test.exs \
  test/cympho/recovery_test.exs \
  test/cympho/board_approvals/recovery_action_test.exs \
  test/cympho/heartbeat_engine/watchdog_test.exs \
  test/cympho/orchestrator/dispatcher_test.exs \
  test/cympho/owner_attention_test.exs
```

Log: `.superpowers/sdd/2026-09-02-l3b-durable-stranded-work-recovery/logs/final-fix-focused-20260903_final3_78511.log`

Exact summary: `Finished in 12.1 seconds (1.7s async, 10.4s sync)` and `125 tests, 0 failures` (exit 0).

### Complete serial verification

Two initial complete invocations each reached `4437 tests, 1 failure`; both failures were timing-sensitive, unrelated `Cympho.PortKillerTest` cases. Each failed case passed immediately in isolation (`1 test, 0 failures`), and no L3b production behavior was changed to mask them. The fresh authoritative serial rerun used the same otherwise-unique compiled build path to avoid compilation load and a new unique DB:

```bash
TEST_DB_NAME=cympho_l3b_full_20260903_fullfinal3_94475 \
MIX_BUILD_PATH=_build/l3b_full_20260903_fullfinal2_87730 \
MIX_ENV=test ERL_COMPILER_OPTIONS='[nowarn_deprecated_catch]' \
mise x -- mix test --max-cases 1 --seed 12345
```

Log: `.superpowers/sdd/2026-09-02-l3b-durable-stranded-work-recovery/logs/full-final-20260903_fullfinal3_94475.log`

Exact authoritative summary: `Finished in 202.1 seconds (68.6s async, 133.4s sync)` and `4437 tests, 0 failures` (exit 0).

Historical failed logs and passing isolated reruns are retained as:

- `logs/full-final-20260903_fullfinal_80749.log` — one PortKiller timing failure; isolated line 412 passed.
- `logs/full-final-20260903_fullfinal2_87730.log` — one different PortKiller timing failure; isolated line 134 passed.
- `logs/port-killer-isolated-20260903_portiso_87438.log` and `logs/port-killer-isolated-20260903_portiso2_94216.log` — both `1 test, 0 failures`.

### Static and browser verification

- `mise x -- mix format --check-formatted`: exit 0.
- `mise x -- bash -n deploy.sh install.sh test/shell/*.sh`: exit 0.
- `git diff --check`: exit 0.
- Ego-lite smoke: `/operations` redirected to sign-in, dev login succeeded, and the authenticated Operations page rendered at `http://127.0.0.1:4329/operations`; task space 1 was closed with `completeTaskSpace(..., {keep: false})`. The first smoke used `127.0.0.1` while Phoenix is configured for `localhost`, so socket origin warnings appeared in the server log, but the authenticated HTTP/LiveView render completed. No sessions/cookies were wiped.

### Residuals and concerns

- The designed L3b residual remains: ordinary dispatch failures and wake-delivery retries are not yet represented by recovery lineages. This wave does not expand that scope.
- Multi-node registry/session liveness remains a conservative hint; the durable database lease/source CAS is authoritative. The documented tiny checkout liveness window and concurrent telemetry overcount remain deferred minor limitations.
- Full-suite PortKiller timing flakes occurred twice under fresh-build load but were independently isolated and the authoritative complete serial rerun passed with zero failures.

Changed-file credential snapshot: 19 changed/untracked files were copied with relative paths and scanned by `/opt/homebrew/bin/gitleaks dir --no-banner --redact --exit-code 1`; exact result was `scanned ~810636 bytes (810.64 KB)`, `no leaks found`, `GITLEAKS_EXIT=0`. Log: `logs/gitleaks-final-fix.log`.
