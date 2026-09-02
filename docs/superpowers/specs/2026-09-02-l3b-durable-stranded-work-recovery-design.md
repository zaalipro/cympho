# L3b Durable Stranded-Work Recovery Design

**Date:** 2026-09-02  
**Status:** Approved for implementation by the operator  
**Roadmap:** `paperclip_gap.md` L3b (P0)

## Problem

Cympho already detects stale heartbeat runs, orphaned runs, and checked-out
issues whose orchestrator disappeared. The detection and cleanup writes are
compare-and-set safe, but the recovery policy is held in process memory. A
dispatcher or watchdog restart resets retry counts, two recovery scanners can
observe the same source independently, and a permanently stranded issue is
requeued forever without one durable owner decision. An owner can therefore
miss both the cause and the point at which automatic retries should stop.

The next slice makes recovery a durable, company-scoped workflow while
preserving the existing conservative source CAS operations.

## Goals and exit criteria

1. Persist one recovery lineage for every stale/orphan heartbeat run and every
   stranded `in_progress` checkout.
2. Persist a versioned source fingerprint, attempt number, retry deadline,
   lease, last error, and outcome so dispatcher/watchdog restarts cannot reset
   policy or duplicate work.
3. Ensure concurrent scanners claim at most one recovery attempt for the same
   unchanged source state. A source state change starts a new child lineage
   rather than resetting an exhausted lineage.
4. Use a deterministic bounded policy: one immediate automatic attempt followed
   by 60- and 120-second exponential delays (three attempts total, capped at
   ten minutes), then no further automatic recovery.
5. When the cap is reached, transition the issue to visible `:blocked` (without
   removing its intended assignee), persist one pending board approval, and
   include a safe restart packet in the proposal. Approval executes only the
   explicit `retry` action; denial leaves the issue paused for manual
   reassignment or cancellation.
6. Make the pending approval appear in the existing company-scoped Owner
   Attention queue and emit normal audit/PubSub updates.
7. Keep all operations tenant-safe and idempotent under database retries,
   watchdog/dispatcher races, and process restarts.

The slice does **not** launch or supervise OS processes, implement workspace
service adoption (L3a), or add durable lineage for ordinary dispatch failures
and wake-delivery retries. Those sources use their existing behavior until a
follow-on slice migrates them to the same context.

## Non-goals and safety boundaries

- No automatic reassignment, cancellation, or silent unblocking after
  exhaustion.
- No arbitrary command execution from a board proposal. The approved action
  calls existing issue/dispatcher APIs and validates the recorded fingerprint.
- No reliance on Registry/ETS state for correctness; local process state is
  only a liveness hint before a durable source CAS.
- No deletion of recovery history when an issue is resolved. Historical cases
  remain queryable for audit.
- No claim of crash-proof OS descendant cleanup or multi-node scheduling; the
  durable database lease is the authority for this policy.

## Alternatives considered

### A. Add fields directly to existing records

Add retry/fingerprint columns to `heartbeat_runs`, `issues`, and `agent_wakes`.
This is a small migration but produces three subtly different policies, cannot
represent a checkout with no run, and has no append-only attempt audit. It also
makes exactly-once board escalation awkward.

### B. One recovery table with an error-history JSON field

This reduces joins, but JSON history is difficult to constrain or claim under
concurrency and grows without a bounded row shape. It also makes per-attempt
metrics and unique attempt numbers unreliable.

### C. Normalized case plus attempt rows (chosen)

`recovery_cases` owns source identity, fingerprint, state, lease, policy, and
board linkage. `recovery_attempts` records each claim/result. Partial unique
indexes enforce one active case per source and one approval per case, while
attempt rows provide bounded, auditable history. This is the smallest design
that supports restart safety and exactly-once escalation without overloading
run metadata.

## Data model

### `recovery_cases`

Create a UUID table with these fields:

