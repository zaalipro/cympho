# Small-VPS hardening — implementation and verification

**Scope:** the approved focused first phase, not the separate architectural backlog.
**Workspace:** implemented in place on the user's existing dirty checkout; no commit, branch switch, stash, push, deployment, or existing-database migration.
**Status:** focused implementation and scoped reviews complete; whole-suite acceptance is **not green**. The final run has seven original failures plus one additional unchanged mock timing failure. Cleanup-liveness and constrained-host capacity limitations remain below.

## Changes

- Tenant-controlled routine/launch-item ownership and consistent associated-resource scope, including fail-closed legacy fallback.
- Actor-aware company membership/invite management, owner-only ownership changes, transactional last-owner protection, channel reauthorization and company-scoped disconnect after removal.
- GitHub webhook project/repository binding and shared PR-link validation at issue API/LiveView/context boundaries; merge validates repository authority before remote calls.
- Authoritative active-run controls, read-only preflight, demand-poll coalescing and singleton heartbeat timers. Live registry ownership supplies bounded candidate queries without arbitrary recent-history cutoffs; roster rows and counters use the same runtime status.
- Direct-adapter output bounds with child teardown; Agrenting cancellation attempts for unknown nonterminal timeout/poll-error outcomes. Limits honor the smaller global/per-adapter/per-run ceiling up to 8,000,000 bytes. The no-Perl fallback uses existing Python3 with block reads rather than bytewise `dd`; absent both interpreters, it fails before starting the producer.
- Configured Finch pools applied at startup; lazy notification preferences; bounded routine overview projections; reduced duplicate board loading/digest computation.
- Explicit safe JSON projections for company, agent, workspace and budget controller responses.

## Reproducible local evidence

