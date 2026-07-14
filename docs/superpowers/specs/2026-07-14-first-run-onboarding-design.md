# First-Run Setup & Company Onboarding

**Date:** 2026-07-14
**Status:** Approved

## Problem

A fresh deploy has no users, no companies, and no way in except a dead login
page. Worse, an authenticated user with no company membership can use the whole
app: `UserAuth` assigns `current_company = nil` and pages silently degrade.
This shipped a real bug in production: a project was created with
`company_id = NULL`, so the sidebar (`Projects.list_for_sidebar(company_id)`)
never shows it, while the global unique index on `projects.prefix` makes
re-creation fail with "has already been taken".

Root causes:

1. `Companies.create_autonomous_company/1` never creates a `CompanyMembership`,
   so even completing the existing `/onboarding` flow leaves the user
   company-less.
2. Nothing routes a company-less user into onboarding or blocks them from
   creating orphan data.
3. `Projects.Project.changeset/2` does not require `company_id` and the DB
   column is nullable.

## Decisions (user-approved)

- Fresh deploy (zero users) → public **setup wizard** creates the owner
  account, then flows into onboarding. Locks itself once any user exists.
- After the first user: **invite-only**. No open signup; `/api/register` is
  gated off by default.
- Onboarding keeps the **blueprint picker** (software, revenue, support,
  research, …) and uses **full blueprint seeding** (goal, project, seed
  issues).
- Team step: **CEO + CTO by default** (from blueprint leadership); the
  **engineering agents are asked about and configured** during onboarding:
  count, names, adapter, optional **command** and **model**.
- Production orphan project (`AILogic`, prefix `AILGC`) is **adopted** into the
  first real company, not deleted.
- **Belt and suspenders**: require `company_id` in the Project changeset and
  make the DB column `NOT NULL` (with adoption backfill).

## Design

### A. Entry gates

**A1. First-run setup (`/setup`)** — controller-based, public pipeline.

- `GET /setup`: if `Repo.aggregate(User, :count) > 0` → redirect `/login`.
  Otherwise render the create-owner form (name, email, password ≥ 8).
- `POST /setup`: inside a transaction taking a Postgres advisory lock
  (`pg_advisory_xact_lock`) re-check user count == 0, then
  `Authentication.register_user/1`. On success reuse
  `SessionController.sign_in/2` and redirect to `/onboarding`. If a user
  already exists (raced or stale form) → redirect `/login`.
- `GET /login` (`SessionController.new`): if user count == 0 → redirect
  `/setup` so a fresh deploy never shows a dead login page. (Count query is
  acceptable on this rarely-hit page; no caching.)

**A2. Require-company gate.**

- LiveView: new `on_mount(:require_company)` appended after
  `{CymphoWeb.UserAuth, :default}` in the `:default`, `:board_governed`, and
  `:authenticated_company_show` live_sessions — except `/onboarding`, which
  moves to its own live_session mounting only `:default`. When
  `current_company == nil` → `{:halt, redirect(to: "/onboarding")}`.
- Controllers: plug `:require_company` in the authenticated browser pipeline
  (company-switcher and logout exempt). Redirects to `/onboarding`.
- API routes are untouched (agents authenticate differently; invites are API).
- Dev flow: `DevSessionController` must keep working — verify the dev user has
  a membership (seeds create a company; add membership in dev login if absent).

**A3. Registration lockdown.**

- `POST /api/register` returns 403 `{"error": "registration is invite-only"}`
  unless `Application.get_env(:cympho, :open_registration, false)` is true.
  Dev/test config may enable it; prod default is locked.

### B. Onboarding wizard (`/onboarding` rebuild)

Six steps, same visual language as the current wizard (step rail, outcome
lines, glow CTA):

1. **Welcome** — what launch creates.
2. **Blueprint** — existing gallery + search (default `software`).
3. **Company** — name, goal title, issue prefix (prefilled from blueprint,
   editable, validated `^[A-Z]{2,10}$`).
4. **Team** —
   - Leadership cards from the blueprint (software: CEO + CTO), names shown.
   - If the blueprint includes engineers: engineer count (0–8, default 2) and
     editable engineer names.
   - Runtime section (applies to all created agents): adapter select
     (`claude_code` default; `codex`, `cursor`, `http`), optional command
     (e.g. `cz`, `cm` wrappers), optional model.
5. **Launch** — review summary; calls the engine (section C); errors surface
   as flash without losing state.
6. **Ready** — bootstrap summary + existing shortcuts content. CTA navigates
   to `/switch-company/:id` so the session `company_id` is set server-side
   (both `assign_current_company` and `resolve_company_for_conn` would also
   fall back to the first membership, but setting it explicitly is cleaner).

### C. Engine changes (`Companies.create_autonomous_company/1`)

New optional attrs, all backward-compatible (seeds/tests unaffected):

- `owner_user_id` — inside the existing transaction, create
  `CompanyMembership{role: "owner", is_board_member: true}`. **This is the
  missing link that caused the production bug.**
- `engineer_names` — list of names for engineer agents; padded/truncated
  against `engineer_count` (count drives).
- `agent_runtime` — `%{"command" => ..., "model" => ...}`; merged into every
  created agent's `runtime_config`: `command` at the top level (read by
  `claude_code_adapter.get_command/1` via the orchestrator's config merge),
  `model` under `runtime_config["env"]["ANTHROPIC_MODEL"]` (injected by
  `Orchestrator.profile_env/1`). Blank values are dropped.

### D. Data hardening

- `Projects.Project.changeset/2`: add `:company_id` to `validate_required`
  plus `foreign_key_constraint`. Fix any test fixtures that relied on
  omitting it.
- Migration (Deploy B only — see rollout):
  1. Adopt orphans: `UPDATE projects SET company_id = (oldest company id)
     WHERE company_id IS NULL` — raise with a clear message if orphans exist
     but no company does.
  2. `ALTER TABLE projects ALTER COLUMN company_id SET NOT NULL`.

### E. Rollout (two-phase, ordering matters)

1. **Deploy A**: all code + gates, *without* the NOT NULL migration. Nick logs
   in → gated into the wizard → creates the real company (membership fixes
   `current_company`).
2. **Deploy B**: ship the migration. It adopts `AILogic` (keeps `AILGC` prefix
   and repo URL) into the now-existing company and locks NOT NULL.

Why two-phase: at Deploy A time production has an orphan project and zero
companies — the backfill has no adoption target, so NOT NULL cannot be applied
yet.

### F. Tests

- **ConnCase / setup**: renders at zero users; creates owner + logs in +
  redirects to onboarding; 302 to `/login` once a user exists (GET and POST);
  advisory-lock race yields exactly one user.
- **ConnCase / gates**: `/login` redirects to `/setup` at zero users;
  authenticated-no-company hitting `/`, `/issues`, `/projects/new` redirects
  to `/onboarding`; with company passes; `/api/register` 403 when locked.
- **LiveCase / wizard**: full walk-through creates company, owner membership,
  CEO + CTO, N engineers with custom names, `runtime_config` carrying
  command/model; user lands with `current_company` set; company-less user is
  halted into `/onboarding` from other live views.
- **DataCase / engine**: `owner_user_id` membership; `engineer_names`
  padding/truncation; `agent_runtime` merge including blank-drop.
- **DataCase / project**: changeset without `company_id` is invalid;
  post-migration insert of NULL `company_id` raises (Deploy B).

## Out of scope

- Browser UI for sending/accepting invites (invites remain API-driven).
- Per-engineer API keys, budgets, instructions in the wizard (Settings later).
- Multi-company switching UX changes.