| Field | Type/constraint | Meaning |
| --- | --- | --- |
| `id` | UUID primary key | Case identity and lineage node. |
| `company_id` | UUID, not null for new rows, FK restrict | Tenant boundary. |
| `issue_id` | UUID, not null, FK restrict | Issue requiring recovery. |
| `agent_id` | UUID nullable, FK nilify | Agent associated with the source. |
| `source_type` | string, required | `heartbeat_run` or `issue_checkout`. |
| `source_id` | string, required | Run UUID or issue UUID as text. |
| `source_run_id` | UUID nullable, FK nilify | Exact run being recovered when applicable. |
| `parent_case_id` | UUID nullable, self FK | Previous lineage node when source state changes. |
| `root_case_id` | UUID nullable, self FK | Stable lineage root; root points to itself. |
| `source_fingerprint` | 64-char lowercase hex | SHA-256 of canonical durable source state. |
| `fingerprint_version` | positive integer | Allows future canonicalization changes. |
| `source_snapshot` | JSONB/map | Bounded, redacted diagnostic values used to explain the case. |
| `source_status` | string | Status observed when detected. |
| `state` | string | `detected`, `scheduled`, `claimed`, `recovered`, `exhausted`, `escalated`, `resolved`, or `superseded`. |
| `attempt_count` | non-negative integer | Number of automatic attempts claimed. |
| `max_attempts` | positive integer | Policy snapshot, default 3. |
| `next_attempt_at` | UTC datetime | Earliest claim time for scheduled retry. |
| `claim_token` | UUID nullable | Lease owner token. |
| `claimed_at` | UTC datetime nullable | Lease start. |
| `lease_expires_at` | UTC datetime nullable | Bounded restart takeover deadline. |
| `claimed_by` | string nullable | Node/process diagnostic, never authority. |
| `last_error` | text nullable | Redacted bounded error summary. |
| `last_attempt_at` | UTC datetime nullable | Most recent attempt start. |
| `recovered_at` | UTC datetime nullable | Successful recovery time. |
| `exhausted_at` | UTC datetime nullable | Automatic policy exhaustion time. |
| `escalated_at` | UTC datetime nullable | Board proposal creation time. |
| `resolved_at` | UTC datetime nullable | Explicit board/operator resolution time. |
| timestamps | UTC datetime | Normal Ecto timestamps. |

Use checks for allowed values and non-negative counts. Index
`(company_id, state, next_attempt_at)`, `(state, lease_expires_at)`,
`(issue_id, state)`, and `(source_type, source_id)`. Add a partial unique index
on `(company_id, source_type, source_id)` for active states
`detected/scheduled/claimed/exhausted/escalated`, so concurrent scans cannot
create two active cases for one source. A separate unique index on
`(company_id, source_type, source_id, source_fingerprint)` supports historical
deduplication. `root_case_id` is indexed for lineage queries.

### `recovery_attempts`

Create a UUID table with `recovery_case_id` (delete-all), `attempt_no`,
`status` (`claimed`, `succeeded`, `failed`, `skipped`), `action`,
`source_fingerprint`, `started_at`, `completed_at`, `next_retry_at`,
`error_reason`, `node`, and bounded `metadata` JSONB. Enforce unique
`(recovery_case_id, attempt_no)` and index `(recovery_case_id, inserted_at)` and
`(status, next_retry_at)`. Attempt rows are append-only after claim except for
the terminal status/error fields updated by the lease owner.

### Board linkage

Add nullable `recovery_case_id` to `board_approvals` with a foreign key and a
partial unique index where it is non-null. Add category
`stranded_work_recovery` to `BoardApproval.categories/0`. Keeping the unique
link on the approval table makes duplicate proposals impossible even if two
nodes race after case exhaustion; proposal JSON remains explanatory, not an
idempotency key.

## Fingerprints

`Cympho.Recovery.Fingerprint` produces canonical JSON with sorted keys and
SHA-256 lowercase hex. Version 1 includes only durable state that identifies
the work, not mutable timestamps or prose:

- run source: case/source type, run ID, issue ID, agent ID, run status,
  issue status, issue `lock_version`, issue `checkout_run_id`, and the error
  category;
- checkout source: issue ID, company ID, assignee ID, issue status,
  `checkout_run_id`, `checked_out_at` truncated to seconds, and `lock_version`.

The source snapshot stores the same IDs/statuses plus a bounded error family;
it never stores provider credentials, full prompts, or unbounded comment text.
If a scan sees a new fingerprint for an existing source, it locks the active
case, marks it `superseded`, and creates a child case with the same root. An
unchanged fingerprint reuses the existing active case.

## State machine and transaction boundaries

1. **Detect:** Watchdog/dispatcher loads a stale source and calls
   `Recovery.ensure_case/1`. A transaction validates company/issue linkage and
   inserts or returns the active case.
2. **Claim:** `Recovery.claim_due_case/1` locks a scheduled/detected case with
   `FOR UPDATE SKIP LOCKED`, rejects a non-expired lease, increments
   `attempt_count`, sets a UUID lease token and `claimed` state, and inserts the
   attempt row. A lease-expired claim can be taken over exactly once.
3. **Apply source CAS:** The lease owner rechecks liveness and calls existing
   exact helpers (`HeartbeatEngine.recover_stale_run/1`,
   `HeartbeatEngine.recover_orphaned_run/1`, or
   `Issues.clear_checkout_lock/2` with the original lock snapshot). A successor
   run/checkout or a live orchestrator causes a `skipped`/`superseded` outcome,
   never a broad cancellation.
