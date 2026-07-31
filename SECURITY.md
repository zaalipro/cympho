# Security policy

Cympho is a pre-1.0 system that can execute local commands, access repositories,
store provider credentials, and coordinate autonomous agents. Treat every
deployment as privileged infrastructure and keep human review enabled until its
runtime boundaries are configured and tested.

## Reporting a vulnerability

Do not open a public issue containing an exploit, credential, private URL,
tenant data, prompt content, or unredacted logs. Prefer a private GitHub Security
Advisory for this repository. If that channel is unavailable, contact the
repository owner privately and include only enough detail to establish a secure
follow-up channel.

Include:

- affected revision and deployment shape;
- impact and the tenant/role required to reproduce it;
- minimal reproduction steps with synthetic data;
- whether a credential or customer environment may be exposed;
- a proposed mitigation, if known.

Maintainers should acknowledge a complete report promptly, coordinate a fix and
disclosure window with the reporter, and credit the reporter when requested.
There is no public bug-bounty commitment.

## High-priority security scope

- cross-company reads, writes, PubSub events, counters, or cached state;
- authentication, session, JWT, board, agent API-key, and webhook bypasses;
- command, path, archive, SSRF, proxy, or workspace escape;
- secret exposure in logs, traces, imports, exports, screenshots, prompts, or
  browser storage;
- governance/approval bypass or unauthorized dynamic tool execution;
- duplicate execution, stale checkout ownership, or spend-control bypass;
- destructive actions that can cross the selected company/project/issue scope.

## Deployment baseline

- Use unique production values for every required secret in
  `config/runtime.exs`; never reuse development defaults.
- Put the web endpoint behind TLS and a trusted reverse proxy.
- Restrict database, object storage, repository, and provider credentials to the
  minimum required scope.
- Start new deployments in review mode or with companies paused.
- Configure budgets, approvals, execution policies, workspaces, and adapter
  cancellation before enabling autonomy.
- Keep dependencies and the BEAM runtime updated, take tested backups, and
  retain company-scoped audit evidence.
- Use opt-in OTLP tracing only under the redaction contract in
  [`docs/OBSERVABILITY.md`](docs/OBSERVABILITY.md).

Never commit real credentials. If one reaches Git history or an agent prompt,
revoke and rotate it; deleting the visible line is not sufficient.
