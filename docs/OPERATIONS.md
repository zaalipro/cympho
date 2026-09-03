# Operator guide

This guide covers the controls that keep autonomous work observable and
recoverable. It complements the in-product Operations console; it does not
replace company-scoped budgets, approvals, or execution policies.

## Operating posture

- Use **review mode** while configuring a new installation.
- Set company, issue, or agent **Pause** when work must remain queued without
  running.
- Use **Low Power** to allow only high- and critical-priority automatic work.
- Use **Stop** for active Cympho-managed sessions; verify the reported adapter
  cancellation result and inspect any remote provider separately.
- Resume only after the workspace, adapter, secret, budget, and governance
  readiness checks are green.

Development enables autonomous dispatch only when
`CYMPHO_ORCHESTRATOR_ENABLED=1`. Use
`CYMPHO_DISPATCH_ONLY_ISSUE_ID` for a one-issue smoke before opening the full
queue.

## Durable stranded-work recovery and escalation

The Dispatcher and Heartbeat Watchdog persist recovery for two source types:
`heartbeat_run` (a stale or orphaned heartbeat run) and `issue_checkout` (a
checked-out issue with no live owner). Each case records a versioned, redacted
source fingerprint and snapshot, company/issue scope, parent/root lineage, a
lease, and a bounded retry deadline. Fingerprint version 2 adds only the
source's bounded durable liveness timestamp as a CAS token: a running run's
`last_heartbeat_at` (falling back to `inserted_at`), a pending/queued run's
`inserted_at`, or a checkout's `checked_out_at` (falling back to `updated_at`).
No prompt, credential, provider log, arbitrary metadata, or other timestamp is
part of that addition.

Direct, due, and exhaustion paths lock and re-read the durable source before a
destructive change. They require an exact match across company, issue, source
type and ID, run, agent, active status, fingerprint/liveness token, and the
applicable final freshness cutoff; a live owner or fresh successor also wins.
Any stale, incomplete, cross-tenant, or mismatched case is superseded without
changing the issue or run. Each due row is selected and reserved in one short
`FOR UPDATE SKIP LOCKED LIMIT 1` transaction. The claim/attempt write commits
before its callback runs, so concurrent nodes reserve different rows without
holding database locks across source mutation.

The default policy is one immediate attempt followed by two bounded retries
(three attempts total, with 60- and 120-second backoff). All four effective
values — maximum attempts, base delay, maximum delay, and lease seconds — are
validated and persisted once. The snapshot is immutable for the active
lineage, later conflicting overrides fail closed, and retry children inherit
the complete policy. Durable attempt rows are append-only with stable ordinals.
A deferred claim is closed as skipped and returns its provisional retry-budget
slot, so audit history remains distinct from the retained budget count used for
exhaustion and backoff.

When the cap is exhausted, the non-terminal issue is set to **Blocked** and one
auditable board approval with category `stranded_work_recovery` is created.
Automatic recovery does not wake or dispatch exhausted work. An owner must
review the approval in the board/Owner Decisions queue and choose the explicit
**Retry** action. An approved retry verifies the company, issue status, source
fingerprint, and lineage, resolves the exhausted case, reopens the
still-matching issue to `todo`, and creates a child scheduled case. Denial,
expiry, or cancellation locks case → approval and commits the approval outcome
plus linked case resolution in one transaction. It does not lock or mutate the
issue; the issue remains blocked from the earlier exhaustion transaction.
Approved retry and exhaustion acquire the issue after case/approval when their
mutation requires it. Audit, company/recovery events, PubSub, and OwnerAttention
publication happen best-effort after commit; there is no durable notification
outbox.

Dispatcher crash cleanup snapshots and recovers the exact pre-crash run first,
then considers an unbound checkout. A durably stale run cohort can be recovered
together, but a fresh or live successor defers cleanup without consuming the
returned retry-budget slot. Successful run recovery performs conservative
checkout follow-up before its case is closed, and a newly bound successor makes
that checkout CAS lose. The Operations recovery aggregate removes orphan run
IDs from its waiting-run set so an overlapping pending/queued run is counted
and routed through Recovery only once.

### Operator procedure

1. Open the company-scoped Owner Decisions/board approvals queue and locate the
   `stranded_work_recovery` item. Confirm the issue, agent, source type,
   attempt count/max, last bounded error, and the case's source snapshot; do
   not paste secrets or raw provider output into the approval.
