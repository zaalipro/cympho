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
LIVE_VIEW_SALT
CYMPHO_ENCRYPTION_KEY
CYMPHO_USER_JWT_SECRET
CYMPHO_AGENT_JWT_SECRET
```

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