4. **Record result:** In a transaction guarded by the claim token, success
   marks the attempt `succeeded`, case `recovered`, and clears lease fields.
   A transient failure marks the attempt `failed`; if attempts remain, case
   becomes `scheduled` with `next_attempt_at` from the deterministic backoff.
5. **Exhaust:** When the attempt reaches `max_attempts`, mark the case
   `exhausted`, clear automatic scheduling, and transition the issue to
   `:blocked` only if it is still non-terminal and still matches the source
   fingerprint. Preserve assignee and record a system comment/audit event.
6. **Escalate once:** In the same transaction as exhaustion, insert a pending
   `BoardApproval` with `recovery_case_id`, action `retry`, source fingerprint,
   attempt history, and a bounded restart packet; set case `escalated` and
   `escalated_at`. Commit-time code then emits audit/PubSub/OwnerAttention
   notifications. If insertion races, the unique link returns the existing
   approval and the case remains escalated.
7. **Resolve:** Denied/expired approval leaves the issue blocked and marks the
   case `resolved` with a human resolution note. Approved `retry` validates
   case state, fingerprint, and issue ownership in one transaction, changes
   case to `scheduled` with a fresh bounded attempt budget, clears the runtime
   pause only through the existing issue API, and queues one dispatcher wake.
   A stale proposal returns a structured no-op and an audit record.

The case lease is the only automatic recovery claim. Board execution continues
to use `BoardApprovalEffect` for exactly-once action dispatch; the recovery
case fingerprint/state check is an additional domain guard.

## Watchdog and dispatcher integration

Add a small `Cympho.Recovery` facade so both scanners call the same code:

- `recover_stale_run/1` and `recover_orphaned_run/1` first ensure/claim a run
  case, then invoke the existing HeartbeatEngine CAS and record the result.
- `recover_orphaned_in_progress/0` first ensures/claims an issue-checkout case,
  then runs its existing live-orchestrator checks, environment release, and
  checkout CAS. It must not clear a successor-bound checkout.
- Watchdog and dispatcher may still both scan; duplicate claims return
  `:already_claimed` and do not call a source mutation.
- A bounded `Recovery.process_due/1` batch runs at each existing recovery pass.
  Database errors log and leave cases scheduled; they never clear a checkout.
- Existing in-memory `State.retry_attempts` remains for ordinary dispatch
  failures in this slice, but no recovery case may be bypassed for stale/orphan
  sources.

## Board action and owner experience

`BoardApprovalActionExecutor` handles `stranded_work_recovery` through
`Recovery.apply_board_action/2`. Only proposal action `retry` is accepted. It
revalidates company, issue, case ID, fingerprint, and `state == escalated`;
otherwise it returns `{:error, :stale_recovery_proposal}` without changing
work. A successful approval records an audit event and enqueues one wake. A
denial or expiration records the resolution note but does not unpause or
requeue the issue.

The existing board-approval LiveView needs no new route: its title,
description, and proposal data are already rendered, and OwnerAttention's
pending board-approval read model supplies the Simple-mode badge/link. Add an
explicit plain-language summary (“Work is paused after three failed automatic
recoveries. Approve Retry to run it once more; deny to leave it paused for
reassignment or cancellation.”). Raw fingerprints and node details stay in
the Advanced proposal/audit payload.

Create/resolve notifications must call `OwnerAttention.notify_changed/1` in
the same places that broadcast board approval events, preserving one badge
source of truth.

## Rollout and compatibility

- New tables start empty; no migration mutates live issues or runs.
- A startup/first-pass backfill may create `detected` cases for currently stale
  runs/checkouts, but it performs no source mutation until a lease is claimed.
- Rows with nil/mismatched company IDs are logged and skipped, not guessed.
- Existing recovery APIs retain their public return shapes for callers/tests;
  the facade wraps them and maps duplicate/terminal races to the same benign
  outcomes.
- A feature flag defaults enabled after migration. Disabling it stops new
  claims but leaves cases and approvals auditable.
- Follow-on work will migrate dispatch-failure and wake-delivery retries into
  the same tables rather than adding another policy.

## Verification

Focused tests must prove:

1. fingerprint stability, changed-state child lineage, and tenant mismatch
   rejection;
2. one active case and one claimed attempt under concurrent scanner calls;
3. persisted backoff/attempt cap across a Dispatcher/Watchdog restart;
4. stale-run CAS losing to a completed run and checkout CAS preserving a
   successor;
5. exhaustion blocks the issue, creates one approval, and suppresses automatic
   requeue;
6. duplicate scans do not create another approval;
7. approved retry is idempotent and stale/denied approval leaves the issue
   paused;
8. OwnerAttention count/broadcast and governance audit entries are
   company-scoped.

Run the focused recovery suites, `mix format --check-formatted`, the complete
serial `mix test`, shell syntax checks, and the modified-file credential scan
before claiming the tranche complete.