2. Check instance health before retrying: run `mix cympho.doctor` from the
   release checkout, inspect readiness/database status, and use the separately
   authenticated `/beam` dashboard plus host tools for node pressure and child
   process state. Keep the issue blocked while investigating.
3. If the source is still valid and the underlying failure is understood,
   approve **Retry** once. Verify that the old case is resolved, a child case
   is scheduled, the issue is `todo`, and a new attempt/run is visible. If the
   source changed, the issue is terminal, or tenant ownership is uncertain,
   do not retry; deny or cancel the approval instead.
4. If the retry does not reach dispatch or wake the agent, treat that as the
   known dispatch/wake-lineage residual: preserve the blocked state, capture
   the case/attempt IDs and bounded timestamps, and investigate Dispatcher,
   Watchdog, adapter, and host logs before taking any further action. Do not
   create ad-hoc duplicate recovery rows or manually signal a provider process.
5. For denial, expiry, or cancellation, record the human reason in the normal
   governance workflow and leave the issue blocked until an owner makes a new,
   separately justified decision. Never bypass the company scope or mutate
   recovery tables directly in production.

This recovery safety pass is durable across the persisted case/attempt records,
but ordinary dispatch-failure and wake-delivery lineage remains open. It also
does not provide cluster-wide owner fencing, durable PubSub/outbox delivery,
measured low-resource RAM/CPU/VPS evidence, managed workspace-service adoption,
or full/latest Paperclip parity. The procedure above is the documented,
fail-closed escalation path while those residuals remain open.

## BEAM dashboard

`/beam` exposes live process, memory, ETS, socket, request-log, and metric
views for the node itself: which orchestrators and agent heartbeats are alive,
how deep the mailbox is on the singleton processes every dispatch and broadcast
passes through, and where run-queue time is going.

This is an **instance operator** surface, not a tenant one. It crosses every
company on the node, so it is deliberately not reachable through company
membership — being a company owner does not grant access. It requires its own
credentials:

```text
CYMPHO_DASHBOARD_USER
CYMPHO_DASHBOARD_PASSWORD
```

With either unset the route returns 404, so an install that has not opted in
does not advertise that the dashboard exists. Development uses the fixed
credentials `cympho` / `cympho`.

Metrics come from `Cympho.Telemetry.Metrics`, which is reporter-agnostic: the
same definitions feed StatsD, Prometheus, or an OTLP exporter without touching
any emit site. Metric tags deliberately exclude per-tenant identifiers so a
large install cannot grow an unbounded number of series.

## Production configuration

Production requires:

```text
DATABASE_URL
SECRET_KEY_BASE
APP_HOST
PREVIEW_HOST
LIVE_VIEW_SALT
CYMPHO_ENCRYPTION_KEY
CYMPHO_USER_JWT_SECRET
CYMPHO_AGENT_JWT_SECRET
```

### Resource profiles

Set one instance profile instead of independently guessing safe process and
connection limits:

| `CYMPHO_RESOURCE_PROFILE` | Total runs | Local CLI runs | Memory reserve | PostgreSQL pool | Finch pool | Use case |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `low` | 1 | 1 | 384 MB | 5 | 2 | 1–2 vCPU / 1–2 GB VPS, many registered agents but one active local CLI |
| `balanced` (default) | 3 | 2 | 768 MB | 10 | 5 | General self-hosting |
| `throughput` | scheduler-derived | 4 | 1536 MB | 25 | 10 | Measured hosts with remote/gateway-heavy execution |

Registered idle agents are not the same as simultaneous OS-backed jobs. Keep
the profile at `low` to host a large roster cheaply; Cympho queues their work
and admits one run at a time. Raise concurrency only after checking app,
PostgreSQL, and BEAM pressure in `/beam`, then checking child CLI RSS with OS
tools. The BEAM dashboard does not include external child-process memory.

`CYMPHO_MAX_CONCURRENT_AGENTS`, `CYMPHO_MAX_LOCAL_AGENT_RUNS`,
`CYMPHO_LOCAL_AGENT_MEMORY_RESERVE_MB`, `POOL_SIZE`, and
`CYMPHO_FINCH_POOL_SIZE` are positive-integer overrides. The local limit may
not exceed the effective total run limit. Explicit overrides win over the
profile. Every runtime, including gateways, consumes the authoritative node
total. Before starting a local process, production admission also requires current
headroom above the configured floor, using the smaller host/cgroup memory value when
both are available. This is a start gate, not a per-process memory reservation;
it fails closed when memory pressure cannot be measured. Gateway work consumes
a total slot but not a local-process slot. Avoid setting a
large DB pool as a substitute for fixing slow queries: each PostgreSQL
connection has a real server-side memory cost.

