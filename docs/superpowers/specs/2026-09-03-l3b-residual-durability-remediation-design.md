# L3b Residual Durability Remediation Design

**Date:** 2026-09-03
**Status:** Approved by the operator's standing instruction to take recommended decisions and continue autonomously
**Parent spec:** `docs/superpowers/specs/2026-09-02-l3b-durable-stranded-work-recovery-design.md`
**Starting point:** `1e4511a`

## Problem

The first L3b implementation persists cases, attempts, leases, source fingerprints,
and board escalation, but a whole-branch review and two independent audits found six
remaining load-bearing gaps:

1. the due scan releases `FOR UPDATE SKIP LOCKED` before it claims a row, so
   concurrent batches can select the same first page;
2. due and final run recovery revalidate status and the semantic fingerprint but
   not durable heartbeat/checkout freshness, so work that became live again can be
   terminated;
3. persisted recovery-case tenant/source fields are not compared comprehensively
   to the loaded run and issue on every destructive path;
4. denial, cancellation, and expiry commit the approval before resolving the linked
   case, leaving a crash window repaired only by later reconciliation;
5. effective test/operator retry policy reaches the current attempt but is not
   always stored by adapter entry points for restart reuse; and
6. crash-time unbound checkout cleanup runs before its active run is recovered and
   passes an ignored option, leaving the checkout stranded.

Green focused and full suites did not cover these races. This remediation adds the
missing authority and tests without widening L3b to ordinary dispatch failures or
wake-delivery retry lineage.

## Options considered

### A. Liveness-aware source version plus atomic one-row claims (chosen)

Add bounded liveness tokens to fingerprint version 2, centralize an exact
case/source guard, and have each due worker select-and-claim one row in a single
short `SKIP LOCKED` transaction before executing its callback. Resolve approval and
case state in the same BoardApprovals transaction. This is the smallest design that
closes the reproduced races while retaining current tables and scanners.

### B. Separate durable owner-epoch columns on runs/issues

Add a monotonically increasing owner generation and require workers to renew it.
This provides stronger multi-node fencing, but it changes the live worker protocol,
requires rollout compatibility, and belongs with the broader cluster/runtime
ownership work. It is not required to stop recovery after a freshly committed
heartbeat.

### C. Remove `process_due/1` and rely only on source scanners

This avoids claim coordination but strands scheduled cases when they fall outside a
scanner batch or stop matching an age query. It contradicts the parent spec and is
rejected.

## Decisions

### 1. Fingerprint version 2 carries a bounded liveness token

The earlier plan excluded arbitrary mutable timestamps to avoid noisy lineages.
Evidence now proves that excluding the authoritative liveness value permits a stale
case to terminate fresh work. Version 2 therefore adds only the timestamp used as a
source CAS token:

- running heartbeat run: `last_heartbeat_at`, falling back to `inserted_at`;
- pending/queued run: `inserted_at`;
- issue checkout: `checked_out_at`, falling back to `updated_at`.

Values are truncated to seconds and encoded as ISO-8601 strings. They contain no
prompt, credential, log, or arbitrary metadata. A new heartbeat/checkout supersedes
the old case. If that work later becomes stale again, its new fingerprint creates a
child lineage. Version 1 historical rows remain readable but destructive recovery
must recompute and match all available persisted source fields; an old row missing a
required liveness token fails closed and is superseded.

This decision supersedes the earlier timestamp-exclusion ruling only for these three
bounded CAS tokens. No other timestamp enters the fingerprint.

### 2. Final durable staleness is checked under the source row lock

`HeartbeatEngine.recover_run_if_current/4` receives an expected guard containing
case company, issue, run, agent, source ID, fingerprint, recovery kind, and the
configured current time/cutoff. In the same transaction that locks the run and issue,
it requires:

- exact guard-to-run-to-issue identity and company equality;
- active source status and exact fingerprint/liveness token;
- running runs have `last_heartbeat_at || inserted_at` older than the stale cutoff;
- pending/queued orphan runs have `inserted_at` older than the cutoff;
- no live local owner or DB successor immediately before the status write.

A concurrent heartbeat UPDATE either commits first (recovery sees the fresh value)
or waits behind the recovery row lock and loses its `status == running` predicate.
Registry/session absence remains an advisory skip, not the source of durable
staleness truth.

Checkout recovery uses the version-2 checkout token plus its existing lock-version,
binding, active-run, and final live-owner checks. A changed checkout token is
superseded.

### 3. Due selection and claim are one atomic short transaction

Replace the ID-page query plus later blocking claims with
`claim_next_due_case/1`. Each invocation:

1. selects one ordered due `detected`, `scheduled`, expired `claimed`, or
   `exhausted` row using `FOR UPDATE SKIP LOCKED LIMIT 1`, excluding IDs already
   visited in the current pass;
