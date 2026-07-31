# Contributing

Thank you for improving Cympho. Changes should stay small, tenant-safe, and
verifiable. The repository's detailed engineering conventions live in
`AGENTS.md` / `CLAUDE.md`.

## Local setup

Follow [`docs/QUICKSTART.md`](docs/QUICKSTART.md), then create a focused branch.
Do not include `.env` files, provider keys, database dumps, private URLs, or
real agent output in commits or fixtures.

## Before coding

1. State the user outcome and acceptance criteria.
2. Identify company-scoping, authorization, spend, and destructive-action
   boundaries.
3. Prefer the smallest end-to-end slice over a broad abstraction.
4. Add a failing regression test for bugs or a focused contract test for new
   behavior.

## Verification

Run the checks proportional to the change:

```bash
mix format --check-formatted
mix test test/path/to_focused_test.exs
mix test
```

For UI or asset changes also run:

```bash
mix assets.deploy
```

Then smoke the changed flow in Ego Lite at desktop and 390x844. Check keyboard
navigation, Simple and Advanced modes, error states, and cross-company access.

## Pull requests

Keep each PR reviewable and include:

- the problem and user-facing outcome;
- changed behavior and important tradeoffs;
- exact tests and smoke evidence;
- migrations, environment variables, rollout, and rollback notes;
- remaining risks or follow-up work.

Do not mix unrelated cleanup with the requested change. Preserve existing user
work in a dirty tree, and do not rewrite shared history or force-push a branch
without explicit coordination.

Security-sensitive findings belong in a private channel described by
[`SECURITY.md`](SECURITY.md), not a public issue or PR.