The total and local-process limits are node-local. The standard deployment runs
one BEAM node per host. If you deliberately co-locate multiple Cympho nodes,
divide the local limits between them; this gate is not a cluster-wide cgroup or
per-process RSS ceiling.

Each admitted run is rebound from its Orchestrator to the registered adapter
worker before provider or CLI work begins. Normal completion, cooperative
cancellation, controller death while that worker remains schedulable, and
admission-manager restarts retain the slot through worker cleanup. Port-backed
workers snapshot and freeze a positive-PID process tree before closing the
Port, then confirm the captured targets are gone before emitting a terminal
result.

This is not an OS containment boundary. A brutally killed adapter worker
cannot run its cleanup, and a descendant that outlives the direct Port child
can escape portable PID-tree discovery. Operators that require authoritative
process containment should run agent commands in a dedicated cgroup or
container. Process start-time rechecks narrow PID reuse during discovery and
retries, but external POSIX signalling still has a final non-atomic
check-to-signal window; pidfd or cgroup-backed custody is required to close it.
A process stuck in uninterruptible kernel sleep, or a permanently
uninspectable process tree, can retain a live cleanup worker and its slot
indefinitely. That fail-closed posture avoids intentionally starting a second
writer in the same workspace, but still requires host-level diagnosis.
Portable discovery caps one process-tree snapshot at 4,096 targets; an unusually
large tree likewise retains its worker and slot for operator containment rather
than being partially released.
Linux normally uses `/proc` for process-tree discovery and falls back to
`pgrep`/`ps`. On the Debian/Ubuntu `apt` path supported by `install.sh`, the
script installs the `procps` package explicitly; operators of other Linux
distributions must install equivalent fallback tools. macOS supplies
`/usr/bin/pgrep` and `/bin/ps`.

Company-scoped Operations pages intentionally show only a coarse shared-capacity
delay signal. Exact node counts, memory samples, and denial counters can reveal
co-tenant activity, so instance operators should use `mix cympho.doctor`,
bounded admission telemetry, and the separately authenticated `/beam` surface
for node-level diagnosis.

### Isolated runtime-preview origin

`PREVIEW_HOST` is mandatory in production and must be an exact hostname that
differs from `APP_HOST`, for example `previews.example.com`. Create DNS records
for both names and terminate TLS for both at the same trusted reverse proxy;
route them to the Cympho endpoint while preserving the original `Host` header.
Cympho enforces the boundary itself: the signed preview-proxy path returns 404
on the application hostname, and every non-preview path returns 404 on the
preview hostname.

Preview links are short-lived signed capabilities (five minutes by default,
configurable with `PREVIEW_TOKEN_MAX_AGE`) and are revoked whenever a service is
stopped or restarted. Do not set a parent-domain or wildcard scope on the
`_cympho_key` application cookie. Preview responses are untrusted agent output;
the proxy strips cookies, authorization headers, `Set-Cookie`, and other
non-allowlisted headers, and never uses a service-supplied URL as its network
target. Deployments upgrading from the preview-identity migration intentionally
leave already-running services unavailable until the trusted launcher observes
and reissues their port identity.

The current Finch/Mint HTTP/1 parser applies response-header count and byte
checks after it has parsed a complete header block. The in-app bounds stop
repeated or accumulated headers and oversized bodies from being retained, but
they are not a parser-level memory bound for one malicious HTTP/1 header block.
Keep untrusted runtime services isolated with OS/container memory limits and
treat this as a residual client-library limitation until a parser-level cap is
available.

### First-owner bootstrap

Production never lets an arbitrary first visitor claim a fresh instance. When
the user table is empty, `/setup` is available only when the service starts
with a `CYMPHO_BOOTSTRAP_SECRET` of at least 32 bytes:

```bash
mix phx.gen.secret
```

Store the generated value in the deployment platform's encrypted environment,
restart, and enter it into the setup form. The value is submitted in the POST
body, is filtered from Phoenix logs, and is never rendered back into the page.
The database transaction and advisory lock make it effectively one-use: after
the first user exists, `/setup` redirects to login regardless of the secret.
Remove the variable and restart after the owner is created. If it is absent on
a fresh production database, `/setup` returns 503 and creates nothing. Dev and
test retain the no-secret local setup flow. `install.sh` seeds an owner
directly, so its normal production path does not need this variable.