The original working-tree snapshot (including the user's uncommitted recovery work) was tested with Elixir 1.19.5 / OTP 28.4.3, seed 12345, four schedulers and four concurrent ExUnit cases, in a disposable PostgreSQL database.

**Baseline:** 4,537 tests, 7 failures. One README link references missing `CLAUDE.md`; six existing Orchestrator tests fail around mocked completion/action handling. These failures were present before this implementation and were not silently repaired or suppressed.

Changed-file formatting (82 source/test paths), compilation and `git diff --check` pass. All seven task reviews and the final correction review passed; a subsequent single-line RunProgress fixture correction was also independently reviewed. The original uncommitted work was independently compared by SHA-256: 22 out-of-scope dirty paths remain byte-identical; four originally dirty paths contain authorized surgical changes. The user's recovery migration remains untouched.

The first post-correction full run had **4,651 tests, 9 failures**: the original seven, a restricted-PATH RunProgress fixture (corrected without changing assertions), and a PortKiller cleanup timeout in unchanged source/test code. Subsequent focused checks passed RunProgress + OutputLimit (12/0) and ProcessAdapter (13/0), but two combined focused attempts also observed missed cleanup completion windows. These failures are retained in the logs, not hidden by the isolated passes.

**Final full run:** **4,651 tests, 8 failures**, 276.1 seconds, exit 2, in fresh disposable database `cympho_audit_20260923_acceptance2`. All seven original failure identities repeated. The additional failure was `Cympho.AgentRunnerTest`, `Mock.run/4 sends turn_ended_with_error for error mock` (`test/cympho/agent_runner_test.exs:21`): ExUnit found the expected message at its 100-ms assertion boundary. One focused diagnostic run also failed at that boundary (1 test, 1 failure, 21 excluded); it was not repeatedly rerun to obtain a pass.

The mock, AgentRunner and test files are SHA-256 identical to the original snapshot. This case calls only an unchanged plain `spawn`/10-ms sleep/message-send path, not changed task logic. Host load later reached approximately 59 on eight CPUs. Scheduling pressure is a plausible explanation, not a proven sole cause. The extra failure is **not** relabeled as one of the baseline seven. The final suite is therefore not baseline-identical or green, despite no changed task-code path being implicated by that particular case.

All 82 task source/test hashes matched the pre-run manifest after acceptance; there was no source/test drift during the suite. Final preservation checks found no missing baseline files or unauthorized baseline changes, and branch/HEAD remain `main` / `3e283fdf4bbac70225c929831b0b2d6eb6ddfb09`.

Commands used for the final full run and single-case diagnostic:

```bash
python3 .superpowers/sdd/2026-09-23-small-vps-hardening/run-tests.py acceptance2 test
python3 .superpowers/sdd/2026-09-23-small-vps-hardening/run-tests.py reviewfinal test/cympho/agent_runner_test.exs:21
```

The runner pins Elixir 1.19.5/OTP 28.4.3, uses four schedulers, seed 12345 and four ExUnit cases, and serializes builds/tests. Evidence: `acceptance2-tests-1790180848967926000.log`, `acceptance-failure-comparison.json`, `reviewfinal-tests-1790181193881619000.log`, `final-static-verification.log`, and `final-state-verification.json` in the retained local workspace.

### Routine-health read benchmark

Fixture: 10 active routines, one trigger each, 2,010 historical/current runs, 4,096 bytes of variable payload per run. Three warmed samples per version used identical data and verified exactly 10 stale runs and 200 recent failures. All fixture writes were rolled back by SQL Sandbox.

| Metric per health-summary read | Original snapshot | Hardened implementation |
| --- | ---: | ---: |
| SQL result rows returned to the application | 2,030 | 4 |
| SQL queries | 3 | 4 |
| Elapsed samples, milliseconds | 42.160 / 55.749 / 44.434 | 14.070 / 14.947 / 13.308 |
| Caller BEAM reductions | 41,923 / 41,964 / 41,785 | 10,391 / 10,146 / 10,317 |

The row-count change demonstrates removal of historical-run materialization. Timings are observational local measurements taken during development, not a controlled production throughput claim; work also moves into SQL aggregates. They do not establish a whole-application RAM/CPU percentage or 2-GB capacity.

Other regression evidence checks the **running** Finch pool configuration (low profile size 2, explicit override retained), zero all-tenant preference warmup, correct cold-cache delivery, board issue-list queries reduced from four to two across disconnected/connected LiveView mount, and no full-board reread or duplicate digest build for unchanged paired issue events.

## Compatibility and safety decisions

- PR linking now requires an issue project with a configured matching GitHub repository. Unlinking and unrelated updates to legacy persisted rows remain possible. Project configuration still has its pre-existing HTTP(S)-only validation; parser support for legacy SSH URLs is not a new SSH configuration feature.
- API projections intentionally omit credential-capable workspace/service URLs, commands, provider references, secret bindings/configuration, and operation logs. Normal allowlisted identifiers, status/date fields, response envelopes and service `reuse_key` remain available. Budget GET actions were not newly routed.
- A user with retained authored invitations receives a controlled HTTP 409 when deleting their account. The existing inviter FK combines `ON DELETE SET NULL` with `NOT NULL`; this phase preserves invitation/audit history rather than deleting it or changing the production schema.
- An Agrenting cancellation acknowledgement is not durable proof of remote terminal state. Cancellation failures retain the hiring ID and error evidence; durable provider reconciliation remains follow-up work.
- No production resource settings were changed. For the chosen 1–2-GB target, use the existing `CYMPHO_RESOURCE_PROFILE=low`: one total/local run, five DB connections, Finch size two and a 384-MB pre-start reserve. The reserve is an admission check, not a hard child-process memory limit.

### Remaining cleanup-liveness limitation

`PortKiller` and its tests are byte-identical to the original snapshot. Its grandchild cleanup test failed once in five isolated repeats with a bounded cleanup timeout, despite passing the preceding 10-test file run. The original full baseline did **not** list this failure; it is an additional intermittent observation, not one of the seven baseline failures.

A temporary ProcessAdapter probe also observed a TERM-ignoring shell/sleep tree still registered without a terminal event after 12 seconds. A subsequent standalone comparison with the same child shape cleaned the direct port in 204 ms and the output-limited wrapper in 307 ms; both left no owned child alive. That comparison did not reproduce the stall and does not establish its cause. Host load was approximately 29 on eight CPUs during the investigation.

A separate deterministic probe confirmed an existing fail-closed liveness edge: if the **first** root identity lookup yields `:unknown`, `PortKiller` retains that identity and subsequent retries never re-read it, even if the probe would recover. Cleanup can therefore remain pending indefinitely. The earlier real stall did not capture its cleanup object, so this edge is **not claimed as its proven cause**. No identity guard was weakened and no test timeout increased. Safe recovery from an initially unverifiable process identity remains follow-up work; stop/timeout latency is not unconditionally guaranteed by this phase. Standalone probes reaped only their identity-checked owned processes and retained their scripts/logs.

## Final acceptance procedure

1. Run the full suite in a fresh disposable database with all current migrations; compare failures by identity with the original snapshot, not only by count.
2. Run changed-file formatting checks and compilation, and complete an independent whole-change review against the dirty-tree snapshot.
3. On a separate isolated Linux host constrained to two CPU cores and 2 GB total RAM, pin app/OTP/PostgreSQL/CLI versions and the low profile. Repeat each workload three times: cold boot, ten-minute idle, 100 idle agents, one active local run plus a queued run, wake bursts, and long-history views.
4. Sample application, CLI descendants and PostgreSQL separately, plus cgroup totals: memory/CPU, DB row/query counts and pool waits, singleton mailboxes, latency, failures, OOM and sustained swap. Measure browser resources on a client machine, not as backend consumption.

This development host is macOS with 16 GB RAM and no Docker/Podman runtime, so the Linux 2-GB acceptance trial has **not** been performed. Automated LiveView/controller/channel tests cover the changed server-side behavior; browser state was not accessed or cleared.

### External constrained-host trial (not run)

Use a disposable Linux VM with two vCPUs and 2 GB RAM, or one parent cgroup containing the application, its CLI descendants **and PostgreSQL**, with equivalent limits. Constraining only BEAM while excluding PostgreSQL is not the target trial. Record kernel, OTP/Elixir, app revision, database and CLI versions; use an isolated fixture company, no production data or paid provider requests. Select `CYMPHO_RESOURCE_PROFILE=low`, record any overrides, and verify effective pools/concurrency before measuring.

Run each workload below three times for both the original snapshot and changed tree with identical fixture data, versions and limits. Restore only the disposable fixture between trials; never reset an existing user database. Sample at one-second intervals, and retain each individual result rather than only an average.

| Workload | Repeatable steps and checks |
| --- | --- |
| Cold boot | Start PostgreSQL and the app from stopped state. Measure time to readiness, peak cgroup memory and child count. Stop both before the next repetition. |
| Ten-minute idle | After readiness, make no requests for 600 seconds. Record idle CPU, memory trend, mailbox sizes and background DB work. |
| 100 idle agents | Create 100 nonrunning fixture agents; observe for 600 seconds, open the roster, then observe another 60 seconds. Verify no per-idle-agent run-history queries or unexpected local CLI launches. |
| Active and queued | Use a deterministic local fixture command that emits a short line each second for 60 seconds. Submit two eligible runs; verify one active/local slot, the second queued, then automatic admission after confirmed cleanup. Sample through both completions. |
| Wake burst | While one fixture run occupies the local slot, send 1,000 wake requests over ten seconds. Observe for 60 seconds after the burst; verify bounded pending poll work, the final wake is honored and admission remains at one. |
| Long history | Reuse the local benchmark's 10-routine/2,010-run/4,096-byte-payload fixture. Measure routine health/index and board reads separately, including returned SQL rows, query count and page latency; confirm exact health values and bounded latest-run records. |

Collect cgroup memory current/peak, CPU usage and OOM counters; report application/CLI/PostgreSQL process RSS separately (do not sum RSS and call it exact physical memory). Record DB pool wait, singleton mailbox length, p50/p95 request latency, failures and swap activity. Require no OOM, no orphan child/slot leak, correct queue progress and no sustained swap before recommending this workload on the target. Report actual resource measurements and limitations; do not extrapolate capacity from the local query benchmark.

## Rulings I made

These preserve the execution ledger's decisions in chronological order; no review workspace or baseline snapshot is being deleted.

| Decision | Reason | Cost or limitation |
| --- | --- | --- |
| Work in place on `main`, without a worktree. | Explicit user instruction to continue the uncommitted checkout. | Implementation and existing edits share a checkout; the original snapshot is retained for comparison. |
| Do not commit user or implementation work. | Avoid capturing unrelated changes without authorization. | Review uses file snapshots, and the user retains integration responsibility. |
| Parallelize independent tasks with exclusive file ownership; serialize tests/builds. | Honor requested multi-agent work without conflicting edits or shared build races. | Cross-task changes require coordination. |
| Keep existing profile defaults; recommend `low` only for the target deployment. | Preserve existing installations and avoid an unauthorized config change. | Deployments do not gain lower limits until an operator selects the profile. |
| Create/migrate only uniquely named disposable audit databases. | Protect existing databases. | Disposable audit databases remain separate local artifacts. |
| Do not equate local evidence with Linux 2-GB capacity. | This host lacks the required constrained environment. | Capacity and Alpine-container validation remain external work. |
| Require a configured matching issue-project repository for PR links and merges. | Fail closed on repository authority. | Projectless or unconfigured PR workflows must configure a repository first. |
| Track baseline failures rather than fix unrelated documentation/recovery mocks. | Keep the approved scope and an honest comparison. | The full project suite is not claimed green. |
| Enforce PR-link authority in the shared Issue boundary, including API/LiveView, with narrow fixture updates. | An AgentActions-only guard would leave other mutation paths open. | Linking incompatible PRs is rejected; unrelated legacy-row updates and unlinking remain allowed. SSH parsing does not introduce a new Project configuration feature. |
| Return a controlled conflict for account deletion with retained authored invitations. | Preserve audit history without a production schema change. | Such accounts cannot be deleted until the conflicting FK/audit policy is redesigned. |
| Include roster status and batched live ownership in reliable run controls. | A valid stop/progress API must be reachable through a truthful product UI. | Adds a small, scoped UI change; unverifiable ownership still reports cleanup pending. |
| Address all final-review findings together, using existing Python3, live-owner discovery and condition-based cleanup assertions. | Remove CPU-heavy fallback and correctness limits without a dependency or historical scan. | The relay needs Perl or Python3; the actual Alpine trial remains unrun. |
| Expose existing Python3 in the restricted-PATH RunProgress test fixture. | Full-suite evidence showed the fixture hid both supported relays. | One extra test-only compatibility edit; all original assertions and the production fail-closed behavior remain unchanged. |
| Preserve fail-closed process identity checks and report the newly confirmed cleanup-liveness edge separately. | PortKiller is unchanged baseline code; loosening identity checks could signal a reused PID, and the observed stall's exact cause remains unproven. | Cleanup may remain pending after an initially unknown root identity; this requires a separately designed recovery fix rather than a timeout relaxation. |
| Leave the unchanged mock timing test intact and report the final non-green suite. | The additional failure invokes no changed task-code path; repeated runs or a wider assertion timeout would not establish a product fix. | A baseline-identical full-suite result is not available; timing reliability needs a quiet-host check or separate test-harness work. |


## Explicitly deferred

- Durable critical post-commit effects and deferred-approval retry cadence in the existing recovery work.
- Atomic Budget/Policy consistency and currency/anchored-window semantics.
- EventStore generation/replay protocol, agent-token lifecycle revocation, fair recovery/backlog pagination and broader ownership recovery.
- Fully paged trace/comment read models, batched unread flags, existing board comment-topic freshness, document rollback preservation and unrelated preview/join-request defects.
- Remote lease reservation redesign, trace-chain rewrite amplification, latent decision/skill/SSH defects, and the invitation-deletion schema/audit policy above.
- Safe recovery from an initially unknown PortKiller root identity and characterization of the intermittent portable cleanup stalls described above.
- The unchanged mock assertion-boundary failure and original seven baseline failures; no broad test timeout or unrelated implementation changes were made to obtain a green result.

Local raw test logs, the original source snapshot, benchmark JSON/script, task reports and review deltas are retained in the git-ignored `.superpowers/sdd/2026-09-23-small-vps-hardening/` workspace. They include the user's original uncommitted baseline and should not be published wholesale.
