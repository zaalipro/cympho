# Quickstart

This path starts Cympho locally in review mode, where you can explore and
configure the product without launching background agents or spending provider
credits.

## Prerequisites

- Elixir `1.19.5-otp-28` and Erlang/OTP `28.4.3` (pinned in `.tool-versions`)
- PostgreSQL reachable at `localhost` with the development credentials in
  `config/dev.exs`
- Git and a shell on macOS or Linux

Use `mise`, `asdf`, or your normal package manager to install the pinned
runtime. Cympho's asset tools are installed through Mix; a global Node project
setup is not required for the normal build.

## Start locally

```bash
git clone https://github.com/zaalipro/cympho.git
cd cympho
mix setup
mix assets.build
mix phx.server
```

Open [http://localhost:4329](http://localhost:4329). To use another port, set
`PORT`, for example `PORT=4000 mix phx.server`.

The development-only owner shortcut creates or signs in the local owner:

```text
http://localhost:4329/dev/login
```

The seeded company and issues are safe to inspect. Development starts with
automatic orchestration disabled.

## Run one controlled autonomy smoke

Autonomous company bootstrap (`Companies.create_autonomous_company/1` and the
onboarding wizard) always inserts a company-scoped `BudgetPolicy` with
`action_on_exceed=block`. A positive monthly limit is required (missing defaults
to $100; explicit `0` is rejected). Runtime hard-stop reads that policy via
`Finances.check_runtime_budget/2` — not `company.budget_monthly_cents` alone.

Before enabling agents, configure the intended project repository, execution
workspace, adapter command/model, credentials, and budget in the UI. Then start
with only the orchestrator enabled:

```bash
CYMPHO_ORCHESTRATOR_ENABLED=1 mix phx.server
```

Use the issue page's readiness panel or Operations console to correct any
missing workspace, runtime, secret, or budget requirement. Keep the company or
individual issue paused until those checks are green.

For a focused issue, add its UUID:

```bash
CYMPHO_ORCHESTRATOR_ENABLED=1 \
CYMPHO_DISPATCH_ONLY_ISSUE_ID=YOUR_ISSUE_UUID \
mix phx.server
```

Provider keys belong in Cympho's secret store or a local untracked environment
file. Never paste them into an issue, comment, screenshot, URL, or commit.

## Verify the checkout

```bash
mix test
mix cympho.compare
```

For deployment, backups, runtime controls, and incident handling, continue with
the [operator guide](OPERATIONS.md). For trace export, see
[observability](OBSERVABILITY.md).

## Common failures

- **Database connection refused:** start PostgreSQL and confirm the local
  database credentials in `config/dev.exs`.
- **Port already in use:** start with a different `PORT`.
- **Agents do not run:** this is expected in review mode; enable the
  orchestrator deliberately and inspect the issue readiness panel.
- **Assets are missing:** run `mix assets.setup` followed by
  `mix assets.build`.