### Browser transport and sessions

Production browser session cookies are `Secure`, `HttpOnly`, `SameSite=Lax`,
path-scoped to `/`, and expire in seven days. Dev and test use the same options
without `Secure` so plain-HTTP localhost remains usable.

Every browser session and user API JWT also carries the user's persisted
session version. Signing out atomically increments that version before dropping
the cookie, immediately invalidating the user's other browser sessions and
previous user JWTs server-side. Active LiveView and authenticated company socket
connections are disconnected at the same time. Tokens issued before this
migration are treated as version zero and are invalidated by the first sign-out.
Agent heartbeat/API credentials have their own revocation controls and are not
affected.

Production also redirects HTTP to the configured `APP_HOST` and emits a
one-year HSTS policy. Cympho never uses a request `Host` or forwarded host for
that redirect. It honors only a single `X-Forwarded-Proto: https` value from an
immediate peer listed in `CYMPHO_TRUSTED_PROXY_IPS` (comma-separated exact IP
addresses or IPv4/IPv6 CIDRs). The default allowlist is empty; `install.sh`
explicitly adds loopback for its local Caddy instance. Cympho deliberately
ignores forwarded host and port headers. Its authenticated socket records a
forwarded client IP only when the immediate peer passes this same allowlist.
Add a container proxy's actual source address or network when it does not
connect from loopback; an untrusted or misconfigured peer is redirected instead
of being allowed to assert HTTPS.

`CYMPHO_FORCE_SSL=false` disables Cympho's redirect/HSTS guard only for an
architecture where a trusted edge already makes the application listener
unreachable over plaintext. Keep the default enabled otherwise.

Set `HTTP_BIND_IP=0.0.0.0` only when a trusted reverse proxy or container
network must reach Bandit. Keep PostgreSQL and application ports private; expose
TLS through the reverse proxy. Object storage additionally requires the
`S3_*`/`AWS_*` variables documented in `config/runtime.exs`.

Never put secrets in `APP_HOST`, provider URLs, proxy URLs, issue text, or
command-line arguments that process listings may reveal. Use the application
secret store or the deployment platform's encrypted environment facility.

## Release checks

```bash
mix format --check-formatted
mix cympho.doctor
mix test
mix assets.deploy
mix cympho.compare
```

### Operator doctor

Run `mix cympho.doctor` before starting a new install and after configuration,
database, or storage changes. After `mix compile`, `mix cympho.doctor --json`
emits one versioned machine-readable
report; a failed check exits non-zero. `--strict` also makes warnings fail.
`--probe-endpoint` performs a one-second TCP connection to the configured
listener and is explicitly transport-only, not proof that Cympho, PostgreSQL,
or migrations are ready.

The doctor is non-destructive rather than literally filesystem read-only. It
does not change application, database, or configuration state and does not
start `Cympho.Application`, Dispatcher, Endpoint, agent
providers, or any provider network call. It starts only a two-connection Repo
when needed, executes `SELECT 1`, reads `schema_migrations` using SELECTs, and
then stops that Repo if it started it. Its BEAM counters and memory-pressure
posture describe only the doctor process and its current host view, not a
separately running Cympho service. Each configured local attachment or
import-transfer directory is checked with an exclusive zero-byte probe that is
always removed. It rejects known temporary, checkout, and release-payload
paths, but cannot prove the durability or backup policy of an arbitrary
filesystem mount. Reports contain aggregate
adapter type/health counts and allowlisted runtime facts; they never include
database URLs, environment values, adapter configuration, agent identities,
provider responses, or raw exceptions.

This is a source-checkout diagnostic, not a service manager. It cannot inspect
another BEAM VM's process tree, and malformed production variables rejected
while `config/runtime.exs` loads can prevent Mix itself from reaching the task;
the boot error is then the authoritative diagnosis. Release service status/logs
are available through the read-only `cymphoctl` described below; managed update
and backup commands remain roadmap work.

### Read-only release operator CLI

Native releases and the shipped container include `bin/cymphoctl`, a versioned,
read-only operator CLI:

```bash
bin/cymphoctl version --json
bin/cymphoctl readiness --json --expect-revision <git-sha>
bin/cymphoctl service status --json
bin/cymphoctl service logs --lines 100
bin/cymphoctl service logs --lines 100 --follow
```

