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
mix test
mix assets.deploy
mix cympho.compare
```

Use `mix cympho.compare --strict` for a zero-open-gap audit. The normal release
check keeps known, documented gaps visible without making every incremental
release fail until the entire roadmap is complete.

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