2. validates/reuses the persisted policy snapshot;
3. closes an expired attempt when necessary;
4. writes the new claim token and attempt row, or returns a typed escalation item;
5. commits before executing source mutation.

`process_due/1` loops at most the bounded `limit`, processes one returned lease/item,
and excludes a row after any result so an escalation error cannot consume the whole
batch. Two nodes therefore reserve different rows without blocking, and lease clocks
start only immediately before each callback.

Before any callback or escalation, the complete case/source guard must require exact
`company_id`, `issue_id`, `source_type`, canonical `source_id`, `source_run_id`,
`agent_id`, fingerprint, status, and liveness token. Direct-SQL corruption produces a
superseded/fail-closed outcome and no source mutation.

### 4. Recovery policy is immutable after detection

Normalize the effective policy once at an adapter boundary and merge all four values
into new source attributes:

- `max_attempts` (1..3),
- `base_delay_seconds` (1..600),
- `max_delay_seconds` (`base..600`), and
- `lease_seconds` (1..600).

`ensure_case/1` persists that exact snapshot. Existing active cases keep their first
snapshot. Later claims/due processing use it and reject conflicting overrides rather
than changing policy mid-lineage. Retry children inherit a validated, complete
snapshot; `%{}` never counts as complete.

### 5. Approval and linked-case terminal resolution commit together

Expose a transaction-only `Recovery.resolve_approval_case_locked/2` that expects the
persisted locked approval and performs no PubSub/audit side effects. BoardApprovals
calls it inside the same transaction that denies, cancels, or expires a recovery
approval. The transaction returns an effect descriptor; after commit, one publisher
emits governance audit, company-scoped approval/recovery events, and OwnerAttention.

`resolve_board_approval/4`, `cancel_board_approval/2`, explicit late approval, and the
bounded expiry sweep all use this composition. Startup reconciliation remains a
bounded repair path for rows written before this change and is idempotent. Resolution
events contain the reloaded `state == "resolved"` case. A bounded human resolution
note is stored on the case when available.

This design guarantees database atomicity, not crash-proof PubSub delivery; durable
notification outbox work remains outside this tranche.

### 6. Crash cleanup is ordered by durable ownership

Dispatcher crash cleanup no longer passes `allow_unbound_active_runs`. It first
recovers the exact pre-crash run snapshots through `Recovery.recover_orphaned_run/2`.
Only after no active run remains and no replacement owner exists does it recover the
unbound issue checkout. If run recovery schedules a retry, checkout cleanup remains
fail-closed. Successful due run recovery performs the same conservative unbound
checkout follow-up, so a transient first pass does not require waiting for the age
scanner. Any newly bound successor makes the checkout CAS lose.

Operations recovery deduplicates pending/queued runs already present in the orphan
set before aggregating counts. All source mutations continue through Recovery.

## Error handling and observability

- A fresh or mismatched source is `superseded`, never a retryable provider failure.
- A database/approval error leaves the durable case due and returns a bounded error;
  it does not report false exhaustion.
- Due batches report distinct `checked`, `claimed`, `recovered`, `scheduled`,
  `exhausted`, `superseded`, and `failed` counts.
- Reconciliation and expiry sweeps use explicit limits and only query unresolved
  linked recovery cases.
- Logs/audit payloads contain IDs, state, policy values, liveness token, and bounded
  error families only.

## Verification

Focused tests must prove:

1. a heartbeat or checkout-liveness update after detection supersedes the old case
   and prevents mutation/escalation;
2. a heartbeat committed before the final row lock wins, while a post-terminal
   heartbeat loses the active-status predicate;
3. two real DB connections atomically claim disjoint due rows, skip a locked first
   row, and do not starve a later row;
4. direct-SQL corruption of any case tenant/source identity cannot mutate a run or
   issue;
5. expired-final leases validate freshness before escalation;
6. adapter-supplied policy survives reload and controls the next lease/backoff;
7. denial/cancel/expiry atomically resolve both approval and case and publish the
   updated resolved case after commit; rollback changes neither;
8. crash cleanup recovers the run before an unbound checkout and eventually clears
   it without touching a successor; and
9. Operations counts each old pending/queued run once.

Run the focused recovery, board, Watchdog, Dispatcher, Operations LiveView, and
OwnerAttention tests, then formatting/shell/diff checks, changed-file gitleaks, and a
fresh full serial suite. Browser smoke is required only if user-visible Operations or
board rendering changes; use Ego Lite, never wipe sessions, and close the task space.

## Explicit residual boundary

Ordinary dispatch-failure and wake-delivery retry lineage remain open as documented
in `paperclip_gap.md`. This remediation does not claim Paperclip parity, low-resource
benchmark parity, cluster-wide owner fencing, crash-proof PubSub delivery, or managed
workspace-service adoption.