The CLI requires Bash, curl, and Python 3. Service status and logs additionally
require systemd and journal access. Readiness connects only to the configured
loopback port, does not follow redirects or use proxy configuration, bounds
connect time, total time, and response size, requires `application/json`, and
validates the exact schema before emitting allowlisted JSON. With
`--expect-revision`, success means the running endpoint reported that exact
build revision and that its application, database, and packaged-migration
checks were ready. It is not a cryptographic remote-attestation protocol.

`service status` combines fixed-unit systemd state with the same readiness
contract; `service logs` accepts only a capped positive line count and passes
fixed arguments directly to `journalctl` without a pager or shell evaluation.
JSON documents go to stdout and operator diagnostics go to stderr.

`deploy.sh` builds from an exact clean Git archive, embeds its revision into the
release and identity manifest, keeps release and validation files root-owned,
and gates cutover on exact-revision readiness. A rollback re-probes the retained
release revision, but it does **not** reverse database migrations. That probe
proves only that the old binary booted against the current schema. Use
expand/contract migrations when a release must remain rollback-compatible;
restore a verified database backup when a migration is not backward compatible.

This foundation does not provide managed install, onboard, update, uninstall,
database-backup, or restore commands. Those remain explicit L5 roadmap work;
do not treat `cymphoctl` as an updater or a backup substitute.

`runtime.local_capacity` validates the total/local relationship and reports
only boolean configuration, probe-availability, and headroom posture. In
production, a disabled memory gate or unavailable probe fails the check; in
development, an unavailable probe warns because development admission is
deliberately slot-only. On Linux, the probe reads `/proc` and walks the
process's cgroup-v2 or conventional cgroup-v1 memory hierarchy, using the
tightest finite ancestor headroom. Detected but unreadable Linux containment
fails closed rather than falling back to host-only data. On non-Linux systems,
Erlang `:os_mon`/`:memsup` supplies a host-memory sample. That fallback is not cgroup-aware
and may start the local `os_mon` application in the short-lived
doctor VM. A pass does not prove the health or current headroom of a separately
running Cympho service.

For release deployments using local attachment storage, set
`CYMPHO_UPLOADS_DIR` to an absolute persistent directory owned by the service
user. `deploy.sh` uses `/opt/cympho/data/uploads`; never store durable uploads
inside a timestamped release or the `/opt/cympho/current` symlink.

Production also requires `CYMPHO_IMPORT_SPOOL_DIR`, even when attachments use
S3. This local spool holds integrity-checked parts for active resumable company
imports and must survive service restarts and release replacement. `deploy.sh`
creates `/opt/cympho/data/import-transfers` with service-user-only permissions
and reconciles the variable into existing environment files without replacing
credentials. The spool is not a substitute for a database or company backup.

Use `mix cympho.compare --strict` to fail when any selected comparison check is
open. The command is a local regression audit, not a latest-Paperclip parity or
resource certificate; the current upstream register and stronger exit evidence
remain in [`paperclip_gap.md`](../paperclip_gap.md).

Run UI smoke tests in Ego Lite at desktop and 390x844 before a UI release.
Confirm login, company switching, Inbox/Decisions, issue creation, Operations,
Pause/Stop/Resume, and the exact adapter path used in production.

## Backups and restore

Back up PostgreSQL with your managed service or `pg_dump`; back up object
storage separately. A company JSON export is a portability aid, not a complete
database backup. Exports intentionally omit secret values, so maintain a
separate encrypted secret inventory and test restoration in an isolated
environment.

Before a restore:

1. Stop or pause autonomous work.
2. Restore the database and object storage to an isolated target.
3. Re-enter omitted secrets through the secret store.
4. Validate company membership and tenant boundaries.
5. Run a single focused issue before resuming the queue.

## Incident response

1. Stop the affected company or issue from Operations.
2. Preserve run IDs, issue IDs, governance audit records, and tool-call trace
   IDs. Do not copy prompt bodies or credentials into a public report.
3. Revoke exposed provider, repository, webhook, and agent credentials.
4. Check for stale/orphaned runs and checkout locks in Operations.
5. Restore service in review mode, then run one focused issue.
6. Record the cause and prevention in an issue or private security advisory.

For exporter setup and the trace redaction contract, see
[Observability](OBSERVABILITY.md). To report a vulnerability, see
[`SECURITY.md`](../SECURITY.md).
