---
spec_id: 04
feature_name: first_run_onboarding
status: ready-for-implementation
created: 2026-07-14
last_updated: 2026-07-15
source_prompt: |
  First-run setup & company onboarding for Cympho — a fresh deploy with no
  users routes to a multi-step setup wizard that creates the owner account,
  then onboards them into a company with CEO + CTO by default and configured
  engineering agents. Design spec at
  docs/superpowers/specs/2026-07-14-first-run-onboarding-design.md and
  implementation plan at docs/superpowers/plans/2026-07-14-first-run-onboarding.md
  already exist.
assumptions:
  - The migration that adopts orphan projects and sets NOT NULL ships as the last code task, and production is deployed in two phases (code first, migration commit second) because production currently holds one orphan project and zero companies — the migration would abort a combined deploy.
  - The Traefik/systemd deployment steps themselves (running ./deploy.sh) are operations work outside this spec's task list; the Rollout Plan documents the exact commands.
  - "CEO CTO should be default" maps to the existing blueprint engine, which always creates CEO and CTO for every blueprint; the wizard's team step displays them as fixed cards rather than adding a new roles system.
  - The runtime "model" value is delivered as runtime_config["env"]["ANTHROPIC_MODEL"] because Cympho.Agents.RuntimeEnv.from_agent/1 (called from Cympho.Runtime.resolve_env/2) injects runtime_config["env"] into agent process environments, and the CLAUDE.md documents ANTHROPIC_MODEL as the provider model export.
  - Registration lockdown defaults to closed with an :open_registration application env override (enabled in config/dev.exs) because the user chose invite-only after the first owner exists.
  - Double-submitting the launch button is guarded in the LiveView (ignore when bootstrap_result is already set) rather than with a DB constraint, because a second company per user is legal in the data model.
  - The onboarding LiveView module and its template are rewritten as whole-file SEARCH/REPLACE blocks (the SEARCH text is the entire current file, which trivially occurs exactly once) in one task, because the rewrite touches nearly every line and the two files form one compile unit; the same applies to the wizard test file. These tasks exceed the ~100-changed-line Form B cap deliberately: a whole-file block is transcription like Form A (which has no line cap), and splitting a full rewrite into partial anchored edits would create fragile intermediate states that do not compile.
  - Making projects.company_id required breaks ~26 existing create_project call sites across nine test files that construct projects without a company; these are updated in dedicated fixture-sweep tasks (TASK-006–TASK-009) so the full suite stays green, rather than by weakening the changeset guard.
  - The wizard's issue-prefix cap is 7 (not the schema's 10) and adds company-name-min-3 / non-blank-goal validation, because the launch engine truncates prefixes to 7 characters and its Repo.insert! calls raise on short slugs or blank goals; the wizard also whitelists the adapter server-side and wraps the launch in a rescue so tampered or invalid input shows the error banner instead of crashing the LiveView.
  - The owner email submitted at /setup is trimmed and downcased before user creation, because authenticate_user/2 matches emails byte-for-byte and there is no password-reset flow to recover from a first-run typo.
---

# 04 — First-Run Setup & Company Onboarding

## Requirements Document

### Introduction

A freshly deployed Cympho instance has no users and no companies, so the operator faces a dead login page, and an authenticated user without a company can create orphan data (a production project was created with a NULL `company_id`, making it invisible in the sidebar while blocking its prefix). This feature adds a one-time first-run setup page that creates the instance owner, a six-step onboarding wizard that launches an autonomous company (CEO + CTO by default, engineering agents configured by the operator), and gates that make company-less sessions impossible to misuse. The audience is the self-hosting operator; the value is a working, populated workspace within minutes of deploying, with no orphan-data bugs.

### Functional Requirements

#### REQ-001 — First-run owner setup page

**User Story**

> As a self-hosting operator on a fresh deploy, I want the app to walk me through creating the owner account, so that I can get in without shell access or seed scripts.

**Acceptance Criteria**

1. **AC-001** — WHEN `GET /setup` is requested AND the `users` table has 0 rows THEN the system responds 200 with a page containing the exact heading text "Create your owner account".
2. **AC-002** — WHEN `GET /setup` is requested AND the `users` table has 1 or more rows THEN the system responds 302 with `Location: /login`.
3. **AC-003** — WHEN `POST /setup` is submitted with a name, an email, and a password of at least 8 characters AND the `users` table has 0 rows THEN the system creates the user, writes the user's id into the session key `:user_id`, and responds 302 with `Location: /onboarding`.
4. **AC-004** — WHEN `POST /setup` is submitted AND the `users` table has 1 or more rows THEN the system responds 302 with `Location: /login` and creates no user.
5. **AC-005** — IF the submitted password is shorter than 8 characters THEN the system responds 200 with a page containing the exact text "at least 8 characters" and creates no user.

#### REQ-002 — Zero-user login redirect

**User Story**

> As a first-time visitor to a fresh deploy, I want the login page to send me to setup instead of showing a form nobody can pass, so that the first-run path is discoverable.

**Acceptance Criteria**

1. **AC-006** — WHEN `GET /login` is requested AND the `users` table has 0 rows THEN the system responds 302 with `Location: /setup`.
2. **AC-007** — WHEN `GET /login` is requested AND the `users` table has 1 or more rows THEN the system responds 200 with the sign-in form (page contains the exact text "Sign in to Cympho").

#### REQ-003 — Company-membership gate

**User Story**

> As an operator, I want users who belong to no company to be routed into onboarding instead of the app, so that no one can create data that belongs to no company.

**Acceptance Criteria**

1. **AC-008** — WHEN an authenticated user with 0 company memberships mounts any LiveView in the `:default`, `:board_governed`, or `:authenticated_company_show` live sessions THEN the socket is halted and redirected to `/onboarding`.
2. **AC-009** — WHEN an authenticated user with 0 company memberships requests a gated controller route (for example `GET /switch-company/<uuid>`) THEN the system responds 302 with `Location: /onboarding`.
3. **AC-010** — WHILE the authenticated user has 1 or more company memberships THE SYSTEM SHALL serve all app routes without redirecting to `/onboarding`.
4. **AC-011** — WHEN an authenticated user with 0 company memberships visits `/onboarding` THEN the wizard renders (no redirect loop) and the page contains the exact text "Step 1 of 6".

#### REQ-004 — Invite-only registration API

**User Story**

> As an operator, I want public self-registration disabled once the owner exists, so that strangers cannot create accounts and companies on my instance.

**Acceptance Criteria**

1. **AC-012** — WHEN `POST /api/register` is requested AND the application env `:cympho, :open_registration` is `false` or unset THEN the system responds 403 with the exact JSON body `{"error":"registration is invite-only"}` and creates no user.
2. **AC-013** — WHEN `POST /api/register` is requested with valid params AND `:cympho, :open_registration` is `true` THEN the system responds 201 and creates the user (pre-existing behavior).

#### REQ-005 — Six-step onboarding wizard

**User Story**

> As a newly signed-in owner, I want a guided wizard — welcome, blueprint, company, team, review, done — so that launching my company is a sequence of small decisions instead of one dense form.

**Acceptance Criteria**

1. **AC-014** — WHEN `/onboarding` mounts THEN the wizard shows 6 steps, starting at a page containing the exact text "Step 1 of 6" and the exact heading "Start an autonomous company".
2. **AC-015** — WHEN the blueprint step is shown THEN the full blueprint gallery renders with its search form, and searching "security" filters the list to show the exact text "1 of 17".
3. **AC-016** — WHEN "Continue" is clicked on the company step AND the issue prefix does not match the regular expression `^[A-Z]{2,7}$` THEN the wizard stays on the company step and shows the exact error text "Issue prefix must be 2-7 uppercase letters." (the cap is 7, not the schema's 10, because the launch engine's `unique_project_prefix/1` truncates prefixes to 7 characters — a wider wizard cap would silently launch a different prefix than the review step displayed).
4. **AC-017** — WHEN the selected blueprint changes THEN the goal and issue-prefix fields are refilled from that blueprint's `default_goal` and `default_prefix` values.

#### REQ-006 — Team step: CEO + CTO default, engineers configured

**User Story**

> As an owner, I want CEO and CTO created by default and my engineering agents configured during onboarding (how many, their names, and what runtime runs them), so that the team matches how I actually work.

**Acceptance Criteria**

1. **AC-018** — WHEN the team step renders THEN it shows a CEO card containing the exact text "Always created." and a CTO card containing the exact text "Always created.".
2. **AC-019** — WHEN the team step renders THEN an engineer-count input with minimum 0, maximum 8, and default value "2" is shown, and one editable name input per engineer appears matching the count.
3. **AC-020** — WHEN the team step renders THEN an adapter select with exactly the options `claude_code`, `codex`, `cursor`, `http` (default `claude_code`) and two optional text inputs labeled "Command" and "Model" are shown.
4. **AC-021** — WHEN the company is launched with command "cz" and model "claude-sonnet-5" THEN every created agent's `runtime_config` map contains `"command" => "cz"` and `"env" => %{"ANTHROPIC_MODEL" => "claude-sonnet-5"}`.

#### REQ-007 — Launch creates a fully owned company

**User Story**

> As an owner, I want one launch action to create the company, my owner seat, all agents, the goal, the project, and the seed issues, so that I land in a working workspace.

**Acceptance Criteria**

1. **AC-022** — WHEN the company is launched THEN a `company_memberships` row exists linking the current user to the new company with `role` exactly `"owner"` and `is_board_member` exactly `true`, and the user's `users.company_id` column is set to the new company's id.
2. **AC-023** — WHEN the company is launched with engineer count 2 and engineer names `["Ada", "Grace"]` THEN exactly two agents with role `:engineer` exist, named exactly "Ada" and "Grace".
3. **AC-024** — WHEN the ready step renders after launch THEN it contains a link with the exact text "Enter Cympho" whose `href` is exactly `/switch-company/<new company id>?return_to=/issues`.
4. **AC-025** — IF the submitted command or model is blank or whitespace-only THEN that key is omitted from `runtime_config`, and every created agent's `runtime_config` still contains `"autonomous" => true`.

#### REQ-008 — Projects always belong to a company

**User Story**

> As an operator, I want project creation without a company to be impossible at both the changeset and database layers, and the existing orphan project adopted, so that the invisible-project bug cannot recur.

**Acceptance Criteria**

1. **AC-026** — WHEN `Cympho.Projects.create_project/1` is called without `company_id` THEN it returns `{:error, changeset}` where `errors_on(changeset).company_id == ["can't be blank"]`.
2. **AC-027** — WHEN the migration `RequireCompanyOnProjects` runs AND orphan projects (NULL `company_id`) exist AND at least one company exists THEN every orphan's `company_id` is set to the oldest company's id (ordered by `inserted_at ASC, id ASC`) and the column becomes NOT NULL.
3. **AC-028** — IF orphan projects exist AND no company exists THEN the migration raises with the exact message "orphan projects exist but no company to adopt them".

### Non-Functional Requirements

#### NFR-001 — Security

1. **AC-029** — WHEN two `POST /setup` requests race THEN at most one user is created, because the insert runs inside a transaction that first takes `pg_advisory_xact_lock(7214001)` and re-checks that the user count is 0.
2. **AC-030** — WHEN the owner is created via `/setup` THEN the password is stored only as an Argon2 hash (the `users.password_hash` value starts with the exact prefix `$argon2`), via the existing `Cympho.Authentication.register_user/1`.

#### NFR-002 — Performance

1. **AC-031** — WHEN `GET /login` or `GET /setup` is served THEN the zero-user check issues exactly one query, `Repo.aggregate(User, :count)`, and no caching layer is added.

#### NFR-003 — Accessibility

1. **AC-032** — WHEN any wizard or setup form input renders THEN it has a visible `<label>` element naming the field (verified by the Manual QA script, steps 3, 6, and 8).

#### NFR-004 — Observability

None — the feature reuses the existing flash-message and Phoenix request logging; no new log lines, metrics, or alerts are introduced.

#### NFR-005 — Reliability

1. **AC-033** — IF any insert inside `Companies.create_autonomous_company/1` fails (including an unknown `owner_user_id`, which rolls back with `{:error, :owner_not_found}`) THEN no company, membership, project, goal, agent, or issue row persists, because the whole launch runs in one `Repo.transaction` using `Repo.insert!`.

#### NFR-006 — Compatibility

1. **AC-034** — WHEN `Companies.create_autonomous_company/1` is called without the new keys `owner_user_id`, `engineer_names`, or `agent_runtime` (as `priv/repo/seeds.exs`, `CymphoWeb.DevSessionController`, and `Cympho.Smoke.Llmotions` do) THEN behavior is unchanged: no membership row is created, engineers are named "Engineer 1"…"Engineer N", and every agent's `runtime_config` equals `%{"autonomous" => true}`. (Seeds compatibility is exercised by `mix ecto.reset` after TASK-003 fixes its pre-existing `first_issue:` destructuring bug; `mix test` never runs seeds.)

### Out of Scope

- A browser UI for sending or accepting company invites. **Known limitation:** the existing `POST /api/invites/:token/accept` endpoint sits behind `CymphoWeb.Plugs.UserAuth`, which returns 401 for users with zero memberships — so a freshly created, not-yet-membered user cannot accept an invite through it. Until that is fixed (out of scope here), the working second-user path is owner-driven: the owner creates the user (`POST /api/users`) or adds an existing user as a member (`POST /api/companies/:id/members`).
- Per-engineer API keys, budgets, instructions, or secrets in the wizard (configured later in Settings).
- Changes to the multi-company switching UX.
- Running `./deploy.sh` itself (operations work; commands are documented in the Rollout Plan).
- Password reset / email verification flows for the owner account.
- **Wizard state persistence.** All wizard state lives in the LiveView socket assigns. A page refresh, deploy, or network reconnect restarts the wizard at step 1 with entered values lost — acceptable for a one-time flow. If a reconnect happens *after* a successful launch but before "Enter Cympho" is clicked, the created company already exists and its owner membership is set, so the user is no longer company-less and can reach it via "Skip setup" → `/issues` (the Skip button now renders for them).
- **Multi-tab / concurrent launches.** The double-launch guard is per-socket (`bootstrap_result`), so two browser tabs are two sockets and can create two companies. A second company per user is legal in the data model; this is intentionally not prevented. (Relevant to Phase B adoption — see the Rollout Plan's operator note about the oldest-company target.)

### User Journeys

1. **Happy path (fresh deploy):** operator opens the domain → `/login` redirects to `/setup` → fills name, email, password → lands on `/onboarding` step 1 → Continue → picks the "software" blueprint → Continue → names the company, edits goal and prefix → Continue → sees CEO/CTO cards, sets 2 engineers named "Ada" and "Grace", adapter `claude_code`, command `cz` → Continue → reviews the summary → clicks "Launch autonomous company" → sees the created company summary and keyboard shortcuts → clicks "Enter Cympho" → lands on `/issues` with the sidebar showing the project and agents.
2. **Alternate path (existing user, no company):** a user signs in at `/login` but belongs to no company → any app URL redirects to `/onboarding` → the user completes steps 2–6 as above.
3. **Alternate path (invalid prefix):** on the company step the user types prefix "bad" → Continue shows "Issue prefix must be 2-7 uppercase letters." and the wizard stays on the company step until fixed.

### Terminology

| Term | Definition |
| --- | --- |
| First-run setup | The one-time `/setup` page that creates the instance owner while the `users` table is empty. |
| Blueprint | A predefined company template (key, roster of agent roles, default goal/prefix, seed issues) from `Cympho.Companies.autonomous_company_blueprints/0`. |
| Launch | The single `Companies.create_autonomous_company/1` transaction that creates the company, membership, project, goal, agents, and seed issues. |
| Orphan project | A `projects` row whose `company_id` is NULL, invisible to the company-scoped sidebar. |
| Gate | The `on_mount(:require_company)` hook / `require_company` plug pair that redirects company-less users to `/onboarding`. |
| Agent runtime | The wizard's adapter + command + model choices, persisted into each agent's `runtime_config` map. |

---

## Plan Document

### Introduction

The feature is implemented in three layers on Phoenix 1.8 / LiveView 1.1. First, `Cympho.Companies.create_autonomous_company/1` gains three optional, backward-compatible inputs (`owner_user_id`, `engineer_names`, `agent_runtime`) so a launch can create the owner's `CompanyMembership` and configure engineer agents in the same transaction. Second, access gates are added: a controller-served `/setup` page (advisory-lock-guarded owner creation), a zero-user redirect in `SessionController.new/2`, an `on_mount(:require_company)` LiveView hook plus a `require_company` conn plug, and an invite-only lock on `POST /api/register`. Third, `CymphoWeb.OnboardingLive.Index` is rebuilt as a six-step wizard. Data hardening lands as a Project changeset change plus a final migration that adopts orphans and sets `projects.company_id` NOT NULL. Success criteria: all new tests pass, `mix test` stays green, and a fresh `mix ecto.reset` dev instance walks the full journey.

### Understanding

The user's request: when a fresh Cympho deploy has no users, the app must show a multi-step onboarding that creates the first user and helps them create their agents — CEO and CTO by default, with engineering agents asked about and configured during onboarding. A design document and an implementation plan already exist in the repo; this spec turns them into a mechanical task list.

Key objectives:

- Zero-user deploys route to a setup wizard; the wizard locks itself after the first user exists.
- After the owner exists, additional users join by invite only.
- Onboarding keeps the blueprint picker and full blueprint seeding (goal, project, seed issues).
- CEO + CTO are always created; the wizard's team step configures engineer count, names, adapter, command, and model.
- Company-less users cannot reach app routes; the production orphan project is adopted, and `projects.company_id` becomes NOT NULL.

Ambiguities resolved by assumption (each also listed in the metadata header):

- **Assumption:** the NOT NULL migration is the last task and production deploys in two phases — production currently has one orphan project and zero companies, so a combined deploy would abort mid-migration.
- **Assumption:** running `./deploy.sh` itself is operations work outside the task list — the Rollout Plan documents the exact deploy and rollback commands.
- **Assumption:** "CEO CTO should be default" is satisfied by the existing engine (every blueprint creates both) and surfaced as fixed cards in the team step.
- **Assumption:** the model value is persisted as `runtime_config["env"]["ANTHROPIC_MODEL"]` because `Cympho.Agents.RuntimeEnv.from_agent/1` (called from `Cympho.Runtime.resolve_env/2`) injects `runtime_config["env"]` into the agent's process environment, and the project documents `ANTHROPIC_MODEL` as the model export.
- **Assumption:** registration lockdown is an `:open_registration` app env (default closed, `true` in dev).
- **Assumption:** double-clicking Launch is guarded in the LiveView by ignoring the event when `bootstrap_result` is already set.
- **Assumption:** the onboarding LiveView module and template (and the wizard test file) are replaced with whole-file SEARCH/REPLACE blocks in single tasks — the rewrites touch nearly every line and each SEARCH (the entire current file) trivially matches exactly once. These tasks intentionally exceed the ~100-changed-line Form B cap: a whole-file block is pure transcription (the same property that exempts Form A from a line cap), while splitting the rewrite into partial anchored edits would create intermediate states that do not compile.
- **Assumption:** requiring `company_id` on projects breaks ~26 pre-existing `create_project` call sites across nine test files; these are fixed in dedicated fixture-sweep tasks (TASK-006–TASK-009) so the full suite stays green, rather than by weakening the changeset. Verified empirically: without these sweeps, the suite fails with ~99 `company_id: {"can't be blank"}` errors.
- **Assumption:** the wizard caps the issue prefix at 7 characters (not the schema's 10) and validates company name ≥ 3 chars and a non-blank goal, because the engine truncates prefixes to 7 and its `Repo.insert!` calls raise on short slugs / blank goals; it also whitelists the adapter server-side and rescues the launch call so bad input shows the error banner rather than crashing the socket.
- **Assumption:** the owner email is trimmed and downcased at `/setup` before user creation, because `authenticate_user/2` matches byte-for-byte and there is no password-reset flow.
- **Assumption:** the Phase B production rollback targets migration version `20260715000000` (not the prior version) because `Ecto.Migrator.run(:down, to:)` is inclusive; targeting the prior version would also roll back and drop `launch_items`.

### Solution Design

**High-level approach** — Reuse the existing, battle-tested launch engine (`create_autonomous_company/1`) rather than building a parallel onboarding path; extend it with the three missing inputs. Put the enforcement at the framework seams every request already passes through (`on_mount` hooks, router pipelines), so no individual LiveView or controller needs editing. Rebuild only the onboarding LiveView UI.

**Data flow & architecture**

```
GET /login ──(0 users)──► GET /setup ──POST /setup──► Authentication.register_user/1
                                                   └► SessionController.sign_in/2 ─► redirect /onboarding
LiveView mount (any app route)
  on_mount :default  ─► assigns current_user / user_companies / current_company
  on_mount :require_company ─(current_company nil)─► redirect /onboarding
OnboardingLive step 5 "Launch"
  └► Companies.create_autonomous_company(%{..., "owner_user_id" => user.id})
        Repo.transaction:
          Company → CompanyMembership(owner, board) → User.company_id update
          → Project → Goal → CEO → CTO → engineers(names) → Product/Design → extras → seed Issues
          (every agent gets runtime_config merged from agent_runtime)
  └► ready step link: /switch-company/<company id>?return_to=/issues (sets session company_id)
```

**Step-by-step execution plan**

1. Extend the launch engine (`companies.ex`) with `owner_user_id`, `engineer_names`, `agent_runtime` + unit tests.
2. Require `company_id` in the Project changeset + unit tests.
3. Add `on_mount(:require_company)` and `require_company/2` to `CymphoWeb.UserAuth`; rewire the router (dedicated onboarding live session, `:company_scoped` pipeline, gate on three live sessions) + gate tests.
4. Create `SetupController` (GET/POST `/setup`), redirect zero-user `/login`, fix the two zero-user login tests + setup tests.
5. Lock `POST /api/register` behind `:open_registration` + tests; enable in dev config.
6. Rebuild `OnboardingLive.Index` module and template as the six-step wizard + LiveView tests.
7. Run `mix format` and the full suite; manual QA on a fresh dev DB.
8. Add the orphan-adoption + NOT NULL migration (deployed as phase B).

**Edge cases & failure handling**

- **EDGE-001** — WHEN two `POST /setup` requests race THEN exactly one user row exists afterward; the loser's transaction re-checks the count under `pg_advisory_xact_lock(7214001)` and rolls back with `:already_configured`. WHEN the loser is the same browser double-submitting (its session already carries the winner's `:user_id`) THEN it is redirected to `/onboarding`; otherwise the loser is redirected to `/login`.
- **EDGE-002** — WHEN `create_autonomous_company` receives an `owner_user_id` that matches no user THEN the transaction rolls back and returns `{:error, :owner_not_found}`; no company row persists.
- **EDGE-003** — WHEN `engineer_names` has fewer entries than `engineer_count`, or contains blank/whitespace entries THEN missing or blank positions fall back to the exact default names "Engineer 1", "Engineer 2", … by position.
- **EDGE-004** — IF `agent_runtime` command and model are blank or whitespace-only THEN `runtime_config` contains neither a `"command"` nor an `"env"` key, and still contains `"autonomous" => true`.
- **EDGE-005** — WHEN "Continue" is clicked on the company step with an issue prefix not matching `^[A-Z]{2,7}$` THEN the wizard does not advance and shows the exact error "Issue prefix must be 2-7 uppercase letters."; WHEN the company name is blank THEN it shows the exact error "Company name is required."; WHEN the trimmed company name is shorter than 3 characters THEN it shows the exact error "Company name must be at least 3 characters." (the derived slug must satisfy the schema's `validate_length(:slug, min: 3)`); WHEN the company goal is blank or whitespace-only THEN it shows the exact error "Company goal is required." (an empty string is truthy in Elixir, so it would otherwise reach `Goal.changeset` and raise).
- **EDGE-006** — WHEN "Launch autonomous company" is clicked a second time while `bootstrap_result` is already set THEN the second event is ignored (handler returns the socket unchanged) and no second company is created.
- **EDGE-007** — WHEN a company-less user visits `/onboarding` THEN the page renders normally — the onboarding live session mounts only `:default`, never `:require_company`, so no redirect loop is possible.
- **EDGE-008** — WHEN the migration runs on a database with orphan projects and zero companies THEN it raises with the exact message "orphan projects exist but no company to adopt them" and the transaction aborts (column stays nullable).
- **EDGE-009** — The "Skip setup" button renders only for users who already have a company (navigating them to `/issues`); WHEN a company-less client forges the `skip` event anyway THEN the wizard stays put and shows the exact error "Finish setup to enter Cympho." (defense in depth — the handler does not trust the template guard).
- **EDGE-010** — WHEN the launch fails inside the LiveView THEN the wizard shows the error banner text `Could not create company: ` followed by `inspect(reason)` and stays on the current step. The engine uses `Repo.insert!` throughout, so most failures surface as raises, not `{:error, _}` returns — the LiveView wraps the call in a rescue (`Ecto.InvalidChangesetError` → its changeset errors; any other exception → the exception term) so a failed launch never crashes the socket and never wipes the operator's wizard state. Nothing persists either way; the transaction rolls back. (Accepted trade-off: `inspect(reason)` can expose changeset internals to the wizard user — acceptable on a self-hosted instance where everyone reaching the wizard is trusted; the wizard's own validations make this banner a rare fallback.)
- **EDGE-011** — WHEN the submitted adapter is not one of `claude_code`, `codex`, `cursor`, `http` (a tampered `<select>` payload — `normalize_adapter/1` in the engine accepts any existing atom, so e.g. `"process"` would otherwise pass) THEN the wizard coerces it to `"claude_code"` before launch.
- **EDGE-012** — WHEN the owner submits `POST /setup` with a padded or mixed-case email (e.g. `" Nick@Example.COM "`) THEN the email is trimmed and downcased before `register_user/1`, because `authenticate_user/2` matches emails byte-for-byte and a first-run typo would permanently lock out the only owner on an instance with no password-reset flow.

**Scalability & performance** — All new queries are single-row or count aggregates on primary keys. The zero-user count query runs only on `/login` and `/setup` requests (rare pages). The gate adds no queries: it reads `socket.assigns.current_company` / `conn.assigns.current_company`, both already computed by the existing auth code.

**Decisions**

- **DES-001** — Extend `create_autonomous_company/1` with optional attrs instead of a new onboarding-specific engine, keeping seeds/dev-login callers unchanged. satisfies: REQ-006, REQ-007
- **DES-002** — Enforce the company requirement at live_session `on_mount` and router pipeline level, not per-view. satisfies: REQ-003
- **DES-003** — `/setup` is a plain controller with inline HTML matching `SessionController`'s login page style (no LiveView), since it renders at most twice per instance lifetime. satisfies: REQ-001, REQ-002
- **DES-004** — Concurrency guard for first-user creation is `pg_advisory_xact_lock(7214001)` + re-count inside one transaction. satisfies: REQ-001 (AC-029)
- **DES-005** — Registration lockdown is `Application.get_env(:cympho, :open_registration, false)`, set `true` only in `config/dev.exs`. satisfies: REQ-004
- **DES-006** — The wizard keeps one flat `@company_form` string-keyed map across steps; each step's form posts `phx-change="update_company_form"` and merges into it. satisfies: REQ-005, REQ-006
- **DES-007** — Runtime mapping: command → top-level `runtime_config["command"]` (read by `get_command/1` in the claude_code adapter via the orchestrator's config merge); model → `runtime_config["env"]["ANTHROPIC_MODEL"]` (injected into the agent process environment by `Cympho.Agents.RuntimeEnv.from_agent/1` via `Cympho.Runtime.resolve_env/2`). satisfies: REQ-006 (AC-021)
- **DES-008** — The ready step's "Enter Cympho" is an `href` link to `/switch-company/<id>?return_to=/issues` so the controller writes the session `company_id` server-side. satisfies: REQ-007 (AC-024)
- **DES-009** — Hardening is layered: changeset `validate_required` (immediate) plus a DB NOT NULL migration with orphan adoption (final task, second deploy). satisfies: REQ-008
- **DES-010** — Onboarding gets its own live_session mounting only `{CymphoWeb.UserAuth, :default}`, exempting it from the gate structurally. satisfies: REQ-003 (AC-011)

### Components & Interfaces

- **Cympho.Companies** (modified) — company launch engine. API (unchanged signature, extended attrs): `create_autonomous_company(attrs :: map()) :: {:ok, %{company: Company.t(), project: Project.t(), goal: Goal.t(), blueprint: map(), agents: [Agent.t()], seed_issues: [Issue.t()]}} | {:error, term()}`. New recognized attrs: `owner_user_id :: Ecto.UUID.t() | nil`, `engineer_names :: [String.t()]`, `agent_runtime :: %{optional("command") => String.t(), optional("model") => String.t()}`. New private helpers: `normalize_engineer_names(term()) :: [String.t()]`, `engineer_name([String.t()], pos_integer()) :: String.t()`, `normalize_agent_runtime(term()) :: map()`, `trim_or_nil(term()) :: String.t() | nil`. Path: `lib/cympho/companies.ex`.
- **Cympho.Projects.Project** (modified) — project schema; `changeset(project :: %Project{}, attrs :: map()) :: Ecto.Changeset.t()` now requires `:company_id`. Path: `lib/cympho/projects/project.ex`.
- **CymphoWeb.UserAuth** (modified) — auth plumbing. New: `on_mount(:require_company, params :: map(), session :: map(), socket :: Phoenix.LiveView.Socket.t()) :: {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}` and `require_company(conn :: Plug.Conn.t(), opts :: keyword()) :: Plug.Conn.t()`. Path: `lib/cympho_web/user_auth.ex`.
- **CymphoWeb.SetupController** (created) — first-run owner creation. API: `new(conn :: Plug.Conn.t(), params :: map()) :: Plug.Conn.t()`, `create(conn :: Plug.Conn.t(), params :: map()) :: Plug.Conn.t()`. Path: `lib/cympho_web/controllers/setup_controller.ex`.
- **CymphoWeb.SessionController** (modified) — `new(conn :: Plug.Conn.t(), params :: map()) :: Plug.Conn.t()` gains the zero-user redirect to `/setup`. Path: `lib/cympho_web/controllers/session_controller.ex`.
- **CymphoWeb.RegistrationController** (modified) — `create(conn :: Plug.Conn.t(), params :: map()) :: Plug.Conn.t()` gains the invite-only 403; new private `do_create(conn :: Plug.Conn.t(), user_params :: map()) :: Plug.Conn.t()`. Path: `lib/cympho_web/controllers/registration_controller.ex`.
- **CymphoWeb.Router** (modified) — new `:company_scoped` pipeline, `/setup` routes, dedicated `:onboarding` live_session, gate on three live sessions. Path: `lib/cympho_web/router.ex`.
- **CymphoWeb.OnboardingLive.Index** (modified) — six-step wizard LiveView. Public LiveView callbacks: `mount/3`, `handle_event/3` for events `"next_step"`, `"prev_step"`, `"skip"`, `"update_company_form"`, `"filter_blueprints"`, `"start_autonomous_company"`. Public template helpers: `engineer_count(form :: map()) :: non_neg_integer()`, `engineer_name_value(form :: map(), index :: pos_integer()) :: String.t()`, `selected_blueprint(blueprints :: [map()], form :: map()) :: map()`. Paths: `lib/cympho_web/live/onboarding_live/index.ex`, `lib/cympho_web/live/onboarding_live/index.html.heex`.
- **Cympho.Repo.Migrations.RequireCompanyOnProjects** (created) — orphan adoption + NOT NULL. API: `up() :: :ok`, `down() :: :ok`. Path: `priv/repo/migrations/20260715000000_require_company_on_projects.exs`.

### Data Contracts & API Examples

**`agent_runtime` map** — passed from the wizard into `create_autonomous_company/1`; not stored as-is.

| Field | Type | Nullable | Default | Constraints |
| --- | --- | --- | --- | --- |
| command | string | yes | — | trimmed; dropped when blank |
| model | string | yes | — | trimmed; dropped when blank |

Example instance (Elixir literal):

```elixir
%{"command" => "cz", "model" => "claude-sonnet-5"}
```

**Agent `runtime_config` after launch** — stored in the `agents.runtime_config` JSONB column for every agent created by the launch.

| Field | Type | Nullable | Default | Constraints |
| --- | --- | --- | --- | --- |
| autonomous | boolean | no | true | always present |
| command | string | yes | absent | present only when a non-blank command was submitted |
| env | map | yes | absent | present only when a non-blank model was submitted; contains exactly `{"ANTHROPIC_MODEL": <model>}` |

Example instance (JSON as stored):

```json
{"autonomous": true, "command": "cz", "env": {"ANTHROPIC_MODEL": "claude-sonnet-5"}}
```

**`company_memberships` row created by launch** — existing table; the launch writes one row.

| Field | Type | Nullable | Default | Constraints |
| --- | --- | --- | --- | --- |
| id | binary_id | no | autogenerate | primary key |
| user_id | binary_id | no | — | FK → users.id |
| company_id | binary_id | no | — | FK → companies.id |
| role | string | no | — | exactly "owner" for the launch-created row; allowed values "owner", "admin", "member", "viewer" |
| is_board_member | boolean | no | false | exactly `true` for the launch-created row |
| inserted_at / updated_at | utc_datetime | no | now() | — |

Example instance (Elixir literal):

```elixir
%Cympho.Companies.CompanyMembership{
  user_id: "66008fbe-3254-4124-95a8-53f93232f0c0",
  company_id: "b3e2b1a0-0000-4000-8000-000000000001",
  role: "owner",
  is_board_member: true
}
```

**`@company_form` assign** — the wizard's cross-step state; string-keyed map.

| Field | Type | Nullable | Default | Constraints |
| --- | --- | --- | --- | --- |
| "blueprint" | string | no | "software" | must be a blueprint key |
| "name" | string | no | "Autonomous Software Company" | non-blank at company-step validation |
| "goal_title" | string | no | "Build and run the business autonomously" | — |
| "issue_prefix" | string | no | "LLM" | must match `^[A-Z]{2,7}$` at company-step validation (engine truncates to 7) |
| "engineer_count" | string | no | "2" | parsed with clamp 0..8; parse failure → 2 |
| "engineer_names" | list of string | no | [] | positional; blanks fall back to "Engineer N" |
| "adapter" | string | no | "claude_code" | one of "claude_code", "codex", "cursor", "http" |
| "runtime_command" | string | no | "" | trimmed downstream |
| "runtime_model" | string | no | "" | trimmed downstream |

Example instance (Elixir literal):

```elixir
%{
  "blueprint" => "software",
  "name" => "Wizard Co",
  "goal_title" => "Ship the wizard",
  "issue_prefix" => "WIZ",
  "engineer_count" => "2",
  "engineer_names" => ["Ada", "Grace"],
  "adapter" => "claude_code",
  "runtime_command" => "cz",
  "runtime_model" => "claude-sonnet-5"
}
```

**GET `/setup`** — public (`:browser` pipeline), no authentication.

Request: plain browser GET, no body.

Success — `200 OK` (zero users): HTML page whose body contains:

```html
<h1>Create your owner account</h1>
```

Error — `302 Found` (a user already exists): empty body with header:

```
location: /login
```

**POST `/setup`** — public (`:browser` pipeline), CSRF-protected form post.

Request (form-encoded):

```
_csrf_token=<token>&user[name]=Nick&user[email]=nick@example.com&user[password]=longenough1
```

Success — `302 Found`: session gains `user_id`; headers:

```
location: /onboarding
```

Error — `200 OK` (validation failure, e.g. short password): HTML page whose body contains the exact text:

```
password should be at least 8 characters
```

**POST `/api/register`** — public (`:api` pipeline), JSON.

Request:

```json
{"user": {"name": "New", "email": "new@example.com", "password": "longenough1"}}
```

Success — `201 Created` (only when `:open_registration` is `true`):

```json
{"data": {"id": "b3e2b1a0-0000-4000-8000-000000000002", "email": "new@example.com", "name": "New"}}
```

Error — `403 Forbidden` (default, `:open_registration` unset):

```json
{"error": "registration is invite-only"}
```

### Dependencies

None — no new libraries; the feature uses Phoenix, LiveView, Ecto, and Argon2 already present in `mix.exs`.

### Integration Points

**1. Router — gate pipeline and onboarding live session.**

**Before** — `lib/cympho_web/router.ex` (verbatim from the codebase):

```elixir
  pipeline :authenticated_browser do
    plug :require_authenticated_user
  end
```

**After** — same site with the new pipeline added:

```elixir
  pipeline :authenticated_browser do
    plug :require_authenticated_user
  end

  pipeline :company_scoped do
    plug :require_company
  end
```

**2. Router — main authenticated scope.**

**Before** — `lib/cympho_web/router.ex` (verbatim):

```elixir
  scope "/", CymphoWeb do
    pipe_through [:browser, :authenticated_browser]

    get "/switch-company/:id", CompanySwitcherController, :switch
```

**After** — onboarding gets its own scope; the main scope gains the pipeline:

```elixir
  scope "/", CymphoWeb do
    pipe_through [:browser, :authenticated_browser]

    live_session :onboarding, on_mount: [{CymphoWeb.UserAuth, :default}] do
      live "/onboarding", OnboardingLive.Index
    end
  end

  scope "/", CymphoWeb do
    pipe_through [:browser, :authenticated_browser, :company_scoped]

    get "/switch-company/:id", CompanySwitcherController, :switch
```

**3. Launch engine — membership creation inside the transaction.**

**Before** — `lib/cympho/companies.ex` (verbatim; end of the Company insert):

```elixir
          brand_color: blueprint.brand_color
        })
        |> Repo.insert!()
```

**After** — membership + default-company update appended:

```elixir
          brand_color: blueprint.brand_color
        })
        |> Repo.insert!()

      # Resolve the owner before inserting the membership: the membership
      # changeset carries assoc_constraint(:user), so inserting first would
      # raise Ecto.InvalidChangesetError on the FK instead of reaching the
      # {:error, :owner_not_found} rollback contract.
      if owner_user_id do
        case Cympho.Users.get_user(owner_user_id) do
          {:ok, user} ->
            %CompanyMembership{}
            |> CompanyMembership.changeset(%{
              user_id: owner_user_id,
              company_id: company.id,
              role: "owner",
              is_board_member: true
            })
            |> Repo.insert!()

            user |> Ecto.Changeset.change(company_id: company.id) |> Repo.update!()

          {:error, :not_found} ->
            Repo.rollback(:owner_not_found)
        end
      end
```

**4. Login page — zero-user redirect.**

**Before** — `lib/cympho_web/controllers/session_controller.ex` (verbatim):

```elixir
  def new(conn, params) do
    conn
    |> put_layout(false)
    |> html(sign_in_page(params, Phoenix.Flash.get(conn.assigns.flash, :error)))
  end
```

**After**:

```elixir
  def new(conn, params) do
    if Repo.aggregate(User, :count) == 0 do
      # Fresh instance: no owner yet — send the visitor to first-run setup
      # instead of a login form nobody can pass.
      redirect(conn, to: "/setup")
    else
      conn
      |> put_layout(false)
      |> html(sign_in_page(params, Phoenix.Flash.get(conn.assigns.flash, :error)))
    end
  end
```

### Testing Strategy

- **Unit:** **TEST-001** — verifies: AC-022, AC-023, AC-021, AC-025, AC-034, EDGE-002, EDGE-003, EDGE-004 — engine tests in `test/cympho/companies_onboarding_test.exs`.

  | Case | Setup / input | Action | Expected result |
  | --- | --- | --- | --- |
  | Owner membership created | user via `Cympho.Users.create_user/1`; attrs `%{name: "Owned Co", owner_user_id: user.id}` | `Companies.create_autonomous_company/1` | `Companies.get_membership(user.id, company.id)` returns a row with `role == "owner"` and `is_board_member == true`; reloaded user has `company_id == company.id` |
  | Backward compatible without owner | attrs `%{name: "Legacy Co"}` | `Companies.create_autonomous_company/1` | `Companies.list_memberships(company.id) == []` |
  | Unknown owner rolls back | attrs `%{name: "Ghost Co", owner_user_id: Ecto.UUID.generate()}` | `Companies.create_autonomous_company/1` | returns `{:error, :owner_not_found}`; `Companies.get_company_by_slug("ghost-co") == nil` |
  | Engineer names with padding | attrs `%{name: "Named Co", engineer_count: 3, engineer_names: ["Ada", "Grace", ""]}` | `Companies.create_autonomous_company/1` | engineer-role agent names, in creation order, are exactly `["Ada", "Grace", "Engineer 3"]` |
  | Runtime lands on every agent | attrs `%{name: "Runtime Co", engineer_count: 1, agent_runtime: %{"command" => "cz", "model" => "claude-sonnet-5"}}` | `Companies.create_autonomous_company/1` | every returned agent has `runtime_config["command"] == "cz"`, `runtime_config["env"]["ANTHROPIC_MODEL"] == "claude-sonnet-5"`, `runtime_config["autonomous"] == true` |
  | Blank runtime dropped | attrs `%{name: "Default Runtime Co", engineer_count: 1, agent_runtime: %{"command" => "  ", "model" => ""}}` | `Companies.create_autonomous_company/1` | every returned agent's `runtime_config` has no `"command"` key, no `"env"` key, and `"autonomous" => true` |

- **Unit:** **TEST-002** — verifies: AC-026 — project changeset tests in `test/cympho/projects_company_requirement_test.exs`.

  | Case | Setup / input | Action | Expected result |
  | --- | --- | --- | --- |
  | Missing company rejected | attrs `%{"name" => "Orphan", "prefix" => "ORPH"}` | `Projects.create_project/1` | `{:error, changeset}` with `errors_on(changeset).company_id == ["can't be blank"]` |
  | With company accepted | company via `Companies.create_company/1`; attrs `%{"name" => "Real", "prefix" => "REAL", "company_id" => company.id}` | `Projects.create_project/1` | `{:ok, project}` with `project.company_id == company.id` |

- **Integration:** **TEST-003** — verifies: AC-008, AC-009, AC-010, AC-011, EDGE-007 — gate tests in `test/cympho_web/require_company_gate_test.exs`.

  | Case | Setup / input | Action | Expected result |
  | --- | --- | --- | --- |
  | Live route gated | session for a user with no membership | `live(conn, "/issues")` | `{:error, {:redirect, %{to: "/onboarding"}}}` |
  | Controller route gated | same session | `get(conn, "/switch-company/<random uuid>")` | `redirected_to(conn) == "/onboarding"` |
  | Onboarding reachable | same session | `live(conn, "/onboarding")` | `{:ok, _view, html}` and `html =~ "Start an autonomous company"` (title text stable across the old and new wizard, since this test lands before the wizard rebuild in task order) |
  | With company passes | `register_and_log_in_user/1` conn | `live(conn, "/issues")` | `{:ok, _view, _html}` |

- **Integration:** **TEST-004** — verifies: AC-001, AC-002, AC-003, AC-004, AC-005, AC-006, AC-029, AC-030, EDGE-001, EDGE-012 — setup tests in `test/cympho_web/controllers/setup_controller_test.exs`. (EDGE-001's true two-request race is verified structurally — the advisory lock + re-count — while the double-submit vector exercises the loser path sequentially.)

  | Case | Setup / input | Action | Expected result |
  | --- | --- | --- | --- |
  | Renders at zero users | empty DB | `get(conn, "/setup")` | 200; body contains "Create your owner account" |
  | Locks after first user | one seeded user | `get(conn, "/setup")` | `redirected_to(conn) == "/login"` |
  | Login redirects at zero users | empty DB | `get(conn, "/login")` | `redirected_to(conn) == "/setup"` |
  | Creates owner + session | empty DB; params `%{"user" => %{"name" => "Nick", "email" => "nick@example.com", "password" => "longenough1"}}` | `post(conn, "/setup", params)` | `redirected_to(conn) == "/onboarding"`; `get_user_by_email("nick@example.com")` returns the user; session `:user_id` equals that user's id; `user.password_hash` starts with `"$argon2"` |
  | Double submit → onboarding | empty DB; same params posted twice, second via `recycle(conn)` carrying the first response's session | `post(recycle(conn), "/setup", params)` | `redirected_to(conn) == "/onboarding"`; exactly 1 user row exists |
  | Normalizes owner email | empty DB; email `"  Nick@Example.COM "` | `post(conn, "/setup", params)` | `redirected_to(conn) == "/onboarding"`; `get_user_by_email("nick@example.com")` returns the user |
  | Refuses when configured | one seeded user; same params with email "late@example.com" | `post(conn, "/setup", params)` | `redirected_to(conn) == "/login"`; `get_user_by_email("late@example.com") == {:error, :not_found}` |
  | Invalid input re-renders | empty DB; password "short" | `post(conn, "/setup", params)` | 200; body contains "at least 8 characters"; no user created |

- **Integration:** **TEST-005** — verifies: AC-012, AC-013 — registration lock tests in `test/cympho_web/controllers/registration_controller_test.exs`.

  | Case | Setup / input | Action | Expected result |
  | --- | --- | --- | --- |
  | Closed by default | `:open_registration` unset; params `%{"user" => %{"name" => "New", "email" => "new@example.com", "password" => "longenough1"}}` | `post(conn, "/api/register", params)` | 403; JSON `error` equals exactly "registration is invite-only"; no user created |
  | Open in dev mode | `Application.put_env(:cympho, :open_registration, true)` (reverted via `on_exit`) | `post(conn, "/api/register", params)` | 201; user exists |

- **End-to-end:** **TEST-006** — verifies: AC-014, AC-015, AC-016, AC-017, AC-018, AC-019, AC-020, AC-021, AC-022, AC-023, AC-024, EDGE-005, EDGE-006, EDGE-009, EDGE-010, EDGE-011 — wizard walk-through in `test/cympho_web/live/onboarding_live_test.exs`.

  | Case | Setup / input | Action | Expected result |
  | --- | --- | --- | --- |
  | Full walk-through | LiveCase conn; blueprint "software"; company "Wizard Co"/"Ship the wizard"/"WIZ"; team 2 engineers ["Ada","Grace"], adapter "claude_code", command "cz", model "claude-sonnet-5" | click Continue ×4 through steps, then click "Launch autonomous company" | ready step contains "Enter Cympho"; `get_company_by_slug("wizard-co")` exists; sole membership has `role == "owner"`, `is_board_member == true`, `membership.user.email =~ "live-user-"`; engineer names sorted are `["Ada", "Grace"]`; every agent has `runtime_config["command"] == "cz"` and `runtime_config["env"]["ANTHROPIC_MODEL"] == "claude-sonnet-5"` |
  | Invalid prefix blocked | LiveCase conn; company step with name "Bad Prefix Co", prefix "bad" | click Continue on company step | page shows exactly "Issue prefix must be 2-7 uppercase letters."; step counter still shows "Step 3 of 6" |
  | Blank goal blocked | LiveCase conn; company step with name "Goalless Co", goal "   ", prefix "GOAL" | click Continue on company step | page shows exactly "Company goal is required."; step counter still shows "Step 3 of 6" |
  | Tampered adapter coerced | LiveCase conn; `render_change(view, "update_company_form", %{"company" => %{"name" => "Tamper Co", "issue_prefix" => "TMP", "adapter" => "process"}})` | `render_click(view, "start_autonomous_company")` | company `tamper-co` exists and every agent's `adapter == :claude_code` |
  | Launch failure shows banner | LiveCase conn; goal set to `String.duplicate("g", 256)` (passes the wizard's blank check, fails `Goal.changeset`'s max-255 inside the transaction) | `render_click(view, "start_autonomous_company")` | page contains "Could not create company:"; `get_company_by_slug("banner-co") == nil` (transaction rolled back; socket alive) |
  | Blueprint filter | LiveCase conn on blueprint step | change `#blueprint-search-form` query to "security" | page shows exactly "1 of 17" |
  | Blueprint refill | LiveCase conn on blueprint step | select blueprint "go_to_market" in `#blueprint-form`, click Continue | company step prefix input HTML contains exactly `value="GTM"` and the goal textarea contains exactly "Launch a repeatable go-to-market motion for the offer" |
  | Double launch ignored | LiveCase conn, wizard already launched "Wizard Co" (slug `wizard-co`) | `render_click(view, "start_autonomous_company")` a second time | `Companies.get_company_by_slug("wizard-co-1") == nil` (no duplicate company; a duplicate would receive the `-1` slug suffix) |
  | Skip with company | LiveCase conn (user has a company) on the welcome step | click "Skip setup" | `{:error, {:live_redirect, %{to: "/issues"}}}` |
  | Skip without company | session for a user with no membership, `/onboarding` mounted | `render_click(view, "skip")` | page shows exactly "Finish setup to enter Cympho." |

- **Regression:** **TEST-007** — verifies: AC-007, AC-034 — the full existing suite plus the two adjusted login tests; `mix test` green proves seeds/dev-login/back-compat paths still work.

  | Case | Setup / input | Action | Expected result |
  | --- | --- | --- | --- |
  | Login form still renders | `registered_user()` seeded first | `get(conn, "/login?return_to=/issues/123")` | 200; body contains `name="return_to" value="/issues/123"` |
  | Whole suite | repo checkout | `mix test` | output ends `0 failures` |

- **Non-functional coverage:** NFR-001 (AC-029, AC-030) is verified by TEST-004's race and hash vectors; NFR-002 (AC-031) is satisfied structurally by TASK-014 — `users_exist?/0` is the single `Repo.aggregate(User, :count)` query and no caching layer is added; NFR-003 (AC-032) is verified by Manual QA steps 3, 6, and 8 below; NFR-004 defines no criteria; NFR-005 (AC-033) is verified by TEST-001's "Unknown owner rolls back" vector; NFR-006 (AC-034) is verified by TEST-001's "Backward compatible without owner" vector and by TEST-007.

- **Manual QA:** numbered script (also the fresh-deploy smoke test):
  1. Run `mix ecto.reset && mix phx.server` → expect server boots with `[info] Running CymphoWeb.Endpoint`.
  2. Open `http://localhost:4000/login` → expect browser lands on `http://localhost:4000/setup` showing exactly "Create your owner account".
  3. Confirm the form shows three labeled fields exactly named "Name", "Email", "Password" → expect all three labels visible.
  4. Submit name "QA Owner", email "qa@example.com", password "longenough1" → expect redirect to `/onboarding` showing exactly "Step 1 of 6".
  5. Click "Continue" → expect the blueprint gallery with the search box and the text "17 of 17".
  6. Click "Continue", type company name "QA Co", prefix "QACO" → expect labeled inputs "Company name", "Company goal", "Issue prefix".
  7. Click "Continue" → expect CEO and CTO cards each containing "Always created.", an "Engineers" number input with value 2, and two name inputs "Engineer 1"/"Engineer 2".
  8. Set command to "cz", confirm labels "Adapter", "Command", "Model" are visible → expect the three runtime fields under the "Agent runtime" legend.
  9. Click "Continue" → expect a review list showing "QA Co", the blueprint name, prefix "QACO", and "claude_code · cz · default model".
  10. Click "Launch autonomous company" → expect "You're all set!" with a summary listing the company, project, agents, and seed issues.
  11. Click "Enter Cympho" → expect `/issues` with the sidebar showing the new project and agents (no "No projects yet.").
  12. In a private window open `http://localhost:4000/setup` → expect redirect to `/login` (setup locked).

### Rollout Plan

- **Migration:** `priv/repo/migrations/20260715000000_require_company_on_projects.exs` adopts orphan projects into the oldest company and sets `projects.company_id` NOT NULL. **Two-phase production rollout:** all tasks — including TASK-022 and the TASK-023 verification sweep — are completed and green locally first; the phasing governs only which commit each production deploy ships. Commit the results of TASK-001–TASK-021 + TASK-023 as one commit (the Phase A commit), then commit `priv/repo/migrations/20260715000000_require_company_on_projects.exs` alone as a final separate commit (the Phase B commit). Phase A deploys from the first commit via `CYMPHO_DEPLOY_PASSWORD='<ssh password>' ./deploy.sh`; the operator (nick@hack.ski) then logs in, is gated into `/onboarding`, and launches the real company. Phase B deploys the migration commit the same way; it adopts the existing "AILogic" orphan (prefix "AILGC") into that company. **Operator note:** the operator must not create additional companies between Phase A and Phase B — adoption targets the *oldest* company (`inserted_at ASC, id ASC`); if more than one exists, verify the oldest is the intended adopter (or fix up with a one-line `UPDATE projects SET company_id = '<id>' WHERE company_id IS NULL` before Phase B).
- **Backwards compatibility:** `create_autonomous_company/1` callers without new attrs are unchanged (AC-034). Existing tests' fixtures already create memberships (`ConnCase.register_and_log_in_user/1`, `LiveCase.authenticated_conn/1`), so gates do not break them. `DevSessionController.ensure_dev_owner!` already ensures a membership for the dev login.
- **Rollback:** Phase B only — run on the host: `sudo -u cympho /opt/cympho/current/bin/cympho eval 'Cympho.Release.rollback(Cympho.Repo, 20260715000000)'`. `Ecto.Migrator.run(:down, to: version)` is **inclusive** — it rolls back every migration with `version >= target` — so the target must be the new migration itself; targeting `20260704000000` would also roll back `create_launch_items` and drop that table. The new migration's `down/0` drops the NOT NULL but intentionally does **not** re-orphan adopted projects (reversing adoption would recreate the invisible-project bug). Code rollback for either phase: re-deploy the previous release directory by re-pointing `/opt/cympho/current` (deploy.sh keeps the 5 most recent under `/opt/cympho/releases`) and `sudo systemctl restart cympho`.
- **Observability:** None — reuses existing Phoenix request logs and flash messages; no new log lines, metrics, or alerts.
- **Feature flags:** `:cympho, :open_registration` (boolean app env, default `false`, `true` in `config/dev.exs`) gates `POST /api/register`. No flag for the wizard itself — the gates are the safety mechanism.

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| NOT NULL migration deployed before the operator creates a company (orphans + zero companies → boot-blocking failed deploy) | Medium | High | Migration is the last commit; two-phase rollout documented in Rollout Plan; migration raises loudly rather than corrupting data. |
| A hidden code path still inserts projects without company_id (agent actions, API) | Low | Medium | Changeset-level `validate_required` catches every `Projects.create_project/1` caller; DB NOT NULL catches raw inserts. |
| Gate redirect loop if /onboarding accidentally inherits :require_company | Low | High | Onboarding lives in its own live_session mounting only `:default` (DES-010); TEST-003 asserts reachability. |
| Existing tests assume no gate and break | Medium | Low | Both test-case helpers already create memberships; the two zero-user login tests are fixed in TASK-015. |
| Double launch creates two companies for one user | Low | Low | EDGE-006 guard: `start_autonomous_company` ignores the event when `bootstrap_result` is set. |

### Research

None — no external dependencies; the feature is built entirely on libraries already in `mix.exs` (Phoenix 1.8, LiveView 1.1, Ecto, Argon2 via `argon2_elixir`).

### Codebase Analysis

- **Patterns:** Phoenix context modules as public APIs (`Cympho.Companies`, `Cympho.Projects`, `Cympho.Users`, `Cympho.Authentication`); LiveViews under `lib/cympho_web/live/<area>_live/` with sibling `.heex` templates; controllers render inline HTML strings for the pre-auth pages (see `SessionController.sign_in_page/2`); all schemas use `:binary_id` keys and `:utc_datetime` timestamps.
- **Conventions:** string-keyed form params merged into assigns maps; router pipelines delegate to `CymphoWeb.UserAuth`:

```elixir
  defp require_authenticated_user(conn, opts) do
    CymphoWeb.UserAuth.require_authenticated_user(conn, opts)
  end
```

- **Testing approach:** `Cympho.DataCase` (with `errors_on/1`), `CymphoWeb.ConnCase` (with `register_and_log_in_user/2` creating user+company+membership), `CymphoWeb.LiveCase` (with `authenticated_conn/1` doing the same and stashing the conn in the process dictionary). SQL sandbox in manual mode; `async: false` for tests touching global app env.
- **Similar implementations:** `lib/cympho_web/controllers/session_controller.ex` — inline-HTML pre-auth page with CSRF token (the `/setup` page copies its style); `lib/cympho_web/controllers/dev_session_controller.ex` — programmatic owner+membership bootstrap (`ensure_dev_owner!/0`).
- **Reusable utilities:** `CymphoWeb.SessionController.sign_in/2` (public; renews the session, sets `:user_id` and `:company_id`, seeds theme cookie); `Cympho.DataCase.errors_on/1`; the engine's `unique_project_prefix/1` and `unique_slug/1` (private, already called inside `create_autonomous_company/1` — no wizard-side uniqueness handling needed).
- **Reference Excerpts** (every existing symbol the new code calls):

  `lib/cympho/authentication.ex` — creates a user with an Argon2-hashed password:

  ```elixir
  def register_user(attrs) do
    %Cympho.Users.User{}
    |> Cympho.Users.User.registration_changeset(attrs)
    |> Repo.insert()
  end
  ```

  `lib/cympho/users.ex` — id and email lookups (both return `{:ok, user} | {:error, :not_found}`):

  ```elixir
  def get_user(id) do
    case Ecto.UUID.cast(id) do
      :error ->
        {:error, :not_found}

      {:ok, _uuid} ->
        case Repo.get(User, id) do
          nil -> {:error, :not_found}
          user -> {:ok, user}
        end
    end
  end

  def get_user_by_email(email) when is_binary(email) do
    case Repo.get_by(User, email: email) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end
  ```

  `lib/cympho/users/user.ex` — registration changeset (requires email, name, password ≥ 8; hashes into `password_hash`):

  ```elixir
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :password, :company_id])
    |> validate_required([:email, :name, :password])
    |> validate_email()
    |> validate_password()
    |> put_password_hash()
    |> unique_constraint(:email)
  end
  ```

  `lib/cympho_web/controllers/session_controller.ex` — session establishment reused by `/setup`:

  ```elixir
  def sign_in(conn, %User{} = user) do
    conn
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    |> put_session(:company_id, default_company_id(user))
    |> seed_theme_cookie(user)
  end
  ```

  `lib/cympho/companies/company_membership.ex` — membership changeset the launch inserts through. Note `assoc_constraint(:user)`: an insert with a nonexistent `user_id` raises `Ecto.InvalidChangesetError` under `Repo.insert!`, which is why the launch resolves the user *before* inserting the membership (see TASK-001):

  ```elixir
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :is_board_member, :user_id, :company_id])
    |> validate_required([:role, :user_id, :company_id])
    |> validate_inclusion(:role, ["owner", "admin", "member", "viewer"])
    |> unique_constraint([:user_id, :company_id])
    |> assoc_constraint(:user)
    |> assoc_constraint(:company)
  end
  ```

  `lib/cympho/companies.ex` — membership lookups used by tests:

  ```elixir
  def list_memberships(company_id) do
    from(m in CompanyMembership, where: m.company_id == ^company_id, preload: [:user])
    |> Repo.all()
  end

  def get_membership(user_id, company_id) do
    Repo.get_by(CompanyMembership, user_id: user_id, company_id: company_id)
  end
  ```

  `lib/cympho/companies.ex` — agent listing used by tests (CEO first, CTO second, then by insertion):

  ```elixir
  def list_company_agents(company_id) do
    Cympho.Agents.list_agents_by_company(company_id)
  end
  ```

  `lib/cympho/companies.ex` — blueprint catalog read by the wizard:

  ```elixir
  def autonomous_company_blueprints do
  ```

  ```elixir
  def autonomous_company_blueprint(key) do
  ```

  `lib/cympho/companies.ex` — slug lookup used by tests:

  ```elixir
  def get_company_by_slug(slug) do
  ```

  `lib/cympho/agents/agent.ex` — role label helper kept by the wizard template:

  ```elixir
  def role_label(:ceo), do: "CEO"
  ```

  `lib/cympho/agents/role_playbook.ex` — instruction helpers used inside `create_template_agent!/1`:

  ```elixir
  def default_overrides_template(:ceo) do
  ```

  ```elixir
  def starter_overrides(role, focus \\ nil) do
  ```

  `lib/cympho/projects.ex` — the changeset entry point hardened by TASK-002:

  ```elixir
  def create_project(attrs \\ %{}) do
  ```

  `lib/cympho_web/controllers/company_switcher_controller.ex` — the route the ready step links to (verifies access, writes session `company_id`, redirects to `return_to`):

  ```elixir
  def switch(conn, %{"id" => company_id}) do
  ```

  `deps/phoenix_html/lib/phoenix_html/form.ex` — select-options helper used in the team step:

  ```elixir
  def options_for_select(options, selected_values, extra \\ []) do
  ```

  `test/support/data_case.ex` — changeset error helper used by unit tests:

  ```elixir
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
  ```

  `test/support/conn_case.ex` — the helper gate tests use for the "has company" case:

  ```elixir
  def register_and_log_in_user(conn, attrs \\ %{}) do
  ```

### Build & Verification Commands

| Purpose | Command (from repo root) | Expected success output |
| --- | --- | --- |
| Install dependencies | `mix deps.get` | ends without error |
| Run full test suite | `mix test` | output ends with `0 failures` |
| Run a single test file | `mix test <path>` | output ends with `0 failures` |
| Lint | `mix format --check-formatted` | exits 0, no output |
| Type check | `None — dialyzer is configured but not enforced; not part of task verification` | — |
| Build | `mix compile --warnings-as-errors` | exits 0 |
| Run locally | `mix phx.server` | log line contains `Running CymphoWeb.Endpoint` |
| Reset dev DB | `mix ecto.reset` | ends with the seed output `Skipping seeds;` or `Seeded autonomous company:` |
| Migrate | `mix ecto.migrate` | output contains `Migrated 20260715000000` (after TASK-022) |

**Environment Prerequisites**

| Prerequisite | Check command | Expected result |
| --- | --- | --- |
| Elixir 1.19.5 / OTP 28 | `elixir --version` | last line starts `Elixir 1.19.5` |
| PostgreSQL reachable for tests | `psql "postgresql://paperclip:paperclip@localhost/postgres" -c 'select 1'` | prints `1` and `(1 row)` |
| Test DB migratable | `MIX_ENV=test mix ecto.create --quiet && MIX_ENV=test mix ecto.migrate --quiet; echo ok` | prints `ok` |
| Repo formatted at start | `mix format --check-formatted` | exits 0, no output |

---

## Task List Document

### File Manifest

| Path | Action | Tasks |
| --- | --- | --- |
| `lib/cympho/companies.ex` | modified | TASK-001 |
| `test/cympho/companies_onboarding_test.exs` | created | TASK-002 |
| `priv/repo/seeds.exs` | modified | TASK-003 |
| `lib/cympho/projects/project.ex` | modified | TASK-004 |
| `test/cympho/projects_company_requirement_test.exs` | created | TASK-005 |
| `test/cympho/wakes_test.exs` | modified | TASK-006 |
| `test/cympho/heartbeat_engine/wakeup_queue_test.exs` | modified | TASK-006 |
| `test/cympho/issues_labels_test.exs` | modified | TASK-006 |
| `test/cympho/issues_paginated_filter_test.exs` | modified | TASK-007 |
| `test/cympho/goals_test.exs` | modified | TASK-007 |
| `test/cympho/workspace_test.exs` | modified | TASK-007 |
| `test/cympho/projects_test.exs` | modified | TASK-008 |
| `test/cympho/issues_test.exs` | modified | TASK-009 |
| `test/cympho/approvals_test.exs` | modified | TASK-009 |
| `test/cympho_web/controllers/github_controller_test.exs` | modified | TASK-009 |
| `lib/cympho_web/user_auth.ex` | modified | TASK-010 |
| `lib/cympho_web/router.ex` | modified | TASK-011, TASK-015 |
| `test/cympho_web/require_company_gate_test.exs` | created | TASK-012 |
| `test/cympho_web/user_auth_test.exs` | modified | TASK-013 |
| `lib/cympho_web/controllers/setup_controller.ex` | created | TASK-014 |
| `lib/cympho_web/controllers/session_controller.ex` | modified | TASK-015 |
| `test/cympho_web/controllers/setup_controller_test.exs` | created | TASK-016 |
| `test/cympho_web/controllers/session_controller_test.exs` | modified | TASK-017 |
| `lib/cympho_web/controllers/registration_controller.ex` | modified | TASK-018 |
| `config/dev.exs` | modified | TASK-018 |
| `test/cympho_web/controllers/registration_controller_test.exs` | created | TASK-019 |
| `lib/cympho_web/live/onboarding_live/index.ex` | modified | TASK-020 |
| `lib/cympho_web/live/onboarding_live/index.html.heex` | modified | TASK-020 |
| `test/cympho_web/live/onboarding_live_test.exs` | modified | TASK-021 |
| `priv/repo/migrations/20260715000000_require_company_on_projects.exs` | created | TASK-022 |

### Tasks

- [ ] **TASK-001** [service] Extend `Companies.create_autonomous_company/1` with owner membership, engineer names, and agent runtime.
  - **Paths:** `lib/cympho/companies.ex` (modified)
  - **Implements:** `REQ-006`, `REQ-007`, `DES-001`, `DES-007` · **Verifies:** `TEST-001` covering `AC-021`, `AC-022`, `AC-023`, `AC-025`, `AC-034`, `EDGE-002`, `EDGE-003`, `EDGE-004` · **Depends:** `None`
  - **Context:** The launch engine currently creates a company, project, agents, goal, and seed issues in one `Repo.transaction`, but never creates a `CompanyMembership` (the production orphan bug), names engineers `"Engineer #{index}"`, and `create_template_agent!/1` overwrites `runtime_config` with `%{"autonomous" => true}`. This task adds three optional attrs — `owner_user_id`, `engineer_names`, `agent_runtime` — all backward compatible. `Cympho.Companies.CompanyMembership` is already aliased at the top of the module (line 5); `Cympho.Users.get_user/1` returns `{:ok, user} | {:error, :not_found}`.
  - **Steps:**
    1. Apply edit block 1 to read the three new attrs after the `adapter =` line.
    2. Apply edit block 2 to insert the membership + default-company update right after the Company insert.
    3. Apply edit block 3 to name engineers from `engineer_names`.
    4. Apply edit blocks 4–8 to pass `runtime_config: agent_runtime` into every `create_template_agent!` call and into `create_blueprint_extra_agents!`.
    5. Apply edit block 9 to thread `runtime_config` through `create_blueprint_extra_agents!/3`.
    6. Apply edit block 10 to rewrite `create_template_agent!/1` so attrs-supplied runtime config merges over the default.
    7. Apply edit block 11 to add the private normalizers.
  - **Code:** apply to `lib/cympho/companies.ex`:

    File: `lib/cympho/companies.ex`

```
<<<<<<< SEARCH
    adapter = normalize_adapter(attrs[:adapter] || attrs["adapter"] || :claude_code)
=======
    adapter = normalize_adapter(attrs[:adapter] || attrs["adapter"] || :claude_code)
    owner_user_id = attrs[:owner_user_id] || attrs["owner_user_id"]
    engineer_names = normalize_engineer_names(attrs[:engineer_names] || attrs["engineer_names"])
    agent_runtime = normalize_agent_runtime(attrs[:agent_runtime] || attrs["agent_runtime"])
>>>>>>> REPLACE
```

    File: `lib/cympho/companies.ex`

```
<<<<<<< SEARCH
          brand_color: blueprint.brand_color
        })
        |> Repo.insert!()
=======
          brand_color: blueprint.brand_color
        })
        |> Repo.insert!()

      # Resolve the owner before inserting the membership: the membership
      # changeset carries assoc_constraint(:user), so inserting first would
      # raise Ecto.InvalidChangesetError on the FK instead of reaching the
      # {:error, :owner_not_found} rollback contract.
      if owner_user_id do
        case Cympho.Users.get_user(owner_user_id) do
          {:ok, user} ->
            %CompanyMembership{}
            |> CompanyMembership.changeset(%{
              user_id: owner_user_id,
              company_id: company.id,
              role: "owner",
              is_board_member: true
            })
            |> Repo.insert!()

            user |> Ecto.Changeset.change(company_id: company.id) |> Repo.update!()

          {:error, :not_found} ->
            Repo.rollback(:owner_not_found)
        end
      end
>>>>>>> REPLACE
```

    File: `lib/cympho/companies.ex`

```
<<<<<<< SEARCH
              name: "Engineer #{index}",
              title: "Software Engineer",
              role: :engineer,
              adapter: adapter,
=======
              name: engineer_name(engineer_names, index),
              title: "Software Engineer",
              role: :engineer,
              adapter: adapter,
              runtime_config: agent_runtime,
>>>>>>> REPLACE
```

    File: `lib/cympho/companies.ex`

```
<<<<<<< SEARCH
          name: "CEO",
          title: "Chief Executive Officer",
          role: :ceo,
          adapter: adapter,
=======
          name: "CEO",
          title: "Chief Executive Officer",
          role: :ceo,
          adapter: adapter,
          runtime_config: agent_runtime,
>>>>>>> REPLACE
```

    File: `lib/cympho/companies.ex`

```
<<<<<<< SEARCH
          name: "CTO",
          title: "Chief Technology Officer",
          role: :cto,
          adapter: adapter,
=======
          name: "CTO",
          title: "Chief Technology Officer",
          role: :cto,
          adapter: adapter,
          runtime_config: agent_runtime,
>>>>>>> REPLACE
```

    File: `lib/cympho/companies.ex`

```
<<<<<<< SEARCH
          name: "Product Lead",
          title: "Product Lead",
          role: :product_manager,
          adapter: adapter,
=======
          name: "Product Lead",
          title: "Product Lead",
          role: :product_manager,
          adapter: adapter,
          runtime_config: agent_runtime,
>>>>>>> REPLACE
```

    File: `lib/cympho/companies.ex`

```
<<<<<<< SEARCH
          name: "Design Lead",
          title: "Design Lead",
          role: :designer,
          adapter: adapter,
=======
          name: "Design Lead",
          title: "Design Lead",
          role: :designer,
          adapter: adapter,
          runtime_config: agent_runtime,
>>>>>>> REPLACE
```

    File: `lib/cympho/companies.ex`

```
<<<<<<< SEARCH
        create_blueprint_extra_agents!(blueprint.extra_agents, base_refs, %{
          company_id: company.id,
          project_id: project.id,
          adapter: adapter
        })
=======
        create_blueprint_extra_agents!(blueprint.extra_agents, base_refs, %{
          company_id: company.id,
          project_id: project.id,
          adapter: adapter,
          runtime_config: agent_runtime
        })
>>>>>>> REPLACE
```

    File: `lib/cympho/companies.ex`

```
<<<<<<< SEARCH
          role: spec.role,
          adapter: base_attrs.adapter,
          max_concurrent_jobs: Map.get(spec, :max_concurrent_jobs, 1),
=======
          role: spec.role,
          adapter: base_attrs.adapter,
          runtime_config: Map.get(base_attrs, :runtime_config, %{}),
          max_concurrent_jobs: Map.get(spec, :max_concurrent_jobs, 1),
>>>>>>> REPLACE
```

    File: `lib/cympho/companies.ex`

```
<<<<<<< SEARCH
  defp create_template_agent!(attrs) do
    role = attrs[:role] || attrs["role"]

    attrs =
      Map.update(
        attrs,
        :instructions,
        RolePlaybook.default_overrides_template(role),
        &RolePlaybook.starter_overrides(role, &1)
      )

    %Agent{}
    |> Agent.changeset(
      Map.merge(attrs, %{
        status: :idle,
        context_mode: "company",
        runtime_config: %{"autonomous" => true}
      })
    )
    |> Repo.insert!()
  end
=======
  defp create_template_agent!(attrs) do
    role = attrs[:role] || attrs["role"]
    runtime_config = Map.merge(%{"autonomous" => true}, attrs[:runtime_config] || %{})

    attrs =
      attrs
      |> Map.delete(:runtime_config)
      |> Map.update(
        :instructions,
        RolePlaybook.default_overrides_template(role),
        &RolePlaybook.starter_overrides(role, &1)
      )

    %Agent{}
    |> Agent.changeset(
      Map.merge(attrs, %{
        status: :idle,
        context_mode: "company",
        runtime_config: runtime_config
      })
    )
    |> Repo.insert!()
  end
>>>>>>> REPLACE
```

    File: `lib/cympho/companies.ex`

```
<<<<<<< SEARCH
  defp normalize_engineer_count(_count), do: 2
=======
  defp normalize_engineer_count(_count), do: 2

  defp normalize_engineer_names(names) when is_list(names) do
    Enum.map(names, fn
      name when is_binary(name) -> String.trim(name)
      _ -> ""
    end)
  end

  defp normalize_engineer_names(_), do: []

  defp engineer_name(names, index) do
    case Enum.at(names, index - 1) do
      name when is_binary(name) and name != "" -> name
      _ -> "Engineer #{index}"
    end
  end

  # Builds the extra runtime_config merged into every launched agent.
  # command -> top-level "command" (read by adapters via the orchestrator's
  # config merge); model -> "env"."ANTHROPIC_MODEL" (injected by profile_env).
  defp normalize_agent_runtime(%{} = runtime) do
    command = trim_or_nil(runtime["command"] || runtime[:command])
    model = trim_or_nil(runtime["model"] || runtime[:model])

    %{}
    |> then(fn config -> if command, do: Map.put(config, "command", command), else: config end)
    |> then(fn config ->
      if model, do: Map.put(config, "env", %{"ANTHROPIC_MODEL" => model}), else: config
    end)
  end

  defp normalize_agent_runtime(_), do: %{}

  defp trim_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_or_nil(_), do: nil
>>>>>>> REPLACE
```
  - **Troubleshooting:**
    - `(KeyError) key :runtime_config not found` in `create_template_agent!/1` → the `Map.delete(:runtime_config)` step was skipped → confirm edit block 10 was applied fully.
    - Engineer names all read `"Engineer N"` in a test that passed names → edit block 3 not applied → confirm `name: engineer_name(engineer_names, index),` replaced `name: "Engineer #{index}",` in the engineer loop only.
    - `(FunctionClauseError) no function clause matching in normalize_engineer_names/1` → attrs passed a non-list, non-nil value → the `normalize_engineer_names(_)` fallback clause from edit block 11 is missing; re-apply block 11.
  - **Done when:** `mix compile --warnings-as-errors` exits 0 and TASK-002's tests pass.
  - **Verify:** `mix compile --warnings-as-errors` — exits 0.

- [ ] **TASK-002** [test] Add engine unit tests for owner membership, engineer names, and agent runtime.
  - **Paths:** `test/cympho/companies_onboarding_test.exs` (created)
  - **Implements:** `REQ-006`, `REQ-007`, `DES-001`, `DES-007` · **Verifies:** `TEST-001` covering `AC-021`, `AC-022`, `AC-023`, `AC-025`, `AC-034`, `EDGE-002`, `EDGE-003`, `EDGE-004` · **Depends:** `TASK-001`
  - **Context:** TASK-001 added the three new attrs to `Companies.create_autonomous_company/1`. This test file locks in the TEST-001 vector table. `Cympho.Users.create_user/1`, `Companies.get_membership/2`, `Companies.list_memberships/1`, and `Companies.get_company_by_slug/1` all exist.
  - **Steps:**
    1. Create the file at the exact path above with the contents in Code.
    2. Exports: seven tests across four `describe` blocks — owner linkage (2), unknown owner rollback (1), engineer names (1), agent runtime (2), plus the backward-compatible no-owner case.
  - **Code:** complete contents of `test/cympho/companies_onboarding_test.exs`:
    ```elixir
    defmodule Cympho.CompaniesOnboardingTest do
      use Cympho.DataCase, async: true

      alias Cympho.Companies

      defp create_user! do
        {:ok, user} =
          Cympho.Users.create_user(%{
            email: "owner-#{System.unique_integer([:positive])}@example.com",
            name: "Owner",
            password: "password1234"
          })

        user
      end

      describe "create_autonomous_company/1 owner linkage" do
        test "creates an owner board membership and sets the user's default company" do
          user = create_user!()

          {:ok, %{company: company}} =
            Companies.create_autonomous_company(%{name: "Owned Co", owner_user_id: user.id})

          membership = Companies.get_membership(user.id, company.id)
          assert membership.role == "owner"
          assert membership.is_board_member

          {:ok, reloaded} = Cympho.Users.get_user(user.id)
          assert reloaded.company_id == company.id
        end

        test "without owner_user_id no membership is created (backward compatible)" do
          {:ok, %{company: company}} = Companies.create_autonomous_company(%{name: "Legacy Co"})

          assert Companies.list_memberships(company.id) == []
        end

        test "an unknown owner_user_id rolls the whole launch back" do
          assert {:error, :owner_not_found} =
                   Companies.create_autonomous_company(%{
                     name: "Ghost Co",
                     owner_user_id: Ecto.UUID.generate()
                   })

          assert Companies.get_company_by_slug("ghost-co") == nil
        end
      end

      describe "create_autonomous_company/1 engineer names" do
        test "names engineer agents in order, padding with defaults" do
          {:ok, %{agents: agents}} =
            Companies.create_autonomous_company(%{
              name: "Named Co",
              engineer_count: 3,
              engineer_names: ["Ada", "Grace", ""]
            })

          engineer_names =
            agents |> Enum.filter(&(&1.role == :engineer)) |> Enum.map(& &1.name)

          assert engineer_names == ["Ada", "Grace", "Engineer 3"]
        end
      end

      describe "create_autonomous_company/1 agent runtime" do
        test "command and model land in every agent's runtime_config" do
          {:ok, %{agents: agents}} =
            Companies.create_autonomous_company(%{
              name: "Runtime Co",
              engineer_count: 1,
              agent_runtime: %{"command" => "cz", "model" => "claude-sonnet-5"}
            })

          assert agents != []

          for agent <- agents do
            assert agent.runtime_config["command"] == "cz"
            assert agent.runtime_config["env"]["ANTHROPIC_MODEL"] == "claude-sonnet-5"
            assert agent.runtime_config["autonomous"] == true
          end
        end

        test "blank runtime values are dropped and autonomous default is preserved" do
          {:ok, %{agents: agents}} =
            Companies.create_autonomous_company(%{
              name: "Default Runtime Co",
              engineer_count: 1,
              agent_runtime: %{"command" => "  ", "model" => ""}
            })

          for agent <- agents do
            refute Map.has_key?(agent.runtime_config, "command")
            refute Map.has_key?(agent.runtime_config, "env")
            assert agent.runtime_config["autonomous"] == true
          end
        end
      end
    end
    ```
  - **Troubleshooting:** `None — standard DataCase test file.`
  - **Done when:** all seven tests pass.
  - **Verify:** `mix test test/cympho/companies_onboarding_test.exs` — expected output contains `0 failures`.

- [ ] **TASK-003** [setup] Fix the seeds destructuring bug (`first_issue` → `seed_issues`).
  - **Paths:** `priv/repo/seeds.exs` (modified)
  - **Implements:** `REQ-007`, `DES-001` · **Verifies:** `TEST-007` covering `AC-034` · **Depends:** `None`
  - **Context:** `priv/repo/seeds.exs` destructures `{:ok, %{company: company, agents: agents, first_issue: issue}}` from `Companies.create_autonomous_company/1`, but the engine returns the keys `company, project, goal, blueprint, agents, seed_issues` — there is no `first_issue` key, so seeding a fresh database raises `MatchError`. This pre-existing bug blocks every fresh-DB verification gate in this spec (`mix ecto.reset`, Manual QA step 1). `mix test` is unaffected (the test alias never runs seeds).
  - **Steps:**
    1. Apply the SEARCH/REPLACE block in Code to `priv/repo/seeds.exs`.
  - **Code:** apply to `priv/repo/seeds.exs`:

    File: `priv/repo/seeds.exs`

```
<<<<<<< SEARCH
case Companies.list_companies() do
  [] ->
    {:ok, %{company: company, agents: agents, first_issue: issue}} =
      Companies.create_autonomous_company(%{
        name: "Cympho Labs",
=======
case Companies.list_companies() do
  [] ->
    {:ok, %{company: company, agents: agents, seed_issues: [issue | _]}} =
      Companies.create_autonomous_company(%{
        name: "Cympho Labs",
>>>>>>> REPLACE
```
  - **Troubleshooting:**
    - `mix ecto.reset` prints `Skipping seeds;` instead of `Seeded autonomous company:` → the dev DB already had companies when seeds ran → this is the correct existing-data branch; drop and re-run (`mix ecto.reset` always drops first, so this should not occur).
    - `(MatchError) no match of right hand side value` persists → the destructuring edit was not applied → confirm the seeds file now matches on `seed_issues: [issue | _]`.
  - **Done when:** `mix ecto.reset` completes and prints the seeded-company summary.
  - **Verify:** `mix ecto.reset` — output contains `Seeded autonomous company:`.

- [ ] **TASK-004** [model] Require `company_id` in the Project changeset.
  - **Paths:** `lib/cympho/projects/project.ex` (modified)
  - **Implements:** `REQ-008`, `DES-009` · **Verifies:** `TEST-002` covering `AC-026` · **Depends:** `None`
  - **Context:** `Cympho.Projects.Project.changeset/2` currently calls `validate_required([:name, :prefix])`, allowing a project row with a NULL `company_id` (the production orphan bug). This adds `:company_id` to the required set and a matching `foreign_key_constraint`.
  - **Steps:**
    1. Apply the SEARCH/REPLACE block in Code to `lib/cympho/projects/project.ex`.
  - **Code:** apply to `lib/cympho/projects/project.ex`:

    File: `lib/cympho/projects/project.ex`

```
<<<<<<< SEARCH
    |> validate_required([:name, :prefix])
=======
    |> validate_required([:name, :prefix, :company_id])
    |> foreign_key_constraint(:company_id)
>>>>>>> REPLACE
```
  - **Troubleshooting:** `None — single-line changeset addition; failures surface in TASK-005's verify.`
  - **Done when:** the module compiles and TASK-005's tests pass.
  - **Verify:** `mix compile --warnings-as-errors` — exits 0.

- [ ] **TASK-005** [test] Add the project company-requirement unit tests.
  - **Paths:** `test/cympho/projects_company_requirement_test.exs` (created)
  - **Implements:** `REQ-008`, `DES-009` · **Verifies:** `TEST-002` covering `AC-026` · **Depends:** `TASK-004`
  - **Context:** TASK-004 added `:company_id` to the Project changeset's required fields. `Cympho.Companies.create_company/1` and `Cympho.Projects.create_project/1` exist; `Cympho.DataCase` imports `errors_on/1`.
  - **Steps:**
    1. Create the file at the exact path above with the contents in Code.
    2. Exports: two tests — "create_project without company_id is invalid", "create_project with company_id succeeds".
  - **Code:** complete contents of `test/cympho/projects_company_requirement_test.exs`:
    ```elixir
    defmodule Cympho.ProjectsCompanyRequirementTest do
      use Cympho.DataCase, async: true

      alias Cympho.Projects

      test "create_project without company_id is invalid" do
        assert {:error, changeset} =
                 Projects.create_project(%{"name" => "Orphan", "prefix" => "ORPH"})

        assert %{company_id: ["can't be blank"]} = errors_on(changeset)
      end

      test "create_project with company_id succeeds" do
        {:ok, company} =
          Cympho.Companies.create_company(%{
            name: "Proj Co",
            slug: "proj-co-#{System.unique_integer([:positive])}"
          })

        assert {:ok, project} =
                 Projects.create_project(%{
                   "name" => "Real",
                   "prefix" => "REAL",
                   "company_id" => company.id
                 })

        assert project.company_id == company.id
      end
    end
    ```
  - **Troubleshooting:** `None — standard DataCase test file.`
  - **Done when:** both tests pass.
  - **Verify:** `mix test test/cympho/projects_company_requirement_test.exs` — expected output contains `0 failures`.

- [ ] **TASK-006** [test] Add `company_id` to project fixtures: wakes_test.exs, wakeup_queue_test.exs, issues_labels_test.exs.
  - **Paths:** `test/cympho/wakes_test.exs` (modified), `test/cympho/heartbeat_engine/wakeup_queue_test.exs` (modified), `test/cympho/issues_labels_test.exs` (modified)
  - **Implements:** `REQ-008`, `DES-009` · **Verifies:** `TEST-007` covering `AC-026` · **Depends:** `TASK-004`
  - **Context:** TASK-004 made `company_id` required in the Project changeset, so every existing `Projects.create_project/1` call (and direct `%Project{}` insert) without a `company_id` now fails. This task threads a fixture company into the affected call sites in the listed files. Each block creates a company via `Companies.create_company/1` with a unique slug (`System.unique_integer([:positive])`) and passes its id.
  - **Steps:**
    1. Apply the SEARCH/REPLACE blocks in Code, top to bottom, to each listed file.
  - **Code:** apply to the listed files:

    File: `test/cympho/wakes_test.exs`

```
<<<<<<< SEARCH

  setup do
    {:ok, project} =
      Projects.create_project(%{
        name: "Wake Test Project",
        prefix: "WAKE"
      })

=======

  setup do
    {:ok, company} =
      Companies.create_company(%{
        name: "Wake Test Co",
        slug: "wake-test-#{System.unique_integer([:positive])}"
      })

    {:ok, project} =
      Projects.create_project(%{
        name: "Wake Test Project",
        prefix: "WAKE",
        company_id: company.id
      })

>>>>>>> REPLACE
```

    File: `test/cympho/heartbeat_engine/wakeup_queue_test.exs`

```
<<<<<<< SEARCH
      })

    {:ok, project} =
      Cympho.Projects.create_project(%{
        name: "WakeTestProject #{System.unique_integer()}",
        prefix: "WKP"
      })

=======
      })

    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "WakeQueue Co",
        slug: "wake-queue-#{System.unique_integer([:positive])}"
      })

    {:ok, project} =
      Cympho.Projects.create_project(%{
        name: "WakeTestProject #{System.unique_integer()}",
        prefix: "WKP",
        company_id: company.id
      })

>>>>>>> REPLACE
```

    File: `test/cympho/issues_labels_test.exs`

```
<<<<<<< SEARCH

  setup do
    {:ok, project} = Projects.create_project(%{name: "Test", prefix: "TST"})

    {:ok, issue} =
=======

  setup do
    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Labels Co",
        slug: "labels-co-#{System.unique_integer([:positive])}"
      })

    {:ok, project} =
      Projects.create_project(%{name: "Test", prefix: "TST", company_id: company.id})

    {:ok, issue} =
>>>>>>> REPLACE
```
  - **Troubleshooting:**
    - `** (MatchError) ... company_id: {"can't be blank"}` in one of these files after applying → a `create_project` call site was left without `company_id` → re-check each block applied and search the file for remaining bare `create_project(%{` calls.
  - **Done when:** the listed files pass.
  - **Verify:** `mix test test/cympho/wakes_test.exs test/cympho/heartbeat_engine/wakeup_queue_test.exs test/cympho/issues_labels_test.exs` — expected output contains `0 failures`.

- [ ] **TASK-007** [test] Add `company_id` to project fixtures: issues_paginated_filter_test.exs, goals_test.exs, workspace_test.exs.
  - **Paths:** `test/cympho/issues_paginated_filter_test.exs` (modified), `test/cympho/goals_test.exs` (modified), `test/cympho/workspace_test.exs` (modified)
  - **Implements:** `REQ-008`, `DES-009` · **Verifies:** `TEST-007` covering `AC-026` · **Depends:** `TASK-004`
  - **Context:** TASK-004 made `company_id` required in the Project changeset, so every existing `Projects.create_project/1` call (and direct `%Project{}` insert) without a `company_id` now fails. This task threads a fixture company into the affected call sites in the listed files. Each block creates a company via `Companies.create_company/1` with a unique slug (`System.unique_integer([:positive])`) and passes its id.
  - **Steps:**
    1. Apply the SEARCH/REPLACE blocks in Code, top to bottom, to each listed file.
  - **Code:** apply to the listed files:

    File: `test/cympho/issues_paginated_filter_test.exs`

```
<<<<<<< SEARCH

  setup do
    {:ok, project} =
      Projects.create_project(%{name: "FilterProj", prefix: "FP"})

    {:ok, agent} =
=======

  setup do
    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Filter Co",
        slug: "filter-co-#{System.unique_integer([:positive])}"
      })

    {:ok, project} =
      Projects.create_project(%{name: "FilterProj", prefix: "FP", company_id: company.id})

    {:ok, agent} =
>>>>>>> REPLACE
```

    File: `test/cympho/goals_test.exs`

```
<<<<<<< SEARCH
  describe "list_goals_by_project/1" do
    test "returns goals for a given project" do
      {:ok, project} = Cympho.Projects.create_project(%{name: "Proj", prefix: "PRJ"})
      {:ok, goal} = Goals.create_goal(%{title: "Project Goal", project_id: project.id})
      {:ok, _other} = Goals.create_goal(%{title: "Other Goal"})
=======
  describe "list_goals_by_project/1" do
    test "returns goals for a given project" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Goals Co",
          slug: "goals-co-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Cympho.Projects.create_project(%{name: "Proj", prefix: "PRJ", company_id: company.id})
      {:ok, goal} = Goals.create_goal(%{title: "Project Goal", project_id: project.id})
      {:ok, _other} = Goals.create_goal(%{title: "Other Goal"})
>>>>>>> REPLACE
```

    File: `test/cympho/goals_test.exs`

```
<<<<<<< SEARCH

    test "returns empty list for project with no goals" do
      {:ok, project} = Cympho.Projects.create_project(%{name: "Empty", prefix: "EMP"})
      assert [] = Goals.list_goals_by_project(project.id)
    end
=======

    test "returns empty list for project with no goals" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Empty Goals Co",
          slug: "empty-goals-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Cympho.Projects.create_project(%{name: "Empty", prefix: "EMP", company_id: company.id})
      assert [] = Goals.list_goals_by_project(project.id)
    end
>>>>>>> REPLACE
```

    File: `test/cympho/goals_test.exs`

```
<<<<<<< SEARCH

    test "creates goal with all fields" do
      {:ok, project} = Cympho.Projects.create_project(%{name: "Proj", prefix: "PRJ"})

      attrs = %{
=======

    test "creates goal with all fields" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Full Goals Co",
          slug: "full-goals-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Cympho.Projects.create_project(%{name: "Proj", prefix: "PRJ", company_id: company.id})

      attrs = %{
>>>>>>> REPLACE
```

    File: `test/cympho/workspace_test.exs`

```
<<<<<<< SEARCH
  alias Cympho.Workspace

  describe "get_repo_url/1" do
    test "returns repo_url from project settings" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test Project",
          prefix: "TP",
=======
  alias Cympho.Workspace

  # Projects now require a company; create a throwaway one per call so the
  # existing fixtures stay self-contained.
  defp create_project_with_company(attrs) do
    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Fixture Co",
        slug: "fixture-co-#{System.unique_integer([:positive])}"
      })

    attrs |> Map.put_new(:company_id, company.id) |> Projects.create_project()
  end

  describe "get_repo_url/1" do
    test "returns repo_url from project settings" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Test Project",
          prefix: "TP",
>>>>>>> REPLACE
```

    File: `test/cympho/workspace_test.exs`

```
<<<<<<< SEARCH
    test "falls back to app env when project settings has no repo_url" do
      {:ok, project} =
        Projects.create_project(%{
          name: "No Repo Project",
          prefix: "NR"
=======
    test "falls back to app env when project settings has no repo_url" do
      {:ok, project} =
        create_project_with_company(%{
          name: "No Repo Project",
          prefix: "NR"
>>>>>>> REPLACE
```

    File: `test/cympho/workspace_test.exs`

```
<<<<<<< SEARCH
    test "returns error when no repo configured anywhere" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Empty Settings Project",
          prefix: "ES"
=======
    test "returns error when no repo configured anywhere" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Empty Settings Project",
          prefix: "ES"
>>>>>>> REPLACE
```

    File: `test/cympho/workspace_test.exs`

```
<<<<<<< SEARCH
    test "ignores empty string repo_url in project settings" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Empty Repo Project",
          prefix: "ER",
=======
    test "ignores empty string repo_url in project settings" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Empty Repo Project",
          prefix: "ER",
>>>>>>> REPLACE
```

    File: `test/cympho/workspace_test.exs`

```
<<<<<<< SEARCH
    test "ignores non-string repo_url in project settings" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Bad Repo Project",
          prefix: "BR",
=======
    test "ignores non-string repo_url in project settings" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Bad Repo Project",
          prefix: "BR",
>>>>>>> REPLACE
```

    File: `test/cympho/workspace_test.exs`

```
<<<<<<< SEARCH

      {:ok, project} =
        Projects.create_project(%{
          name: "Branch Project",
          prefix: "BP",
=======

      {:ok, project} =
        create_project_with_company(%{
          name: "Branch Project",
          prefix: "BP",
>>>>>>> REPLACE
```
  - **Troubleshooting:**
    - `** (MatchError) ... company_id: {"can't be blank"}` in one of these files after applying → a `create_project` call site was left without `company_id` → re-check each block applied and search the file for remaining bare `create_project(%{` calls.
  - **Done when:** the listed files pass.
  - **Verify:** `mix test test/cympho/issues_paginated_filter_test.exs test/cympho/goals_test.exs test/cympho/workspace_test.exs` — expected output contains `0 failures`.

- [ ] **TASK-008** [test] Add `company_id` to project fixtures: projects_test.exs.
  - **Paths:** `test/cympho/projects_test.exs` (modified)
  - **Implements:** `REQ-008`, `DES-009` · **Verifies:** `TEST-007` covering `AC-026` · **Depends:** `TASK-004`
  - **Context:** TASK-004 made `company_id` required in the Project changeset, so every existing `Projects.create_project/1` call (and direct `%Project{}` insert) without a `company_id` now fails. This task threads a fixture company into the affected call sites in the listed files. Each block creates a company via `Companies.create_company/1` with a unique slug (`System.unique_integer([:positive])`) and passes its id.
  - **Steps:**
    1. Apply the SEARCH/REPLACE blocks in Code, top to bottom, to each listed file.
  - **Code:** apply to the listed files:

    File: `test/cympho/projects_test.exs`

```
<<<<<<< SEARCH
  alias Cympho.Projects.Project

  describe "list_projects/0" do
    test "returns all projects" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test Project",
          prefix: "TST",
=======
  alias Cympho.Projects.Project

  # Projects now require a company; create a throwaway one per call so the
  # existing fixtures stay self-contained.
  defp create_project_with_company(attrs) do
    {:ok, company} =
      Companies.create_company(%{
        name: "Fixture Co",
        slug: "fixture-co-#{System.unique_integer([:positive])}"
      })

    attrs |> Map.put_new(:company_id, company.id) |> Projects.create_project()
  end

  describe "list_projects/0" do
    test "returns all projects" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Test Project",
          prefix: "TST",
>>>>>>> REPLACE
```

    File: `test/cympho/projects_test.exs`

```
<<<<<<< SEARCH
    test "returns the project with given id" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test Project",
          prefix: "TST"
=======
    test "returns the project with given id" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Test Project",
          prefix: "TST"
>>>>>>> REPLACE
```

    File: `test/cympho/projects_test.exs`

```
<<<<<<< SEARCH
    test "returns {:ok, project} for valid id" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test Project",
          prefix: "TST"
=======
    test "returns {:ok, project} for valid id" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Test Project",
          prefix: "TST"
>>>>>>> REPLACE
```

    File: `test/cympho/projects_test.exs`

```
<<<<<<< SEARCH
    test "returns {:ok, project} for valid prefix" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test Project",
          prefix: "TST"
=======
    test "returns {:ok, project} for valid prefix" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Test Project",
          prefix: "TST"
>>>>>>> REPLACE
```

    File: `test/cympho/projects_test.exs`

```
<<<<<<< SEARCH
      }

      assert {:ok, %Project{} = project} = Projects.create_project(attrs)
      assert project.name == "New Project"
      assert project.prefix == "NEW"
=======
      }

      assert {:ok, %Project{} = project} = create_project_with_company(attrs)
      assert project.name == "New Project"
      assert project.prefix == "NEW"
>>>>>>> REPLACE
```

    File: `test/cympho/projects_test.exs`

```
<<<<<<< SEARCH
      }

      assert {:ok, %Project{} = project} = Projects.create_project(attrs)
      assert project.status == :active
    end
=======
      }

      assert {:ok, %Project{} = project} = create_project_with_company(attrs)
      assert project.status == :active
    end
>>>>>>> REPLACE
```

    File: `test/cympho/projects_test.exs`

```
<<<<<<< SEARCH
    test "returns error changeset for invalid data (missing name)" do
      attrs = %{prefix: "NO"}
      assert {:error, %Ecto.Changeset{}} = Projects.create_project(attrs)
    end

=======
    test "returns error changeset for invalid data (missing name)" do
      attrs = %{prefix: "NO"}
      assert {:error, %Ecto.Changeset{}} = create_project_with_company(attrs)
    end

>>>>>>> REPLACE
```

    File: `test/cympho/projects_test.exs`

```
<<<<<<< SEARCH
    test "returns error changeset for invalid prefix (lowercase)" do
      attrs = %{name: "Test", prefix: "lowercase"}
      assert {:error, %Ecto.Changeset{}} = Projects.create_project(attrs)
    end

=======
    test "returns error changeset for invalid prefix (lowercase)" do
      attrs = %{name: "Test", prefix: "lowercase"}
      assert {:error, %Ecto.Changeset{}} = create_project_with_company(attrs)
    end

>>>>>>> REPLACE
```

    File: `test/cympho/projects_test.exs`

```
<<<<<<< SEARCH
    test "returns error changeset for prefix too short" do
      attrs = %{name: "Test", prefix: "A"}
      assert {:error, %Ecto.Changeset{}} = Projects.create_project(attrs)
    end

=======
    test "returns error changeset for prefix too short" do
      attrs = %{name: "Test", prefix: "A"}
      assert {:error, %Ecto.Changeset{}} = create_project_with_company(attrs)
    end

>>>>>>> REPLACE
```

    File: `test/cympho/projects_test.exs`

```
<<<<<<< SEARCH
    test "returns error changeset for duplicate prefix" do
      attrs = %{name: "First", prefix: "DUPE"}
      assert {:ok, _} = Projects.create_project(attrs)

      attrs2 = %{name: "Second", prefix: "DUPE"}
      assert {:error, %Ecto.Changeset{}} = Projects.create_project(attrs2)
    end
  end
=======
    test "returns error changeset for duplicate prefix" do
      attrs = %{name: "First", prefix: "DUPE"}
      assert {:ok, _} = create_project_with_company(attrs)

      attrs2 = %{name: "Second", prefix: "DUPE"}
      assert {:error, %Ecto.Changeset{}} = create_project_with_company(attrs2)
    end
  end
>>>>>>> REPLACE
```

    File: `test/cympho/projects_test.exs`

```
<<<<<<< SEARCH
    test "updates project with valid data" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Original Name",
          prefix: "ORIG"
=======
    test "updates project with valid data" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Original Name",
          prefix: "ORIG"
>>>>>>> REPLACE
```

    File: `test/cympho/projects_test.exs`

```
<<<<<<< SEARCH
    test "returns error changeset for invalid data" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test",
          prefix: "TST"
=======
    test "returns error changeset for invalid data" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Test",
          prefix: "TST"
>>>>>>> REPLACE
```

    File: `test/cympho/projects_test.exs`

```
<<<<<<< SEARCH
    test "archives the project" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test",
          prefix: "TST"
=======
    test "archives the project" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Test",
          prefix: "TST"
>>>>>>> REPLACE
```

    File: `test/cympho/projects_test.exs`

```
<<<<<<< SEARCH
    test "deletes the project" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test",
          prefix: "TST"
=======
    test "deletes the project" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Test",
          prefix: "TST"
>>>>>>> REPLACE
```

    File: `test/cympho/projects_test.exs`

```
<<<<<<< SEARCH
    test "returns a changeset" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test",
          prefix: "TST"
=======
    test "returns a changeset" do
      {:ok, project} =
        create_project_with_company(%{
          name: "Test",
          prefix: "TST"
>>>>>>> REPLACE
```
  - **Troubleshooting:**
    - `** (MatchError) ... company_id: {"can't be blank"}` in one of these files after applying → a `create_project` call site was left without `company_id` → re-check each block applied and search the file for remaining bare `create_project(%{` calls.
  - **Done when:** the listed files pass.
  - **Verify:** `mix test test/cympho/projects_test.exs` — expected output contains `0 failures`.

- [ ] **TASK-009** [test] Add `company_id` to project fixtures: issues_test.exs, approvals_test.exs, github_controller_test.exs.
  - **Paths:** `test/cympho/issues_test.exs` (modified), `test/cympho/approvals_test.exs` (modified), `test/cympho_web/controllers/github_controller_test.exs` (modified)
  - **Implements:** `REQ-008`, `DES-009` · **Verifies:** `TEST-007` covering `AC-026` · **Depends:** `TASK-004`
  - **Context:** TASK-004 made `company_id` required in the Project changeset, so every existing `Projects.create_project/1` call (and direct `%Project{}` insert) without a `company_id` now fails. This task threads a fixture company into the affected call sites in the listed files. Each block creates a company via `Companies.create_company/1` with a unique slug (`System.unique_integer([:positive])`) and passes its id.
  - **Steps:**
    1. Apply the SEARCH/REPLACE blocks in Code, top to bottom, to each listed file.
  - **Code:** apply to the listed files:

    File: `test/cympho/issues_test.exs`

```
<<<<<<< SEARCH

    test "filters by project_id" do
      {:ok, project} = Projects.create_project(%{name: "Filter Project", prefix: "FP"})

      {:ok, project_issue} =
=======

    test "filters by project_id" do
      {:ok, filter_company} =
        Companies.create_company(%{
          name: "Filter Co",
          slug: "filter-co-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Projects.create_project(%{
          name: "Filter Project",
          prefix: "FP",
          company_id: filter_company.id
        })

      {:ok, project_issue} =
>>>>>>> REPLACE
```

    File: `test/cympho/issues_test.exs`

```
<<<<<<< SEARCH
  describe "list_issues_by_project/1" do
    test "returns issues scoped to a project" do
      {:ok, project} =
        Projects.create_project(%{
          name: "Test Project",
          prefix: "TTP"
        })

=======
  describe "list_issues_by_project/1" do
    test "returns issues scoped to a project" do
      {:ok, scoped_company} =
        Companies.create_company(%{
          name: "Scoped Co",
          slug: "scoped-co-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Projects.create_project(%{
          name: "Test Project",
          prefix: "TTP",
          company_id: scoped_company.id
        })

>>>>>>> REPLACE
```

    File: `test/cympho/issues_test.exs`

```
<<<<<<< SEARCH

  defp insert_issue do
    project =
      Cympho.Repo.insert!(%Cympho.Projects.Project{
        name: "Test Project #{System.unique_integer()}",
        prefix: "TST"
      })

=======

  defp insert_issue do
    {:ok, company} =
      Companies.create_company(%{
        name: "Insert Issue Co",
        slug: "insert-issue-#{System.unique_integer([:positive])}"
      })

    project =
      Cympho.Repo.insert!(%Cympho.Projects.Project{
        name: "Test Project #{System.unique_integer()}",
        prefix: "TST",
        company_id: company.id
      })

>>>>>>> REPLACE
```

    File: `test/cympho/issues_test.exs`

```
<<<<<<< SEARCH
  describe "auto-complete parent" do
    setup do
      project =
        Cympho.Repo.insert!(%Cympho.Projects.Project{
          name: "Parent Test Project #{System.unique_integer()}",
          prefix: "PCT"
        })

=======
  describe "auto-complete parent" do
    setup do
      {:ok, parent_company} =
        Companies.create_company(%{
          name: "Parent Test Co",
          slug: "parent-test-#{System.unique_integer([:positive])}"
        })

      project =
        Cympho.Repo.insert!(%Cympho.Projects.Project{
          name: "Parent Test Project #{System.unique_integer()}",
          prefix: "PCT",
          company_id: parent_company.id
        })

>>>>>>> REPLACE
```

    File: `test/cympho/approvals_test.exs`

```
<<<<<<< SEARCH
        %{project | company_id: opts[:company_id]}
      else
        project
      end

=======
        %{project | company_id: opts[:company_id]}
      else
        {:ok, company} =
          Cympho.Companies.create_company(%{
            name: "Approvals Co",
            slug: "approvals-co-#{System.unique_integer([:positive])}"
          })

        %{project | company_id: company.id}
      end

>>>>>>> REPLACE
```

    File: `test/cympho_web/controllers/github_controller_test.exs`

```
<<<<<<< SEARCH

  setup do
    # Create a project with a webhook secret
    {:ok, project} =
=======

  setup do
    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Github Test Co",
        slug: "github-test-#{System.unique_integer([:positive])}"
      })

    # Create a project with a webhook secret
    {:ok, project} =
>>>>>>> REPLACE
```

    File: `test/cympho_web/controllers/github_controller_test.exs`

```
<<<<<<< SEARCH
        name: "Test Project",
        prefix: "TEST",
        github_webhook_secret: "test-webhook-secret"
      })

=======
        name: "Test Project",
        prefix: "TEST",
        github_webhook_secret: "test-webhook-secret",
        company_id: company.id
      })

>>>>>>> REPLACE
```

    File: `test/cympho_web/controllers/github_controller_test.exs`

```
<<<<<<< SEARCH
  describe "branch-based auto-link" do
    setup do
      {:ok, project} =
        Projects.create_project(%{
=======
  describe "branch-based auto-link" do
    setup do
      {:ok, company} =
        Cympho.Companies.create_company(%{
          name: "Autolink Co",
          slug: "autolink-co-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Projects.create_project(%{
>>>>>>> REPLACE
```

    File: `test/cympho_web/controllers/github_controller_test.exs`

```
<<<<<<< SEARCH
          prefix: "AL",
          github_webhook_secret: "autolink-secret",
          repo_url: "https://github.com/autolink-org/repo"
        })

=======
          prefix: "AL",
          github_webhook_secret: "autolink-secret",
          repo_url: "https://github.com/autolink-org/repo",
          company_id: company.id
        })

>>>>>>> REPLACE
```
  - **Troubleshooting:**
    - `** (MatchError) ... company_id: {"can't be blank"}` in one of these files after applying → a `create_project` call site was left without `company_id` → re-check each block applied and search the file for remaining bare `create_project(%{` calls.
  - **Done when:** the listed files pass.
  - **Verify:** `mix test test/cympho/issues_test.exs test/cympho/approvals_test.exs test/cympho_web/controllers/github_controller_test.exs` — expected output contains `0 failures`.


- [ ] **TASK-010** [service] Add the `:require_company` on_mount hook and `require_company/2` plug to `CymphoWeb.UserAuth`.
  - **Paths:** `lib/cympho_web/user_auth.ex` (modified)
  - **Implements:** `REQ-003`, `DES-002` · **Verifies:** `TEST-003` covering `AC-008`, `AC-009` · **Depends:** `None`
  - **Context:** `CymphoWeb.UserAuth` already defines `on_mount(:default, ...)` (which assigns `:current_company`, nil when the user has no membership) and `require_authenticated_user/2` (which assigns `conn.assigns.current_company`). This adds the company gate in both forms: a LiveView `on_mount(:require_company, ...)` and a conn-level `require_company/2`. `Phoenix.LiveView` and `Phoenix.Controller` are fully qualified so no new imports are needed.
  - **Steps:**
    1. Apply edit block 1 to add `on_mount(:require_company, ...)` after the `on_mount(:default, ...)` clause (anchored on the `login_path/1` head that immediately follows it).
    2. Apply edit block 2 to add `require_company/2` after `require_authenticated_user/2` (anchored on its `sync_theme/2` follow-on).
  - **Code:** apply to `lib/cympho_web/user_auth.ex`:

    File: `lib/cympho_web/user_auth.ex`

```
<<<<<<< SEARCH
  def login_path(return_to) do
=======
  # Blocks company-less users from the app proper; they are funneled into
  # /onboarding (its live_session mounts only :default) until they own a
  # company membership. Prevents orphan rows like projects with NULL company.
  def on_mount(:require_company, _params, _session, socket) do
    case socket.assigns[:current_company] do
      %{id: _} -> {:cont, socket}
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: "/onboarding")}
    end
  end

  def login_path(return_to) do
>>>>>>> REPLACE
```

    File: `lib/cympho_web/user_auth.ex`

```
<<<<<<< SEARCH
  # The DB is the source of truth for an authenticated user's theme. FetchTheme
=======
  # Conn-level twin of on_mount(:require_company) for non-LiveView routes.
  def require_company(conn, _opts) do
    case conn.assigns[:current_company] do
      %{id: _} ->
        conn

      _ ->
        conn
        |> Phoenix.Controller.redirect(to: "/onboarding")
        |> Plug.Conn.halt()
    end
  end

  # The DB is the source of truth for an authenticated user's theme. FetchTheme
>>>>>>> REPLACE
```
  - **Troubleshooting:**
    - `(CompileError) undefined function on_mount/4` clause conflict → the new clause was placed after an unrelated function; confirm it sits directly before `def login_path(return_to) do`.
    - Company-less LiveView still renders instead of redirecting → the router (TASK-011) has not yet added `{CymphoWeb.UserAuth, :require_company}` to the live_session; TASK-010 alone is inert until TASK-011.
  - **Done when:** the module compiles.
  - **Verify:** `mix compile --warnings-as-errors` — exits 0.

- [ ] **TASK-011** [integration] Wire the company gate into the router: new pipeline, dedicated onboarding live session, gate on three live sessions.
  - **Paths:** `lib/cympho_web/router.ex` (modified)
  - **Implements:** `REQ-003`, `DES-002`, `DES-010` · **Verifies:** `TEST-003` covering `AC-008`, `AC-009`, `AC-010`, `AC-011`, `EDGE-007` · **Depends:** `TASK-010`
  - **Context:** The main authenticated scope pipes through `[:browser, :authenticated_browser]` and hosts `/onboarding` inside `live_session :default`. This task adds a `:company_scoped` pipeline, moves `/onboarding` into its own gate-free live session, applies `:company_scoped` to the main scope's `pipe_through`, and appends `{CymphoWeb.UserAuth, :require_company}` to the `:default`, `:board_governed`, and `:authenticated_company_show` live sessions. `CymphoWeb.UserAuth.require_company/2` exists after TASK-010.
  - **Steps:**
    1. Apply edit block 1 to add the `:company_scoped` pipeline after `:authenticated_browser`.
    2. Apply edit block 2 to add a dedicated onboarding scope above the main authenticated scope and add `:company_scoped` to the main scope's `pipe_through`.
    3. Apply edit block 3 to delete the old `/onboarding` route from `live_session :default` and gate that session.
    4. Apply edit block 4 to gate `live_session :board_governed`.
    5. Apply edit block 5 to gate `live_session :authenticated_company_show`.
    6. Apply edit block 6 to add the `require_company/2` delegation next to `require_authenticated_user/2`.
  - **Code:** apply to `lib/cympho_web/router.ex`:

    File: `lib/cympho_web/router.ex`

```
<<<<<<< SEARCH
  pipeline :authenticated_browser do
    plug :require_authenticated_user
  end
=======
  pipeline :authenticated_browser do
    plug :require_authenticated_user
  end

  pipeline :company_scoped do
    plug :require_company
  end
>>>>>>> REPLACE
```

    File: `lib/cympho_web/router.ex`

```
<<<<<<< SEARCH
  scope "/", CymphoWeb do
    pipe_through [:browser, :authenticated_browser]

    get "/switch-company/:id", CompanySwitcherController, :switch
=======
  scope "/", CymphoWeb do
    pipe_through [:browser, :authenticated_browser]

    live_session :onboarding, on_mount: [{CymphoWeb.UserAuth, :default}] do
      live "/onboarding", OnboardingLive.Index
    end
  end

  scope "/", CymphoWeb do
    pipe_through [:browser, :authenticated_browser, :company_scoped]

    get "/switch-company/:id", CompanySwitcherController, :switch
>>>>>>> REPLACE
```

    File: `lib/cympho_web/router.ex`

```
<<<<<<< SEARCH
    live_session :default, on_mount: [{CymphoWeb.UserAuth, :default}] do
=======
    live_session :default,
      on_mount: [{CymphoWeb.UserAuth, :default}, {CymphoWeb.UserAuth, :require_company}] do
>>>>>>> REPLACE
```

    File: `lib/cympho_web/router.ex`

```
<<<<<<< SEARCH
      live "/routines/:id/edit", RoutineLive.Edit
      live "/onboarding", OnboardingLive.Index
=======
      live "/routines/:id/edit", RoutineLive.Edit
>>>>>>> REPLACE
```

    File: `lib/cympho_web/router.ex`

```
<<<<<<< SEARCH
    live_session :board_governed,
      on_mount: [{CymphoWeb.UserAuth, :default}, {CymphoWeb.Live.BoardAuth, :default}] do
=======
    live_session :board_governed,
      on_mount: [
        {CymphoWeb.UserAuth, :default},
        {CymphoWeb.UserAuth, :require_company},
        {CymphoWeb.Live.BoardAuth, :default}
      ] do
>>>>>>> REPLACE
```

    File: `lib/cympho_web/router.ex`

```
<<<<<<< SEARCH
    live_session :authenticated_company_show,
      on_mount: [{CymphoWeb.UserAuth, :default}] do
=======
    live_session :authenticated_company_show,
      on_mount: [{CymphoWeb.UserAuth, :default}, {CymphoWeb.UserAuth, :require_company}] do
>>>>>>> REPLACE
```

    File: `lib/cympho_web/router.ex`

```
<<<<<<< SEARCH
  defp require_authenticated_user(conn, opts) do
    CymphoWeb.UserAuth.require_authenticated_user(conn, opts)
  end
=======
  defp require_authenticated_user(conn, opts) do
    CymphoWeb.UserAuth.require_authenticated_user(conn, opts)
  end

  defp require_company(conn, opts) do
    CymphoWeb.UserAuth.require_company(conn, opts)
  end
>>>>>>> REPLACE
```
  - **Troubleshooting:**
    - `(ArgumentError) could not find a live session for "/onboarding"` → edit block 4 deleted the old route but edit block 2's new onboarding live_session was not applied → confirm block 2 added `live_session :onboarding`.
    - Redirect loop on `/onboarding` for a company-less user → the onboarding live_session accidentally carries `:require_company` → confirm the `:onboarding` session's `on_mount` is exactly `[{CymphoWeb.UserAuth, :default}]`.
    - `(RuntimeError) no plug named :require_company` → edit block 6's `defp require_company/2` delegation is missing → re-apply block 6.
  - **Done when:** the router compiles and TASK-012's tests pass.
  - **Verify:** `mix compile --warnings-as-errors` — exits 0.

- [ ] **TASK-012** [test] Add the company-gate integration tests.
  - **Paths:** `test/cympho_web/require_company_gate_test.exs` (created)
  - **Implements:** `REQ-003`, `DES-002`, `DES-010` · **Verifies:** `TEST-003` covering `AC-008`, `AC-009`, `AC-010`, `AC-011`, `EDGE-007` · **Depends:** `TASK-011`
  - **Context:** TASK-011 gated the app behind company membership. This test proves company-less users are redirected to `/onboarding` from both live and controller routes, that `/onboarding` itself stays reachable, and that users with a company pass. `CymphoWeb.ConnCase.register_and_log_in_user/1` returns `{conn, user, company}` and creates a membership; `Cympho.Users.create_user/1` exists.
  - **Steps:**
    1. Create the file at the exact path above with the contents in Code.
    2. Exports: four tests — live route gated, controller route gated, onboarding reachable, users with a company pass through.
  - **Code:** complete contents of `test/cympho_web/require_company_gate_test.exs`:
    ```elixir
    defmodule CymphoWeb.RequireCompanyGateTest do
      use CymphoWeb.ConnCase, async: true

      import Phoenix.LiveViewTest

      defp companyless_conn do
        {:ok, user} =
          Cympho.Users.create_user(%{
            email: "solo-#{System.unique_integer([:positive])}@example.com",
            name: "Solo",
            password: "password1234"
          })

        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, user.id)
      end

      test "live routes redirect company-less users to onboarding" do
        assert {:error, {:redirect, %{to: "/onboarding"}}} = live(companyless_conn(), "/issues")
      end

      test "controller routes redirect company-less users to onboarding" do
        conn = get(companyless_conn(), "/switch-company/#{Ecto.UUID.generate()}")
        assert redirected_to(conn) == "/onboarding"
      end

      test "onboarding stays reachable for company-less users" do
        assert {:ok, _view, html} = live(companyless_conn(), "/onboarding")
        assert html =~ "Start an autonomous company"
      end

      test "users with a company pass through" do
        {conn, _user, _company} = CymphoWeb.ConnCase.register_and_log_in_user(build_conn())
        assert {:ok, _view, _html} = live(conn, "/issues")
      end
    end
    ```
  - **Troubleshooting:** `None — standard ConnCase test file.`
  - **Done when:** all four tests pass.
  - **Verify:** `mix test test/cympho_web/require_company_gate_test.exs` — expected output contains `0 failures`.

- [ ] **TASK-013** [test] Adapt the membership-less `user_auth_test` expectation to the gate.
  - **Paths:** `test/cympho_web/user_auth_test.exs` (modified)
  - **Implements:** `REQ-003`, `DES-002` · **Verifies:** `TEST-007` covering `AC-008` · **Depends:** `TASK-011`
  - **Context:** The existing test "assigns nil current_company for user with no memberships" mounts `/issues` as a membership-less user and asserts a successful mount with `current_company == nil`. After TASK-011 wires the `:require_company` gate, that mount halts with a redirect to `/onboarding` — which is the new intended behavior, so the test is updated to assert it.
  - **Steps:**
    1. Apply the SEARCH/REPLACE blocks in Code to `test/cympho_web/user_auth_test.exs`.
  - **Code:** apply to `test/cympho_web/user_auth_test.exs`:

    File: `test/cympho_web/user_auth_test.exs`

```
<<<<<<< SEARCH
    end

    test "assigns nil current_company for user with no memberships" do
      # Create a user with no company memberships
      {:ok, lonely_user} =
        %User{}
=======
    end

    test "redirects membership-less users into onboarding" do
      # Create a user with no company memberships; the require_company gate
      # sends them to the onboarding wizard instead of mounting the app.
      {:ok, lonely_user} =
        %User{}
>>>>>>> REPLACE
```

    File: `test/cympho_web/user_auth_test.exs`

```
<<<<<<< SEARCH
        |> Plug.Conn.put_session("user_id", lonely_user.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_company == nil
    end

=======
        |> Plug.Conn.put_session("user_id", lonely_user.id)

      assert {:error, {:redirect, %{to: "/onboarding"}}} = live(conn, "/issues")
    end

>>>>>>> REPLACE
```
  - **Troubleshooting:** `None — assertion swap only; if the redirect tuple differs, TASK-011's gate is misapplied and that task's Troubleshooting applies.`
  - **Done when:** the file passes.
  - **Verify:** `mix test test/cympho_web/user_auth_test.exs` — expected output contains `0 failures`.

- [ ] **TASK-014** [api] Create `CymphoWeb.SetupController` for first-run owner creation.
  - **Paths:** `lib/cympho_web/controllers/setup_controller.ex` (created)
  - **Implements:** `REQ-001`, `DES-003`, `DES-004` · **Verifies:** `TEST-004` covering `AC-001`, `AC-002`, `AC-003`, `AC-004`, `AC-005`, `AC-029`, `AC-030`, `EDGE-001` · **Depends:** `None`
  - **Context:** No `/setup` route exists yet. This controller renders an inline-HTML owner-creation form when the `users` table is empty and locks itself once any user exists, guarding concurrent submits with `pg_advisory_xact_lock(7214001)`. It reuses `Cympho.Authentication.register_user/1` (Argon2-hashing), `CymphoWeb.SessionController.sign_in/2` (sets `:user_id` + `:company_id` session keys), and `Cympho.Users.User`. The inline-HTML + CSRF-token style mirrors `SessionController.sign_in_page/2`.
  - **Steps:**
    1. Create the file at the exact path above with the contents in Code.
    2. Exports: `new/2`, `create/2`.
  - **Code:** complete contents of `lib/cympho_web/controllers/setup_controller.ex`:
    ```elixir
    defmodule CymphoWeb.SetupController do
      @moduledoc """
      One-time first-run setup: creates the instance owner when the user table is
      empty, then hands off to /onboarding. Locks itself permanently once any user
      exists (guarded by a Postgres advisory lock against concurrent submits).
      """

      use CymphoWeb, :controller

      alias Cympho.Authentication
      alias Cympho.Repo
      alias Cympho.Users.User
      alias CymphoWeb.SessionController

      @setup_lock_key 7_214_001

      def new(conn, _params) do
        if users_exist?() do
          redirect(conn, to: "/login")
        else
          conn |> put_layout(false) |> html(setup_page(%{}, nil))
        end
      end

      def create(conn, %{"user" => user_params}) do
        case create_first_user(user_params) do
          {:ok, user} ->
            conn
            |> SessionController.sign_in(user)
            |> put_flash(:info, "Welcome! Let's set up your company.")
            |> redirect(to: "/onboarding")

          {:error, :already_configured} ->
            # A double-submitted form loses the race against itself: the first
            # request signed the owner in, so send the second to onboarding
            # instead of stranding a signed-in user on the login form.
            if get_session(conn, :user_id) do
              redirect(conn, to: "/onboarding")
            else
              redirect(conn, to: "/login")
            end

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_layout(false)
            |> html(setup_page(user_params, first_error(changeset)))
        end
      end

      def create(conn, _params), do: redirect(conn, to: "/setup")

      defp users_exist?, do: Repo.aggregate(User, :count) > 0

      defp create_first_user(params) do
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock($1)", [@setup_lock_key])

          if users_exist?() do
            Repo.rollback(:already_configured)
          else
            # Trim + downcase the email: authenticate_user/2 matches emails
            # byte-for-byte, and a first-run typo ("Nick@Example.com ") would
            # permanently lock out the only owner on an instance that has no
            # password-reset flow.
            case Authentication.register_user(%{
                   "name" => String.trim(params["name"] || ""),
                   "email" => params["email"] |> to_string() |> String.trim() |> String.downcase(),
                   "password" => params["password"]
                 }) do
              {:ok, user} -> user
              {:error, changeset} -> Repo.rollback(changeset)
            end
          end
        end)
      end

      defp first_error(changeset) do
        Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
          Enum.reduce(opts, msg, fn {key, value}, acc ->
            String.replace(acc, "%{#{key}}", to_string(value))
          end)
        end)
        |> Enum.map(fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
        |> List.first()
      end

      defp setup_page(params, error) do
        csrf = Plug.CSRFProtection.get_csrf_token()
        error_html = if error, do: ~s(<p class="error">#{escape(error)}</p>), else: ""

        """
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <link rel="icon" type="image/svg+xml" href="/images/favicon.svg">
            <title>Set up · Cympho</title>
            <style>
              :root { color-scheme: dark; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #20201E; color: #FAF9F5; }
              body { min-height: 100dvh; margin: 0; display: grid; place-items: center; background: radial-gradient(900px 480px at 50% -120px, rgba(217, 119, 87, .18), transparent 70%), #20201E; }
              main { width: min(420px, calc(100vw - 32px)); border: 1px solid rgba(255,250,245,.10); border-radius: 20px; background: rgba(38, 38, 36, .96); box-shadow: inset 0 1px 0 0 rgba(255,250,245,.05), 0 24px 80px rgba(0,0,0,.42); animation: enter 700ms cubic-bezier(0.16,1,0.3,1) both; }
              @keyframes enter { from { opacity: 0; transform: translateY(14px) scale(.98); } to { opacity: 1; transform: none; } }
              @media (prefers-reduced-motion: reduce) { main { animation: none; } }
              form { display: grid; gap: 14px; padding: 30px; }
              .mark { display: inline-flex; align-items: center; gap: 8px; color: #D97757; font-size: 13px; font-weight: 620; letter-spacing: .08em; text-transform: uppercase; }
              .mark svg { width: 14px; height: 14px; }
              h1 { margin: 6px 0 0; font-family: "Source Serif 4", Georgia, "Times New Roman", serif; font-size: 27px; line-height: 1.15; font-weight: 600; letter-spacing: -0.3px; }
              p { margin: 6px 0 0; color: #B0A99C; font-size: 14px; line-height: 1.5; }
              label { display: grid; gap: 7px; color: #E5E1D8; font-size: 13px; font-weight: 560; }
              input { width: 100%; box-sizing: border-box; border: 1px solid rgba(255,250,245,.12); border-radius: 10px; background: #2D2C2A; color: #FAF9F5; padding: 10px 11px; font: inherit; transition: border-color 160ms ease, box-shadow 160ms ease; }
              input:focus { outline: none; border-color: rgba(217,119,87,.75); box-shadow: 0 0 0 3px rgba(217,119,87,.22); }
              button { border: 0; border-radius: 10px; background: #D97757; color: #20201E; padding: 11px 12px; font: inherit; font-weight: 620; cursor: pointer; box-shadow: inset 0 1px 0 0 rgba(255,255,255,.18); transition: background 160ms ease; }
              button:hover { background: #E08A6B; }
              .error { color: #E0AEAE; background: rgba(198, 69, 69, .12); border: 1px solid rgba(198, 69, 69, .26); border-radius: 8px; padding: 9px 10px; }
            </style>
          </head>
          <body>
            <main>
              <form method="post" action="/setup">
                <input type="hidden" name="_csrf_token" value="#{csrf}">
                <div>
                  <span class="mark">
                    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2 L13.8 10.2 L22 12 L13.8 13.8 L12 22 L10.2 13.8 L2 12 L10.2 10.2 Z"/></svg>
                    Cympho
                  </span>
                  <h1>Create your owner account</h1>
                  <p>This instance is brand new. Create the owner account, then the setup wizard will launch your first autonomous company.</p>
                </div>
                #{error_html}
                <label>
                  Name
                  <input name="user[name]" type="text" autocomplete="name" value="#{escape(params["name"])}" required>
                </label>
                <label>
                  Email
                  <input name="user[email]" type="email" autocomplete="email" value="#{escape(params["email"])}" required>
                </label>
                <label>
                  Password
                  <input name="user[password]" type="password" autocomplete="new-password" minlength="8" required>
                </label>
                <button type="submit">Create owner account</button>
              </form>
            </main>
          </body>
        </html>
        """
      end

      defp escape(value) when is_binary(value),
        do: Phoenix.HTML.html_escape(value) |> Phoenix.HTML.safe_to_string()

      defp escape(_), do: ""
    end
    ```
  - **Troubleshooting:**
    - `(UndefinedFunctionError) function CymphoWeb.SessionController.sign_in/2 is undefined` → the alias `CymphoWeb.SessionController` is missing → confirm the `alias CymphoWeb.SessionController` line is present.
    - `POST /setup` returns 500 with `pg_advisory_xact_lock` error → the DB user lacks advisory-lock permission (not the case for the app's own Postgres role) → confirm the parameter list is `[@setup_lock_key]` (an integer), not a string.
    - Setup page returns 200 after a user exists → `users_exist?/0` is querying the wrong schema → confirm `Repo.aggregate(User, :count)` uses `Cympho.Users.User`.
  - **Done when:** the module compiles and TASK-016's tests pass.
  - **Verify:** `mix compile --warnings-as-errors` — exits 0.

- [ ] **TASK-015** [integration] Add the `/setup` routes and the zero-user `/login` redirect.
  - **Paths:** `lib/cympho_web/router.ex` (modified), `lib/cympho_web/controllers/session_controller.ex` (modified)
  - **Implements:** `REQ-001`, `REQ-002`, `DES-003` · **Verifies:** `TEST-004` covering `AC-006`, `AC-007` · **Depends:** `TASK-014`
  - **Context:** The public `:browser` scope defines `get "/login"` / `post "/login"` and `delete "/logout"`; `SessionController.new/2` currently always renders the sign-in page. This task adds `GET/POST /setup` next to the logout route and makes `new/2` redirect to `/setup` when the `users` table is empty. `CymphoWeb.SetupController` exists after TASK-014; `SessionController` already aliases `Cympho.Repo` and `Cympho.Users.User`.
  - **Steps:**
    1. Apply edit block 1 to add the `/setup` routes after `delete "/logout"`.
    2. Apply edit block 2 to add the zero-user redirect in `SessionController.new/2`.
  - **Code:** apply to the two files:

    File: `lib/cympho_web/router.ex`

```
<<<<<<< SEARCH
    delete "/logout", SessionController, :delete
=======
    delete "/logout", SessionController, :delete

    get "/setup", SetupController, :new
    post "/setup", SetupController, :create
>>>>>>> REPLACE
```

    File: `lib/cympho_web/controllers/session_controller.ex`

```
<<<<<<< SEARCH
  def new(conn, params) do
    conn
    |> put_layout(false)
    |> html(sign_in_page(params, Phoenix.Flash.get(conn.assigns.flash, :error)))
  end
=======
  def new(conn, params) do
    if Repo.aggregate(User, :count) == 0 do
      # Fresh instance: no owner yet — send the visitor to first-run setup
      # instead of a login form nobody can pass.
      redirect(conn, to: "/setup")
    else
      conn
      |> put_layout(false)
      |> html(sign_in_page(params, Phoenix.Flash.get(conn.assigns.flash, :error)))
    end
  end
>>>>>>> REPLACE
```
  - **Troubleshooting:**
    - `(ArgumentError) unknown controller CymphoWeb.SetupController` → TASK-014 was not completed → create the controller first.
    - `/login` shows the form on a fresh DB instead of redirecting → the `Repo.aggregate(User, :count) == 0` branch was not applied → re-apply edit block 2.
  - **Done when:** the router and controller compile and TASK-016's tests pass.
  - **Verify:** `mix compile --warnings-as-errors` — exits 0.

- [ ] **TASK-016** [test] Add the `/setup` controller integration tests.
  - **Paths:** `test/cympho_web/controllers/setup_controller_test.exs` (created)
  - **Implements:** `REQ-001`, `REQ-002`, `DES-003`, `DES-004` · **Verifies:** `TEST-004` covering `AC-001`, `AC-002`, `AC-003`, `AC-004`, `AC-005`, `AC-006`, `AC-029`, `AC-030`, `EDGE-001` · **Depends:** `TASK-015`
  - **Context:** TASK-014 and TASK-015 added the `/setup` page, the `/setup` routes, and the zero-user `/login` redirect. This file is `async: false` because it reads and mutates the global `users` count. `Cympho.Users.create_user/1` and `Cympho.Users.get_user_by_email/1` exist; `get_user_by_email/1` returns `{:ok, user} | {:error, :not_found}`.
  - **Steps:**
    1. Create the file at the exact path above with the contents in Code.
    2. Exports: six tests — renders at zero users, locks after first user, login redirects at zero users, creates owner + session, refuses when configured, invalid input re-renders.
  - **Code:** complete contents of `test/cympho_web/controllers/setup_controller_test.exs`:
    ```elixir
    defmodule CymphoWeb.SetupControllerTest do
      use CymphoWeb.ConnCase, async: false

      defp seed_user! do
        {:ok, user} =
          Cympho.Users.create_user(%{
            email: "existing-#{System.unique_integer([:positive])}@example.com",
            name: "Existing",
            password: "password1234"
          })

        user
      end

      test "GET /setup renders the owner form when no users exist", %{conn: conn} do
        conn = get(conn, "/setup")
        assert html_response(conn, 200) =~ "Create your owner account"
      end

      test "GET /setup redirects to login once a user exists", %{conn: conn} do
        seed_user!()
        assert redirected_to(get(conn, "/setup")) == "/login"
      end

      test "GET /login redirects to setup when no users exist", %{conn: conn} do
        assert redirected_to(get(conn, "/login")) == "/setup"
      end

      test "POST /setup creates the owner, signs them in, and sends them to onboarding", %{
        conn: conn
      } do
        conn =
          post(conn, "/setup", %{
            "user" => %{"name" => "Nick", "email" => "nick@example.com", "password" => "longenough1"}
          })

        assert redirected_to(conn) == "/onboarding"
        assert {:ok, user} = Cympho.Users.get_user_by_email("nick@example.com")
        assert Plug.Conn.get_session(conn, :user_id) == user.id
        assert String.starts_with?(user.password_hash, "$argon2")
      end

      test "POST /setup refuses once a user exists", %{conn: conn} do
        seed_user!()

        conn =
          post(conn, "/setup", %{
            "user" => %{"name" => "Late", "email" => "late@example.com", "password" => "longenough1"}
          })

        assert redirected_to(conn) == "/login"
        assert {:error, :not_found} = Cympho.Users.get_user_by_email("late@example.com")
      end

      test "POST /setup double submit sends the signed-in owner to onboarding", %{conn: conn} do
        params = %{
          "user" => %{"name" => "Nick", "email" => "nick@example.com", "password" => "longenough1"}
        }

        conn = post(conn, "/setup", params)
        assert redirected_to(conn) == "/onboarding"

        # The browser re-submits with the session cookie from the first response.
        conn = post(recycle(conn), "/setup", params)
        assert redirected_to(conn) == "/onboarding"

        assert Cympho.Repo.aggregate(Cympho.Users.User, :count) == 1
      end

      test "POST /setup normalizes the owner email before creating", %{conn: conn} do
        conn =
          post(conn, "/setup", %{
            "user" => %{
              "name" => "Nick",
              "email" => "  Nick@Example.COM ",
              "password" => "longenough1"
            }
          })

        assert redirected_to(conn) == "/onboarding"
        assert {:ok, _user} = Cympho.Users.get_user_by_email("nick@example.com")
      end

      test "POST /setup re-renders with errors on invalid input", %{conn: conn} do
        conn =
          post(conn, "/setup", %{
            "user" => %{"name" => "Nick", "email" => "nick@example.com", "password" => "short"}
          })

        assert html_response(conn, 200) =~ "at least 8 characters"
        assert {:error, :not_found} = Cympho.Users.get_user_by_email("nick@example.com")
      end
    end
    ```
  - **Troubleshooting:** `None — standard ConnCase test file.`
  - **Done when:** all six tests pass.
  - **Verify:** `mix test test/cympho_web/controllers/setup_controller_test.exs` — expected output contains `0 failures`.

- [ ] **TASK-017** [test] Seed a user in the two zero-user `/login` rendering tests.
  - **Paths:** `test/cympho_web/controllers/session_controller_test.exs` (modified)
  - **Implements:** `REQ-002`, `DES-003` · **Verifies:** `TEST-007` covering `AC-007` · **Depends:** `TASK-015`
  - **Context:** After TASK-015, `GET /login` redirects to `/setup` when the `users` table is empty. Two existing tests — "renders a safe return target into the sign-in form" and "drops unsafe return targets from the sign-in form" — GET `/login` on an empty DB and assert on the returned HTML. They must seed a user first so the sign-in form still renders. The `registered_user/0` helper is already defined at the bottom of this file (used by the two POST tests).
  - **Steps:**
    1. Apply edit block 1 to seed a user before the safe-return-target GET.
    2. Apply edit block 2 to seed a user before the unsafe-return-target GET.
  - **Code:** apply to `test/cympho_web/controllers/session_controller_test.exs`:

    File: `test/cympho_web/controllers/session_controller_test.exs`

```
<<<<<<< SEARCH
    test "renders a safe return target into the sign-in form", %{conn: conn} do
      conn = get(conn, "/login?return_to=/issues/123")
=======
    test "renders a safe return target into the sign-in form", %{conn: conn} do
      registered_user()
      conn = get(conn, "/login?return_to=/issues/123")
>>>>>>> REPLACE
```

    File: `test/cympho_web/controllers/session_controller_test.exs`

```
<<<<<<< SEARCH
    test "drops unsafe return targets from the sign-in form", %{conn: conn} do
      conn = get(conn, "/login?return_to=https://evil.example/issues")
=======
    test "drops unsafe return targets from the sign-in form", %{conn: conn} do
      registered_user()
      conn = get(conn, "/login?return_to=https://evil.example/issues")
>>>>>>> REPLACE
```
  - **Troubleshooting:** `None — two one-line insertions.`
  - **Done when:** the full session controller test file passes.
  - **Verify:** `mix test test/cympho_web/controllers/session_controller_test.exs` — expected output contains `0 failures`.

- [ ] **TASK-018** [api] Lock `POST /api/register` behind `:open_registration` and enable it in dev.
  - **Paths:** `lib/cympho_web/controllers/registration_controller.ex` (modified), `config/dev.exs` (modified)
  - **Implements:** `REQ-004`, `DES-005` · **Verifies:** `TEST-005` covering `AC-012`, `AC-013` · **Depends:** `None`
  - **Context:** `RegistrationController.create/2` currently always creates a user via `Cympho.Authentication.register_user/1`. This wraps it in an `:open_registration` app-env check (default `false`, `true` in dev) so production is invite-only. `Cympho.Authentication`, `Cympho.Users.User`, and `CymphoWeb.ErrorJSON` are already in scope. `config/dev.exs` ends with `config :phoenix, :plug_init_mode, :runtime`.
  - **Steps:**
    1. Apply edit block 1 to gate `create/2` and add the `do_create/2` helper.
    2. Apply edit block 2 to enable open registration in dev config.
  - **Code:** apply to the two files:

    File: `lib/cympho_web/controllers/registration_controller.ex`

```
<<<<<<< SEARCH
  def create(conn, %{"user" => user_params}) do
    case Authentication.register_user(user_params) do
      {:ok, %User{} = user} ->
        conn
        |> put_status(:created)
        |> render(:show, user: user)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:error, changeset: changeset)
    end
  end
=======
  def create(conn, %{"user" => user_params}) do
    if Application.get_env(:cympho, :open_registration, false) do
      do_create(conn, user_params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "registration is invite-only"})
    end
  end

  defp do_create(conn, user_params) do
    case Authentication.register_user(user_params) do
      {:ok, %User{} = user} ->
        conn
        |> put_status(:created)
        |> render(:show, user: user)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: CymphoWeb.ErrorJSON)
        |> render(:error, changeset: changeset)
    end
  end
>>>>>>> REPLACE
```

    File: `config/dev.exs`

```
<<<<<<< SEARCH
config :phoenix, :plug_init_mode, :runtime
=======
config :phoenix, :plug_init_mode, :runtime

# Open self-registration is a dev convenience; production is invite-only.
config :cympho, open_registration: true
>>>>>>> REPLACE
```
  - **Troubleshooting:**
    - `POST /api/register` still returns 201 with `:open_registration` unset in test → the test env inherited the dev config → confirm the config change is in `config/dev.exs` only (not `config/config.exs`), so `MIX_ENV=test` keeps it unset.
    - `(FunctionClauseError) no function clause matching in ...do_create/2` → the private `do_create/2` head was not added → re-apply edit block 1.
  - **Done when:** the module and config compile and TASK-019's tests pass.
  - **Verify:** `mix compile --warnings-as-errors` — exits 0.

- [ ] **TASK-019** [test] Add the registration-lock integration tests.
  - **Paths:** `test/cympho_web/controllers/registration_controller_test.exs` (created)
  - **Implements:** `REQ-004`, `DES-005` · **Verifies:** `TEST-005` covering `AC-012`, `AC-013` · **Depends:** `TASK-018`
  - **Context:** TASK-018 locked `POST /api/register` behind `:open_registration`. This file is `async: false` because it mutates the global app env. `Cympho.Users.get_user_by_email/1` returns `{:ok, user} | {:error, :not_found}`.
  - **Steps:**
    1. Create the file at the exact path above with the contents in Code.
    2. Exports: two tests — returns 403 when closed (default), creates a user when open_registration is enabled.
  - **Code:** complete contents of `test/cympho_web/controllers/registration_controller_test.exs`:
    ```elixir
    defmodule CymphoWeb.RegistrationControllerTest do
      use CymphoWeb.ConnCase, async: false

      @params %{"user" => %{"name" => "New", "email" => "new@example.com", "password" => "longenough1"}}

      test "returns 403 when registration is closed (default)", %{conn: conn} do
        conn = post(conn, "/api/register", @params)
        assert json_response(conn, 403)["error"] == "registration is invite-only"
        assert {:error, :not_found} = Cympho.Users.get_user_by_email("new@example.com")
      end

      test "creates a user when open_registration is enabled", %{conn: conn} do
        Application.put_env(:cympho, :open_registration, true)
        on_exit(fn -> Application.delete_env(:cympho, :open_registration) end)

        conn = post(conn, "/api/register", @params)
        assert json_response(conn, 201)
        assert {:ok, _user} = Cympho.Users.get_user_by_email("new@example.com")
      end
    end
    ```
  - **Troubleshooting:** `None — standard ConnCase test file.`
  - **Done when:** both tests pass.
  - **Verify:** `mix test test/cympho_web/controllers/registration_controller_test.exs` — expected output contains `0 failures`.

- [ ] **TASK-020** [ui] Rebuild the onboarding LiveView as the six-step wizard (module + template).
  - **Paths:** `lib/cympho_web/live/onboarding_live/index.ex` (modified), `lib/cympho_web/live/onboarding_live/index.html.heex` (modified)
  - **Implements:** `REQ-005`, `REQ-006`, `REQ-007`, `DES-006`, `DES-007`, `DES-008` · **Verifies:** `TEST-006` covering `AC-014`, `AC-015`, `AC-016`, `AC-017`, `AC-018`, `AC-019`, `AC-020`, `AC-024`, `EDGE-005`, `EDGE-006`, `EDGE-009`, `EDGE-010`, `EDGE-011` · **Depends:** `TASK-001`, `TASK-011`
  - **Context:** The current onboarding LiveView is a 4-step wizard whose single `#company-starter-form` submits directly to `Companies.create_autonomous_company/1` without an owner. This task replaces both files wholesale (each SEARCH block is the entire current file, so it matches exactly once): 6 steps (welcome, blueprint, company, team, launch, ready), per-step validation with exact error strings "Company name is required." / "Company name must be at least 3 characters." / "Company goal is required." / "Issue prefix must be 2-7 uppercase letters." / "Finish setup to enter Cympho.", a server-side adapter whitelist (`~w(claude_code codex cursor http)`, anything else coerced to `"claude_code"`), a rescue around the launch call that converts engine raises (`Repo.insert!` on invalid changesets) into the error banner instead of crashing the LiveView, a double-launch guard (event ignored when `bootstrap_result` is set), and a launch payload carrying `owner_user_id`, `engineer_names`, `adapter`, and `agent_runtime` (command/model). The ready step links to `/switch-company/<company id>?return_to=/issues` with the exact text "Enter Cympho". Both files are one compile unit, so they change in one task; the whole-file Form B blocks are transcription, matching Form A's no-line-cap rationale.
  - **Steps:**
    1. Apply edit block 1 (whole-file replacement) to `lib/cympho_web/live/onboarding_live/index.ex`.
    2. Apply edit block 2 (whole-file replacement) to `lib/cympho_web/live/onboarding_live/index.html.heex`.
    3. Confirm the new module's public helpers exist: `engineer_count/1`, `engineer_name_value/2`, `selected_blueprint/2`; events handled: `"next_step"`, `"prev_step"`, `"skip"`, `"update_company_form"`, `"filter_blueprints"`, `"start_autonomous_company"`.
  - **Code:** apply to the two files:

    File: `lib/cympho_web/live/onboarding_live/index.ex`

```
<<<<<<< SEARCH
defmodule CymphoWeb.OnboardingLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Agents.Agent
  alias Cympho.Companies

  @steps [
    %{
      id: :welcome,
      title: "Start an autonomous company",
      description: "Create a CEO, CTO, engineers, goal, project, and first issue"
    },
    %{
      id: :workspace,
      title: "Company operating system",
      description: "Set the company goal and default execution team"
    },
    %{
      id: :shortcuts,
      title: "Quick navigation",
      description: "Learn keyboard shortcuts to move fast"
    },
    %{
      id: :ready,
      title: "You're all set!",
      description: "Start managing your projects with AI agents"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    blueprints = Companies.autonomous_company_blueprints()

    socket =
      socket
      |> assign(:page_title, "Get Started")
      |> assign(:steps, @steps)
      |> assign(:blueprints, blueprints)
      |> assign(:blueprint_query, "")
      |> assign(:filtered_blueprints, blueprints)
      |> assign(:current_step, 0)
      |> assign(:bootstrap_result, nil)
      |> assign(:company_form, %{
        "blueprint" => "software",
        "name" => "Autonomous Software Company",
        "goal_title" => "Build and run the business autonomously",
        "issue_prefix" => "LLM",
        "engineer_count" => "2"
      })

    {:ok, socket}
  end

  @impl true
  def handle_event("next_step", _params, socket) do
    current = socket.assigns.current_step
    max = length(socket.assigns.steps) - 1

    if current < max do
      {:noreply, assign(socket, :current_step, current + 1)}
    else
      {:noreply, push_navigate(socket, to: ~p"/issues")}
    end
  end

  def handle_event("prev_step", _params, socket) do
    current = socket.assigns.current_step

    if current > 0 do
      {:noreply, assign(socket, :current_step, current - 1)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("skip", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/issues")}
  end

  def handle_event("update_company_form", %{"company" => params}, socket) do
    params = maybe_apply_blueprint_defaults(params, socket.assigns.company_form)
    {:noreply, assign(socket, :company_form, params)}
  end

  def handle_event("filter_blueprints", %{"blueprint_query" => query}, socket) do
    query = String.trim(query || "")

    {:noreply,
     socket
     |> assign(:blueprint_query, query)
     |> assign(:filtered_blueprints, filter_blueprints(socket.assigns.blueprints, query))}
  end

  def handle_event("start_autonomous_company", %{"company" => params}, socket) do
    attrs =
      socket.assigns.company_form
      |> Map.merge(params)
      |> Map.update("engineer_count", 2, &parse_engineer_count/1)

    case Companies.create_autonomous_company(attrs) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:bootstrap_result, result)
         |> assign(:current_step, 3)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create company: #{inspect(reason)}")}
    end
  end

  defp parse_engineer_count(value) when is_integer(value), do: max(0, min(value, 8))

  defp parse_engineer_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, _} -> max(0, min(count, 8))
      :error -> 2
    end
  end

  defp maybe_apply_blueprint_defaults(params, current_form) do
    selected = params["blueprint"] || current_form["blueprint"] || "software"
    previous = current_form["blueprint"] || "software"

    if selected != previous do
      case Companies.autonomous_company_blueprint(selected) do
        {:ok, blueprint} ->
          params
          |> Map.put("blueprint", selected)
          |> Map.put("goal_title", blueprint.default_goal)
          |> Map.put("issue_prefix", blueprint.default_prefix)

        {:error, :not_found} ->
          params
      end
    else
      Map.put_new(params, "blueprint", selected)
    end
  end

  defp filter_blueprints(blueprints, ""), do: blueprints

  defp filter_blueprints(blueprints, query) do
    normalized_query = String.downcase(query)

    Enum.filter(blueprints, fn blueprint ->
      [
        blueprint.key,
        blueprint.name,
        blueprint.description,
        blueprint.default_goal,
        blueprint.role_summary,
        Enum.join(blueprint.roles, " "),
        Enum.join(blueprint.capability_tags, " "),
        Enum.join(blueprint.seed_issue_titles, " ")
      ]
      |> Enum.join(" ")
      |> String.downcase()
      |> String.contains?(normalized_query)
    end)
  end

  defp role_label(role), do: Agent.role_label(role)

  # What the operator walks away with after each step — states the payoff, not
  # just the inputs, so the wizard feels like progress rather than a form.
  defp step_outcome(:welcome),
    do: "One click sets up a CEO, CTO, specialist agents, a goal, a project, and seed issues."

  defp step_outcome(:workspace),
    do: "Pick a blueprint and we create the agents and their first issues for you."

  defp step_outcome(:shortcuts),
    do:
      "Optional — these just help you move faster once you're inside. Press ? anytime to see them again."

  defp step_outcome(:ready), do: "Everything below is live. Open any item to start working."
  defp step_outcome(_), do: nil

  # Only the step's true next action glows; the footer recedes when the card
  # already holds the primary action (create company / open the workspace).
  defp nav_cta_class(step) when step in [1, 3] do
    "border border-border bg-surface text-text-secondary hover:bg-surface-hover hover:text-text-primary font-510 text-sm px-5 py-2.5 rounded-button transition-colors min-h-[44px]"
  end

  defp nav_cta_class(_step) do
    "cta-glow bg-brand hover:bg-accent text-on-primary font-510 text-sm px-5 py-2.5 rounded-button transition-colors min-h-[44px]"
  end
end
=======
defmodule CymphoWeb.OnboardingLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Agents.Agent
  alias Cympho.Companies

  @steps [
    %{
      id: :welcome,
      title: "Start an autonomous company",
      description: "Create a CEO, CTO, engineers, goal, project, and first issues"
    },
    %{
      id: :blueprint,
      title: "Choose a blueprint",
      description: "Pick the kind of company your agents will run"
    },
    %{
      id: :company,
      title: "Name the company",
      description: "Set the company name, goal, and issue prefix"
    },
    %{
      id: :team,
      title: "Build the team",
      description: "CEO and CTO lead by default — configure your engineers and runtime"
    },
    %{
      id: :launch,
      title: "Review and launch",
      description: "Confirm the plan — launch creates everything in one transaction"
    },
    %{
      id: :ready,
      title: "You're all set!",
      description: "Your autonomous company is live"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    blueprints = Companies.autonomous_company_blueprints()

    socket =
      socket
      |> assign(:page_title, "Get Started")
      |> assign(:steps, @steps)
      |> assign(:blueprints, blueprints)
      |> assign(:blueprint_query, "")
      |> assign(:filtered_blueprints, blueprints)
      |> assign(:current_step, 0)
      |> assign(:step_error, nil)
      |> assign(:bootstrap_result, nil)
      |> assign(:company_form, %{
        "blueprint" => "software",
        "name" => "Autonomous Software Company",
        "goal_title" => "Build and run the business autonomously",
        "issue_prefix" => "LLM",
        "engineer_count" => "2",
        "engineer_names" => [],
        "adapter" => "claude_code",
        "runtime_command" => "",
        "runtime_model" => ""
      })

    {:ok, socket}
  end

  @impl true
  def handle_event("next_step", _params, socket) do
    step = Enum.at(socket.assigns.steps, socket.assigns.current_step)

    case validate_step(step.id, socket.assigns.company_form) do
      :ok ->
        max = length(socket.assigns.steps) - 1
        next = min(socket.assigns.current_step + 1, max)
        {:noreply, socket |> assign(:current_step, next) |> assign(:step_error, nil)}

      {:error, message} ->
        {:noreply, assign(socket, :step_error, message)}
    end
  end

  def handle_event("prev_step", _params, socket) do
    {:noreply,
     socket
     |> assign(:current_step, max(socket.assigns.current_step - 1, 0))
     |> assign(:step_error, nil)}
  end

  def handle_event("skip", _params, socket) do
    if socket.assigns[:current_company] do
      {:noreply, push_navigate(socket, to: ~p"/issues")}
    else
      {:noreply, assign(socket, :step_error, "Finish setup to enter Cympho.")}
    end
  end

  def handle_event("update_company_form", %{"company" => params}, socket) do
    params = maybe_apply_blueprint_defaults(params, socket.assigns.company_form)
    form = Map.merge(socket.assigns.company_form, params)
    {:noreply, socket |> assign(:company_form, form) |> assign(:step_error, nil)}
  end

  def handle_event("filter_blueprints", %{"blueprint_query" => query}, socket) do
    query = String.trim(query || "")

    {:noreply,
     socket
     |> assign(:blueprint_query, query)
     |> assign(:filtered_blueprints, filter_blueprints(socket.assigns.blueprints, query))}
  end

  # Ignores repeat clicks after a successful launch (the ready step already
  # shows the result); a second transaction would create a duplicate company.
  def handle_event("start_autonomous_company", _params, socket) do
    if socket.assigns.bootstrap_result do
      {:noreply, socket}
    else
      launch_company(socket)
    end
  end

  @allowed_adapters ~w(claude_code codex cursor http)

  defp launch_company(socket) do
    form = socket.assigns.company_form

    with :ok <- validate_step(:company, form) do
      attrs = %{
        "blueprint" => form["blueprint"],
        "name" => form["name"],
        "goal_title" => form["goal_title"],
        "issue_prefix" => form["issue_prefix"],
        "engineer_count" => engineer_count(form),
        "engineer_names" => form["engineer_names"] || [],
        "adapter" => sanitize_adapter(form["adapter"]),
        "agent_runtime" => %{
          "command" => form["runtime_command"],
          "model" => form["runtime_model"]
        },
        "owner_user_id" => socket.assigns.current_user.id
      }

      case create_company_safely(attrs) do
        {:ok, result} ->
          {:noreply,
           socket
           |> assign(:bootstrap_result, result)
           |> assign(:step_error, nil)
           |> assign(:current_step, 5)}

        {:error, reason} ->
          {:noreply, assign(socket, :step_error, "Could not create company: #{inspect(reason)}")}
      end
    else
      {:error, message} ->
        {:noreply, socket |> assign(:current_step, 2) |> assign(:step_error, message)}
    end
  end

  # The engine uses Repo.insert! throughout, so changeset-invalid input raises
  # out of the transaction instead of returning {:error, _}. Convert raises
  # into the error banner rather than crashing the LiveView and losing all
  # wizard state. Nothing persists either way — the transaction rolls back.
  defp create_company_safely(attrs) do
    Companies.create_autonomous_company(attrs)
  rescue
    error in [Ecto.InvalidChangesetError] -> {:error, error.changeset.errors}
    error -> {:error, error}
  end

  # The <select> constrains the browser, not the client: a tampered payload
  # could smuggle any existing atom into the agent adapter enum.
  defp sanitize_adapter(adapter) when adapter in @allowed_adapters, do: adapter
  defp sanitize_adapter(_), do: "claude_code"

  def engineer_count(form) do
    case Integer.parse(to_string(form["engineer_count"] || "2")) do
      {count, _} -> count |> max(0) |> min(8)
      :error -> 2
    end
  end

  def engineer_name_value(form, index) do
    case Enum.at(form["engineer_names"] || [], index - 1) do
      name when is_binary(name) and name != "" -> name
      _ -> "Engineer #{index}"
    end
  end

  def selected_blueprint(blueprints, form) do
    Enum.find(blueprints, &(&1.key == form["blueprint"])) || List.first(blueprints)
  end

  # The prefix cap is 7 (not the schema's 10) because the launch engine
  # truncates prefixes to 7 characters; the name minimum is 3 because the
  # company slug derived from it must satisfy validate_length(:slug, min: 3).
  defp validate_step(:company, form) do
    cond do
      String.trim(form["name"] || "") == "" ->
        {:error, "Company name is required."}

      String.length(String.trim(form["name"])) < 3 ->
        {:error, "Company name must be at least 3 characters."}

      String.trim(form["goal_title"] || "") == "" ->
        {:error, "Company goal is required."}

      not Regex.match?(~r/^[A-Z]{2,7}$/, form["issue_prefix"] || "") ->
        {:error, "Issue prefix must be 2-7 uppercase letters."}

      true ->
        :ok
    end
  end

  defp validate_step(_step, _form), do: :ok

  defp maybe_apply_blueprint_defaults(params, current_form) do
    selected = params["blueprint"] || current_form["blueprint"] || "software"
    previous = current_form["blueprint"] || "software"

    if selected != previous do
      case Companies.autonomous_company_blueprint(selected) do
        {:ok, blueprint} ->
          params
          |> Map.put("blueprint", selected)
          |> Map.put("goal_title", blueprint.default_goal)
          |> Map.put("issue_prefix", blueprint.default_prefix)

        {:error, :not_found} ->
          params
      end
    else
      Map.put_new(params, "blueprint", selected)
    end
  end

  defp filter_blueprints(blueprints, ""), do: blueprints

  defp filter_blueprints(blueprints, query) do
    normalized_query = String.downcase(query)

    Enum.filter(blueprints, fn blueprint ->
      [
        blueprint.key,
        blueprint.name,
        blueprint.description,
        blueprint.default_goal,
        blueprint.role_summary,
        Enum.join(blueprint.roles, " "),
        Enum.join(blueprint.capability_tags, " "),
        Enum.join(blueprint.seed_issue_titles, " ")
      ]
      |> Enum.join(" ")
      |> String.downcase()
      |> String.contains?(normalized_query)
    end)
  end

  defp role_label(role), do: Agent.role_label(role)

  # What the operator walks away with after each step — states the payoff, not
  # just the inputs, so the wizard feels like progress rather than a form.
  defp step_outcome(:welcome),
    do:
      "A few quick choices set up a CEO, CTO, specialist agents, a goal, a project, and seed issues."

  defp step_outcome(:blueprint),
    do: "The blueprint decides which agents get hired and what their first issues are."

  defp step_outcome(:company),
    do: "The prefix becomes your issue IDs (like ACME-1); the goal is what the CEO decomposes."

  defp step_outcome(:team),
    do:
      "CEO and CTO are always created. Engineers do the hands-on work — name them and pick their runtime."

  defp step_outcome(:launch),
    do:
      "One transaction creates the company, your owner seat, all agents, the goal, project, and first issues."

  defp step_outcome(:ready), do: "Everything below is live. Enter Cympho to start working."
  defp step_outcome(_), do: nil
end
>>>>>>> REPLACE
```

    File: `lib/cympho_web/live/onboarding_live/index.html.heex`

```
<<<<<<< SEARCH
<div class="min-h-screen flex items-start justify-center overflow-y-auto px-4 py-8">
  <div class="ember-aurora relative w-full max-w-4xl">
    <div class="relative z-[1]">
      <!-- Progress dots -->
      <div class="flex items-center justify-center gap-2 mb-8">
        <%= for {step, idx} <- Enum.with_index(@steps) do %>
          <div class={
          "h-2 rounded-full transition-all duration-300 " <>
          cond do
            idx < @current_step -> "w-6 bg-brand/55"
            idx == @current_step -> "w-2 bg-brand shadow-[0_0_12px_2px_rgb(var(--color-primary-rgb)/0.6)]"
            true -> "w-2 bg-white/10"
          end
        }>
          </div>
        <% end %>
      </div>
      
<!-- Step content -->
      <div class="text-center mb-8">
        <span class="ember-eyebrow">
          Step {@current_step + 1} of {length(@steps)}
        </span>
        <h1 class="ember-ink mt-4 mb-2 font-serif text-[clamp(28px,4vw,40px)] font-510 leading-[1.1] tracking-[-0.02em]">
          {@steps |> Enum.at(@current_step) |> Map.get(:title)}
        </h1>
        <p class="text-sm text-text-secondary">
          {@steps |> Enum.at(@current_step) |> Map.get(:description)}
        </p>
        <p
          :if={step_outcome(@steps |> Enum.at(@current_step) |> Map.get(:id))}
          class="mx-auto mt-3 max-w-md text-xs leading-5 text-text-tertiary"
        >
          {step_outcome(@steps |> Enum.at(@current_step) |> Map.get(:id))}
        </p>
      </div>
      
<!-- Welcome step -->
      <div :if={@current_step == 0} class="ember-glass card-lift p-6 mb-6">
        <div class="flex flex-col items-center gap-4 text-center">
          <div class="w-16 h-16 rounded-full bg-gradient-to-br from-brand/25 to-brand/5 ring-1 ring-brand/40 shadow-[0_0_28px_rgb(var(--color-primary-rgb)/0.4)] flex items-center justify-center">
            <svg class="w-8 h-8 text-brand" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 10V3L4 14h7v7l9-11h-7z"
              />
            </svg>
          </div>
          <div>
            <p class="text-sm text-text-secondary mb-2">
              Cympho turns a company goal into an operating loop: CEO, CTO, specialist agents, issues, budgets, runtime evidence, and owner signoff in one control plane.
            </p>
            <ul class="stagger-children text-sm text-text-tertiary space-y-1.5 text-left">
              <li class="flex items-center gap-2">
                <svg
                  class="w-4 h-4 text-emerald shrink-0"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M5 13l4 4L19 7"
                  />
                </svg>
                Track issues with kanban boards
              </li>
              <li class="flex items-center gap-2">
                <svg
                  class="w-4 h-4 text-emerald shrink-0"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M5 13l4 4L19 7"
                  />
                </svg>
                Assign AI agents to automate work
              </li>
              <li class="flex items-center gap-2">
                <svg
                  class="w-4 h-4 text-emerald shrink-0"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M5 13l4 4L19 7"
                  />
                </svg>
                Set goals and track progress
              </li>
              <li class="flex items-center gap-2">
                <svg
                  class="w-4 h-4 text-emerald shrink-0"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M5 13l4 4L19 7"
                  />
                </svg>
                Keyboard-first for speed
              </li>
            </ul>
          </div>
        </div>
      </div>
      
<!-- Workspace step -->
      <div :if={@current_step == 1} class="ember-glass p-6 mb-6">
        <form id="blueprint-search-form" phx-change="filter_blueprints" class="mb-3">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
            <div class="min-w-0 flex-1">
              <label class="block text-xs font-510 text-text-tertiary mb-1.5">
                Search blueprints
              </label>
              <input
                type="search"
                name="blueprint_query"
                value={@blueprint_query}
                placeholder="Security, content, sales, training..."
                class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:border-accent focus:outline-none"
              />
            </div>
            <p class="shrink-0 text-xs text-text-quaternary">
              {length(@filtered_blueprints)} of {length(@blueprints)}
            </p>
          </div>
        </form>

        <form
          id="company-starter-form"
          phx-change="update_company_form"
          phx-submit="start_autonomous_company"
          class="space-y-4"
        >
          <div>
            <div class="mb-2 flex items-center justify-between gap-3">
              <label class="block text-xs font-510 text-text-tertiary">Company blueprint</label>
              <span class="text-[11px] text-text-quaternary">
                Creates agents and first issues
              </span>
            </div>
            <div class="grid max-h-[30vh] gap-2 overflow-y-auto pr-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5">
              <label
                :for={blueprint <- @filtered_blueprints}
                class={[
                  "group flex min-h-[118px] cursor-pointer flex-col justify-between rounded-lg border bg-surface px-3 py-3 text-left transition",
                  if(@company_form["blueprint"] == blueprint.key,
                    do: "border-brand/60 bg-brand/10",
                    else: "border-border hover:border-border-hover hover:bg-surface-hover"
                  )
                ]}
              >
                <input
                  type="radio"
                  name="company[blueprint]"
                  value={blueprint.key}
                  checked={@company_form["blueprint"] == blueprint.key}
                  class="sr-only"
                />
                <span class="text-sm font-590 leading-5 text-text-primary">{blueprint.name}</span>
                <span
                  class="mt-1 block truncate text-[11px] leading-4 text-text-tertiary"
                  title={blueprint.role_summary}
                >
                  {blueprint.role_summary}
                </span>
                <span class="mt-3 flex flex-wrap gap-x-2 gap-y-1 text-[11px] font-510 uppercase tracking-[0.08em] text-text-quaternary">
                  <span>{blueprint.default_agent_count} agents</span>
                  <span>{blueprint.capability_count} capabilities</span>
                  <span>{blueprint.seed_issue_count} issues</span>
                </span>
              </label>
            </div>
            <div
              :if={Enum.empty?(@filtered_blueprints)}
              class="rounded-lg border border-border bg-surface px-3 py-6 text-center text-sm text-text-tertiary"
            >
              No matching blueprints.
            </div>
          </div>

          <div>
            <label class="block text-xs font-510 text-text-tertiary mb-1.5">Company name</label>
            <input
              name="company[name]"
              value={@company_form["name"]}
              class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:border-accent focus:outline-none"
            />
          </div>
          <div>
            <label class="block text-xs font-510 text-text-tertiary mb-1.5">Company goal</label>
            <textarea
              name="company[goal_title]"
              rows="3"
              class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:border-accent focus:outline-none"
            >{@company_form["goal_title"]}</textarea>
          </div>
          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class="block text-xs font-510 text-text-tertiary mb-1.5">Issue prefix</label>
              <input
                name="company[issue_prefix]"
                value={@company_form["issue_prefix"]}
                maxlength="10"
                class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary focus:border-accent focus:outline-none"
              />
            </div>
            <div>
              <label class="block text-xs font-510 text-text-tertiary mb-1.5">Engineers</label>
              <input
                type="number"
                min="1"
                max="8"
                name="company[engineer_count]"
                value={@company_form["engineer_count"]}
                class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary focus:border-accent focus:outline-none"
              />
            </div>
          </div>
          <button
            type="submit"
            class="w-full cta-glow rounded-button bg-brand px-4 py-2.5 text-sm font-510 text-on-primary hover:bg-accent-hover transition-colors"
          >
            Create autonomous company
          </button>
        </form>
      </div>
      
<!-- Shortcuts step -->
      <div :if={@current_step == 2} class="ember-glass p-6 mb-6">
        <p class="mb-4 text-xs leading-5 text-text-tertiary">
          Nothing to fill in here — just a few keys that make Cympho faster to move around.
        </p>
        <div class="stagger-children space-y-3">
          <div class="flex items-center justify-between text-sm">
            <span class="text-text-secondary">Command palette</span>
            <div class="flex gap-1"><kbd class="kbd">Cmd</kbd><kbd class="kbd">K</kbd></div>
          </div>
          <div class="flex items-center justify-between text-sm">
            <span class="text-text-secondary">New issue</span>
            <kbd class="kbd">C</kbd>
          </div>
          <div class="flex items-center justify-between text-sm">
            <span class="text-text-secondary">Go to Issues</span>
            <div class="flex gap-1"><kbd class="kbd">G</kbd><kbd class="kbd">I</kbd></div>
          </div>
          <div class="flex items-center justify-between text-sm">
            <span class="text-text-secondary">Go to Board</span>
            <div class="flex gap-1"><kbd class="kbd">G</kbd><kbd class="kbd">K</kbd></div>
          </div>
          <div class="flex items-center justify-between text-sm">
            <span class="text-text-secondary">Show shortcuts</span>
            <kbd class="kbd">?</kbd>
          </div>
        </div>
      </div>
      
<!-- Ready step -->
      <div :if={@current_step == 3} class="ember-glass card-lift p-6 mb-6">
        <div class="flex flex-col gap-4">
          <div class="flex flex-col items-center gap-3 text-center">
            <div class="w-14 h-14 rounded-full bg-emerald/10 ring-1 ring-emerald/40 shadow-[0_0_30px_rgb(var(--color-success-rgb)/0.5)] flex items-center justify-center">
              <svg
                class="w-7 h-7 text-emerald"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
            </div>
            <p class="text-sm text-text-secondary">
              Your autonomous company is ready. Here's what was created:
            </p>
          </div>

          <%= if @bootstrap_result do %>
            <div class="stagger-children space-y-2 text-sm">
              <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
                <span class="text-text-secondary">Company</span>
                <span class="text-text-primary font-590">{@bootstrap_result.company.name}</span>
              </div>
              <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
                <span class="text-text-secondary">Project</span>
                <.app_link
                  navigate={~p"/projects"}
                  class="text-accent hover:text-accent-hover font-590"
                >
                  {@bootstrap_result.project.name}
                </.app_link>
              </div>
              <div class="flex items-center justify-between gap-3 py-1.5 px-3 rounded-lg bg-surface">
                <span class="text-text-secondary">Blueprint</span>
                <span class="text-text-primary font-590 text-right">
                  {@bootstrap_result.blueprint.name}
                </span>
              </div>
              <div class="flex items-center justify-between gap-3 py-1.5 px-3 rounded-lg bg-surface">
                <span class="text-text-secondary">Manifest</span>
                <span class="text-text-primary font-590 text-right">
                  {@bootstrap_result.company.governance_config["company_blueprint_manifest"][
                    "agent_count"
                  ]} agents · {@bootstrap_result.company.governance_config[
                    "company_blueprint_manifest"
                  ]["capability_count"]} capabilities
                </span>
              </div>
              <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
                <span class="text-text-secondary">Mission</span>
                <span
                  class="text-text-primary truncate max-w-[200px]"
                  title={@bootstrap_result.goal.title}
                >
                  {@bootstrap_result.goal.title}
                </span>
              </div>
              <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
                <span class="text-text-secondary">Agents</span>
                <span class="text-text-primary font-590">
                  {length(@bootstrap_result.agents)} ({Enum.map_join(
                    @bootstrap_result.agents,
                    ", ",
                    &role_label(&1.role)
                  )})
                </span>
              </div>
              <div class="py-1.5 px-3">
                <span class="text-text-secondary text-xs">Seed issues</span>
                <div class="mt-1.5 space-y-1">
                  <%= for issue <- @bootstrap_result.seed_issues do %>
                    <div class="flex items-center gap-2">
                      <.app_link
                        navigate={~p"/issues/#{issue.id}"}
                        class="text-xs text-accent hover:text-accent-hover font-mono"
                      >
                        {issue.identifier}
                      </.app_link>
                      <span class="text-xs text-text-tertiary truncate">{issue.title}</span>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          <% else %>
            <p class="text-sm text-text-tertiary text-center">
              You're ready to start using Cympho. Create your first project or jump straight to the issue board.
            </p>
          <% end %>

          <div class="flex gap-3 w-full pt-2">
            <.app_link
              navigate={~p"/kanban"}
              class="flex-1 text-center bg-surface hover:bg-surface-hover border border-border text-text-secondary hover:text-text-primary font-590 text-sm px-4 py-2.5 rounded-lg transition-colors"
            >
              Kanban Board
            </.app_link>
            <.app_link
              navigate={~p"/issues"}
              class="flex-1 text-center cta-glow bg-brand hover:bg-accent text-on-primary font-590 text-sm px-4 py-2.5 rounded-button transition-colors"
            >
              Go to Issues
            </.app_link>
          </div>
        </div>
      </div>
      
<!-- Navigation buttons -->
      <div class="flex items-center justify-between">
        <button
          :if={@current_step > 0}
          type="button"
          phx-click="prev_step"
          class="text-sm text-text-tertiary hover:text-text-secondary transition-colors px-3 py-2 min-h-[44px]"
        >
          Back
        </button>
        <button
          :if={@current_step == 0}
          type="button"
          phx-click="skip"
          class="text-sm text-text-quaternary hover:text-text-tertiary transition-colors px-3 py-2 min-h-[44px]"
        >
          Skip setup
        </button>
        <div class="flex items-center gap-3 ml-auto">
          <span class="text-xs text-text-quaternary">
            {@current_step + 1} of {length(@steps)}
          </span>
          <button
            type="button"
            phx-click="next_step"
            class={nav_cta_class(@current_step)}
          >
            {if @current_step == length(@steps) - 1 do
              "Get Started"
            else
              "Continue"
            end}
          </button>
        </div>
      </div>
    </div>
  </div>
</div>
=======
<div class="min-h-screen flex items-start justify-center overflow-y-auto px-4 py-8">
  <div class="ember-aurora relative w-full max-w-4xl">
    <div class="relative z-[1]">
      <!-- Progress dots -->
      <div class="flex items-center justify-center gap-2 mb-8">
        <%= for {step, idx} <- Enum.with_index(@steps) do %>
          <div class={
          "h-2 rounded-full transition-all duration-300 " <>
          cond do
            idx < @current_step -> "w-6 bg-brand/55"
            idx == @current_step -> "w-2 bg-brand shadow-[0_0_12px_2px_rgb(var(--color-primary-rgb)/0.6)]"
            true -> "w-2 bg-white/10"
          end
        }>
          </div>
        <% end %>
      </div>
      
<!-- Step content -->
      <div class="text-center mb-8">
        <span class="ember-eyebrow">
          Step {@current_step + 1} of {length(@steps)}
        </span>
        <h1 class="ember-ink mt-4 mb-2 font-serif text-[clamp(28px,4vw,40px)] font-510 leading-[1.1] tracking-[-0.02em]">
          {@steps |> Enum.at(@current_step) |> Map.get(:title)}
        </h1>
        <p class="text-sm text-text-secondary">
          {@steps |> Enum.at(@current_step) |> Map.get(:description)}
        </p>
        <p
          :if={step_outcome(@steps |> Enum.at(@current_step) |> Map.get(:id))}
          class="mx-auto mt-3 max-w-md text-xs leading-5 text-text-tertiary"
        >
          {step_outcome(@steps |> Enum.at(@current_step) |> Map.get(:id))}
        </p>
      </div>

      <div
        :if={@step_error}
        class="mb-4 rounded-lg border border-red-500/40 bg-red-500/10 px-4 py-2.5 text-sm text-red-300"
      >
        {@step_error}
      </div>
      
<!-- Welcome step -->
      <div :if={@current_step == 0} class="ember-glass card-lift p-6 mb-6">
        <div class="flex flex-col items-center gap-4 text-center">
          <div class="w-16 h-16 rounded-full bg-gradient-to-br from-brand/25 to-brand/5 ring-1 ring-brand/40 shadow-[0_0_28px_rgb(var(--color-primary-rgb)/0.4)] flex items-center justify-center">
            <svg class="w-8 h-8 text-brand" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 10V3L4 14h7v7l9-11h-7z"
              />
            </svg>
          </div>
          <div>
            <p class="text-sm text-text-secondary mb-2">
              Cympho turns a company goal into an operating loop: CEO, CTO, specialist agents, issues, budgets, runtime evidence, and owner signoff in one control plane.
            </p>
            <ul class="stagger-children text-sm text-text-tertiary space-y-1.5 text-left">
              <li class="flex items-center gap-2">
                <svg
                  class="w-4 h-4 text-emerald shrink-0"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M5 13l4 4L19 7"
                  />
                </svg>
                Track issues with kanban boards
              </li>
              <li class="flex items-center gap-2">
                <svg
                  class="w-4 h-4 text-emerald shrink-0"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M5 13l4 4L19 7"
                  />
                </svg>
                Assign AI agents to automate work
              </li>
              <li class="flex items-center gap-2">
                <svg
                  class="w-4 h-4 text-emerald shrink-0"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M5 13l4 4L19 7"
                  />
                </svg>
                Set goals and track progress
              </li>
              <li class="flex items-center gap-2">
                <svg
                  class="w-4 h-4 text-emerald shrink-0"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M5 13l4 4L19 7"
                  />
                </svg>
                Keyboard-first for speed
              </li>
            </ul>
          </div>
        </div>
      </div>
      
<!-- Blueprint step -->
      <div :if={@current_step == 1} class="ember-glass p-6 mb-6">
        <form id="blueprint-search-form" phx-change="filter_blueprints" class="mb-3">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
            <div class="min-w-0 flex-1">
              <label class="block text-xs font-510 text-text-tertiary mb-1.5">
                Search blueprints
              </label>
              <input
                type="search"
                name="blueprint_query"
                value={@blueprint_query}
                placeholder="Security, content, sales, training..."
                class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:border-accent focus:outline-none"
              />
            </div>
            <p class="shrink-0 text-xs text-text-quaternary">
              {length(@filtered_blueprints)} of {length(@blueprints)}
            </p>
          </div>
        </form>

        <form id="blueprint-form" phx-change="update_company_form">
          <div class="mb-2 flex items-center justify-between gap-3">
            <label class="block text-xs font-510 text-text-tertiary">Company blueprint</label>
            <span class="text-[11px] text-text-quaternary">
              Creates agents and first issues
            </span>
          </div>
          <div class="grid max-h-[42vh] gap-2 overflow-y-auto pr-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5">
            <label
              :for={blueprint <- @filtered_blueprints}
              class={[
                "group flex min-h-[118px] cursor-pointer flex-col justify-between rounded-lg border bg-surface px-3 py-3 text-left transition",
                if(@company_form["blueprint"] == blueprint.key,
                  do: "border-brand/60 bg-brand/10",
                  else: "border-border hover:border-border-hover hover:bg-surface-hover"
                )
              ]}
            >
              <input
                type="radio"
                name="company[blueprint]"
                value={blueprint.key}
                checked={@company_form["blueprint"] == blueprint.key}
                class="sr-only"
              />
              <span class="text-sm font-590 leading-5 text-text-primary">{blueprint.name}</span>
              <span
                class="mt-1 block truncate text-[11px] leading-4 text-text-tertiary"
                title={blueprint.role_summary}
              >
                {blueprint.role_summary}
              </span>
              <span class="mt-3 flex flex-wrap gap-x-2 gap-y-1 text-[11px] font-510 uppercase tracking-[0.08em] text-text-quaternary">
                <span>{blueprint.default_agent_count} agents</span>
                <span>{blueprint.capability_count} capabilities</span>
                <span>{blueprint.seed_issue_count} issues</span>
              </span>
            </label>
          </div>
          <div
            :if={Enum.empty?(@filtered_blueprints)}
            class="rounded-lg border border-border bg-surface px-3 py-6 text-center text-sm text-text-tertiary"
          >
            No matching blueprints.
          </div>
        </form>
      </div>
      
<!-- Company step -->
      <div :if={@current_step == 2} class="ember-glass p-6 mb-6">
        <form id="company-step-form" phx-change="update_company_form" class="space-y-4">
          <div>
            <label class="block text-xs font-510 text-text-tertiary mb-1.5">Company name</label>
            <input
              name="company[name]"
              value={@company_form["name"]}
              class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:border-accent focus:outline-none"
            />
          </div>
          <div>
            <label class="block text-xs font-510 text-text-tertiary mb-1.5">Company goal</label>
            <textarea
              name="company[goal_title]"
              rows="3"
              class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:border-accent focus:outline-none"
            >{@company_form["goal_title"]}</textarea>
          </div>
          <div class="max-w-[200px]">
            <label class="block text-xs font-510 text-text-tertiary mb-1.5">Issue prefix</label>
            <input
              name="company[issue_prefix]"
              value={@company_form["issue_prefix"]}
              maxlength="7"
              class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary focus:border-accent focus:outline-none"
            />
          </div>
        </form>
      </div>
      
<!-- Team step -->
      <div :if={@current_step == 3} class="ember-glass p-6 mb-6">
        <div class="mb-5 grid gap-2 sm:grid-cols-2">
          <div class="rounded-lg border border-brand/40 bg-brand/10 px-4 py-3">
            <p class="text-sm font-590 text-text-primary">CEO</p>
            <p class="mt-0.5 text-xs text-text-tertiary">
              Owns the goal, decomposes strategy, delegates. Always created.
            </p>
          </div>
          <div class="rounded-lg border border-brand/40 bg-brand/10 px-4 py-3">
            <p class="text-sm font-590 text-text-primary">CTO</p>
            <p class="mt-0.5 text-xs text-text-tertiary">
              Turns strategy into technical plans and reviews the work. Always created.
            </p>
          </div>
        </div>
        <p class="mb-4 text-xs text-text-quaternary">
          Blueprint roster: {selected_blueprint(@blueprints, @company_form).role_summary}
        </p>

        <form id="team-step-form" phx-change="update_company_form" class="space-y-4">
          <div class="max-w-[200px]">
            <label class="block text-xs font-510 text-text-tertiary mb-1.5">Engineers</label>
            <input
              type="number"
              min="0"
              max="8"
              name="company[engineer_count]"
              value={@company_form["engineer_count"]}
              class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary focus:border-accent focus:outline-none"
            />
          </div>
          <div :if={engineer_count(@company_form) > 0} class="grid gap-2 sm:grid-cols-2">
            <div :for={index <- 1..engineer_count(@company_form)}>
              <label class="block text-xs font-510 text-text-tertiary mb-1.5">
                Engineer {index} name
              </label>
              <input
                name="company[engineer_names][]"
                value={engineer_name_value(@company_form, index)}
                class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary focus:border-accent focus:outline-none"
              />
            </div>
          </div>

          <fieldset class="rounded-lg border border-border p-4">
            <legend class="px-1 text-xs font-510 text-text-tertiary">Agent runtime</legend>
            <div class="grid gap-3 sm:grid-cols-3">
              <div>
                <label class="block text-xs font-510 text-text-tertiary mb-1.5">Adapter</label>
                <select
                  name="company[adapter]"
                  class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary focus:border-accent focus:outline-none"
                >
                  {Phoenix.HTML.Form.options_for_select(
                    [
                      {"Claude Code", "claude_code"},
                      {"Codex", "codex"},
                      {"Cursor", "cursor"},
                      {"HTTP", "http"}
                    ],
                    @company_form["adapter"]
                  )}
                </select>
              </div>
              <div>
                <label class="block text-xs font-510 text-text-tertiary mb-1.5">Command</label>
                <input
                  name="company[runtime_command]"
                  value={@company_form["runtime_command"]}
                  placeholder="claude (default)"
                  class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:border-accent focus:outline-none"
                />
              </div>
              <div>
                <label class="block text-xs font-510 text-text-tertiary mb-1.5">Model</label>
                <input
                  name="company[runtime_model]"
                  value={@company_form["runtime_model"]}
                  placeholder="provider default"
                  class="w-full rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:border-accent focus:outline-none"
                />
              </div>
            </div>
            <p class="mt-2 text-[11px] leading-4 text-text-quaternary">
              Applies to every agent. Command can be a Claude-compatible wrapper (e.g. cz); model is exported as ANTHROPIC_MODEL.
            </p>
          </fieldset>
        </form>
      </div>
      
<!-- Launch step -->
      <div :if={@current_step == 4} class="ember-glass card-lift p-6 mb-6">
        <div class="stagger-children space-y-2 text-sm">
          <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
            <span class="text-text-secondary">Company</span>
            <span class="text-text-primary font-590">{@company_form["name"]}</span>
          </div>
          <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
            <span class="text-text-secondary">Blueprint</span>
            <span class="text-text-primary font-590">
              {selected_blueprint(@blueprints, @company_form).name}
            </span>
          </div>
          <div class="flex items-center justify-between gap-3 py-1.5 px-3 rounded-lg bg-surface">
            <span class="text-text-secondary">Goal</span>
            <span
              class="max-w-[280px] truncate text-text-primary"
              title={@company_form["goal_title"]}
            >
              {@company_form["goal_title"]}
            </span>
          </div>
          <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
            <span class="text-text-secondary">Issue prefix</span>
            <span class="text-text-primary font-mono font-590">
              {@company_form["issue_prefix"]}
            </span>
          </div>
          <div class="flex items-center justify-between gap-3 py-1.5 px-3 rounded-lg bg-surface">
            <span class="text-text-secondary">Engineers</span>
            <span class="max-w-[280px] truncate text-text-primary font-590">
              {engineer_count(@company_form)}<span :if={engineer_count(@company_form) > 0}>
                · {Enum.map_join(
                  1..engineer_count(@company_form),
                  ", ",
                  &engineer_name_value(@company_form, &1)
                )}</span>
            </span>
          </div>
          <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
            <span class="text-text-secondary">Runtime</span>
            <span class="text-text-primary font-590">
              {@company_form["adapter"]} · {if @company_form["runtime_command"] not in [nil, ""],
                do: @company_form["runtime_command"],
                else: "default command"} · {if @company_form["runtime_model"] not in [nil, ""],
                do: @company_form["runtime_model"],
                else: "default model"}
            </span>
          </div>
        </div>
        <button
          type="button"
          phx-click="start_autonomous_company"
          phx-disable-with="Launching..."
          class="mt-5 w-full cta-glow rounded-button bg-brand px-4 py-2.5 text-sm font-510 text-on-primary hover:bg-accent-hover transition-colors"
        >
          Launch autonomous company
        </button>
      </div>
      
<!-- Ready step -->
      <div :if={@current_step == 5} class="ember-glass card-lift p-6 mb-6">
        <div class="flex flex-col gap-4">
          <div class="flex flex-col items-center gap-3 text-center">
            <div class="w-14 h-14 rounded-full bg-emerald/10 ring-1 ring-emerald/40 shadow-[0_0_30px_rgb(var(--color-success-rgb)/0.5)] flex items-center justify-center">
              <svg
                class="w-7 h-7 text-emerald"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
            </div>
            <p class="text-sm text-text-secondary">
              Your autonomous company is ready. Here's what was created:
            </p>
          </div>

          <%= if @bootstrap_result do %>
            <div class="stagger-children space-y-2 text-sm">
              <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
                <span class="text-text-secondary">Company</span>
                <span class="text-text-primary font-590">{@bootstrap_result.company.name}</span>
              </div>
              <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
                <span class="text-text-secondary">Project</span>
                <span class="text-text-primary font-590">{@bootstrap_result.project.name}</span>
              </div>
              <div class="flex items-center justify-between gap-3 py-1.5 px-3 rounded-lg bg-surface">
                <span class="text-text-secondary">Blueprint</span>
                <span class="text-text-primary font-590 text-right">
                  {@bootstrap_result.blueprint.name}
                </span>
              </div>
              <div class="flex items-center justify-between gap-3 py-1.5 px-3 rounded-lg bg-surface">
                <span class="text-text-secondary">Manifest</span>
                <span class="text-text-primary font-590 text-right">
                  {@bootstrap_result.company.governance_config["company_blueprint_manifest"][
                    "agent_count"
                  ]} agents · {@bootstrap_result.company.governance_config[
                    "company_blueprint_manifest"
                  ]["capability_count"]} capabilities
                </span>
              </div>
              <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
                <span class="text-text-secondary">Mission</span>
                <span
                  class="text-text-primary truncate max-w-[200px]"
                  title={@bootstrap_result.goal.title}
                >
                  {@bootstrap_result.goal.title}
                </span>
              </div>
              <div class="flex items-center justify-between py-1.5 px-3 rounded-lg bg-surface">
                <span class="text-text-secondary">Agents</span>
                <span class="text-text-primary font-590">
                  {length(@bootstrap_result.agents)} ({Enum.map_join(
                    @bootstrap_result.agents,
                    ", ",
                    &role_label(&1.role)
                  )})
                </span>
              </div>
              <div class="py-1.5 px-3">
                <span class="text-text-secondary text-xs">Seed issues</span>
                <div class="mt-1.5 space-y-1">
                  <%= for issue <- @bootstrap_result.seed_issues do %>
                    <div class="flex items-center gap-2">
                      <span class="text-xs text-accent font-mono">{issue.identifier}</span>
                      <span class="text-xs text-text-tertiary truncate">{issue.title}</span>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          <% else %>
            <p class="text-sm text-text-tertiary text-center">
              You're ready to start using Cympho. Create your first project or jump straight to the issue board.
            </p>
          <% end %>

          <div class="border-t border-border pt-4">
            <p class="mb-3 text-xs text-text-quaternary">
              A few keys that make Cympho faster to move around:
            </p>
            <div class="stagger-children space-y-3">
              <div class="flex items-center justify-between text-sm">
                <span class="text-text-secondary">Command palette</span>
                <div class="flex gap-1"><kbd class="kbd">Cmd</kbd><kbd class="kbd">K</kbd></div>
              </div>
              <div class="flex items-center justify-between text-sm">
                <span class="text-text-secondary">New issue</span>
                <kbd class="kbd">C</kbd>
              </div>
              <div class="flex items-center justify-between text-sm">
                <span class="text-text-secondary">Go to Issues</span>
                <div class="flex gap-1"><kbd class="kbd">G</kbd><kbd class="kbd">I</kbd></div>
              </div>
              <div class="flex items-center justify-between text-sm">
                <span class="text-text-secondary">Go to Board</span>
                <div class="flex gap-1"><kbd class="kbd">G</kbd><kbd class="kbd">K</kbd></div>
              </div>
              <div class="flex items-center justify-between text-sm">
                <span class="text-text-secondary">Show shortcuts</span>
                <kbd class="kbd">?</kbd>
              </div>
            </div>
          </div>

          <div class="flex gap-3 w-full pt-2">
            <.link
              :if={@bootstrap_result}
              href={"/switch-company/#{@bootstrap_result.company.id}?return_to=/issues"}
              class="flex-1 text-center cta-glow bg-brand hover:bg-accent text-on-primary font-590 text-sm px-4 py-2.5 rounded-button transition-colors"
            >
              Enter Cympho
            </.link>
          </div>
        </div>
      </div>
      
<!-- Navigation buttons -->
      <div class="flex items-center justify-between">
        <button
          :if={@current_step > 0 && @current_step < 5}
          type="button"
          phx-click="prev_step"
          class="text-sm text-text-tertiary hover:text-text-secondary transition-colors px-3 py-2 min-h-[44px]"
        >
          Back
        </button>
        <button
          :if={@current_step == 0 && @current_company}
          type="button"
          phx-click="skip"
          class="text-sm text-text-quaternary hover:text-text-tertiary transition-colors px-3 py-2 min-h-[44px]"
        >
          Skip setup
        </button>
        <div class="flex items-center gap-3 ml-auto">
          <span class="text-xs text-text-quaternary">
            {@current_step + 1} of {length(@steps)}
          </span>
          <button
            :if={@current_step < 4}
            type="button"
            phx-click="next_step"
            class="cta-glow bg-brand hover:bg-accent text-on-primary font-510 text-sm px-5 py-2.5 rounded-button transition-colors min-h-[44px]"
          >
            Continue
          </button>
        </div>
      </div>
    </div>
  </div>
</div>
>>>>>>> REPLACE
```

  - **Troubleshooting:** `None — whole-file replacement; compile errors mean the transcription diverged, so re-apply both blocks byte-for-byte.`
  - **Done when:** both files compile and TASK-021's tests pass.
  - **Verify:** `mix compile --warnings-as-errors` — exits 0.

- [ ] **TASK-021** [test] Rewrite the onboarding LiveView tests for the six-step wizard.
  - **Paths:** `test/cympho_web/live/onboarding_live_test.exs` (modified)
  - **Implements:** `REQ-005`, `REQ-006`, `REQ-007`, `DES-006` · **Verifies:** `TEST-006` covering `AC-014`, `AC-015`, `AC-016`, `AC-017`, `AC-018`, `AC-019`, `AC-020`, `AC-021`, `AC-022`, `AC-023`, `AC-024`, `EDGE-005`, `EDGE-006`, `EDGE-009`, `EDGE-010`, `EDGE-011` · **Depends:** `TASK-020`
  - **Context:** The existing test file drives the old 4-step wizard's `#company-starter-form`, which no longer exists after TASK-020. This whole-file replacement covers the full walk-through (owner membership, engineer names, runtime config), invalid-prefix blocking, blueprint refill, double-launch guard, both skip behaviors, and keeps the blueprint filter test. `Companies.list_memberships/1` preloads `:user`; the LiveCase user email matches `"live-user-"`.
  - **Steps:**
    1. Apply the whole-file replacement edit block in Code.
    2. Confirm the file contains six tests: full walk-through, invalid prefix blocked, blueprint refill, skip with company, skip without company, blueprint filter.
  - **Code:** apply to `test/cympho_web/live/onboarding_live_test.exs`:

    File: `test/cympho_web/live/onboarding_live_test.exs`

```
<<<<<<< SEARCH
defmodule CymphoWeb.OnboardingLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Companies

  describe "Onboarding page" do
    test "creates a company from a selected blueprint", %{conn: conn} do
      {:ok, view, html} = live(conn, "/onboarding")

      assert html =~ "Start an autonomous company"
      assert html =~ "Cympho turns a company goal into an operating loop"
      refute html =~ "Cympho runs like Paperclip"

      html =
        view
        |> element("button", "Continue")
        |> render_click()

      assert html =~ "Company blueprint"
      assert html =~ "Go-to-market company"
      assert html =~ "Product discovery company"
      assert html =~ "QA and release company"
      assert html =~ "Community growth company"
      assert html =~ "Security compliance company"
      assert html =~ "Training academy company"
      assert html =~ "agents"
      assert html =~ "capabilities"

      html =
        view
        |> form("#company-starter-form",
          company: %{
            "blueprint" => "go_to_market",
            "name" => "Live Growth Blueprint",
            "goal_title" => "Build and run the business autonomously",
            "issue_prefix" => "LLM",
            "engineer_count" => "1"
          }
        )
        |> render_change()

      assert html =~ "Launch a repeatable go-to-market motion for the offer"
      assert html =~ ~s(value="GTM")

      html =
        view
        |> form("#company-starter-form",
          company: %{
            "blueprint" => "go_to_market",
            "name" => "Live Growth Blueprint",
            "goal_title" => "Launch a repeatable go-to-market motion for the offer",
            "issue_prefix" => "GTM",
            "engineer_count" => "1"
          }
        )
        |> render_submit()

      assert html =~ "Your autonomous company is ready"
      assert html =~ "Go-to-market company"
      assert html =~ "Growth OS"
      assert html =~ "Manifest"
      assert html =~ "agents ·"
      assert html =~ "capabilities"
      assert html =~ "Product Manager"
      assert html =~ "Sales Development"
      refute html =~ "Product_manager"
      refute html =~ "Sales_development"

      company = Companies.get_company_by_slug("live-growth-blueprint")
      assert company.governance_config["company_blueprint"] == "go_to_market"
      assert company.governance_config["company_blueprint_manifest"]["agent_count"] == 10
      assert company.governance_config["company_blueprint_manifest"]["seed_issue_count"] == 5

      roles =
        company.id
        |> Companies.list_company_agents()
        |> Enum.map(& &1.role)

      assert :marketer in roles
      assert :sales_development in roles
      assert :customer_support in roles
    end

    test "filters the larger blueprint catalog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      html =
        view
        |> element("button", "Continue")
        |> render_click()

      assert html =~ "17 of 17"

      html =
        view
        |> form("#blueprint-search-form", blueprint_query: "security")
        |> render_change()

      assert html =~ "Security compliance company"
      assert html =~ "1 of 17"
      refute html =~ "Training academy company"

      html =
        view
        |> form("#blueprint-search-form", blueprint_query: "training")
        |> render_change()

      assert html =~ "Training academy company"
      assert html =~ "1 of 17"
      refute html =~ "Security compliance company"
    end
  end
end
=======
defmodule CymphoWeb.OnboardingLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Companies

  describe "Onboarding wizard" do
    test "walks the wizard and launches a company with owner, engineers, and runtime", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/onboarding")
      assert html =~ "Start an autonomous company"
      assert html =~ "Step 1 of 6"

      # welcome -> blueprint
      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Company blueprint"

      view
      |> form("#blueprint-form", company: %{"blueprint" => "software"})
      |> render_change()

      # blueprint -> company
      view |> element("button", "Continue") |> render_click()

      view
      |> form("#company-step-form",
        company: %{
          "name" => "Wizard Co",
          "goal_title" => "Ship the wizard",
          "issue_prefix" => "WIZ"
        }
      )
      |> render_change()

      # company -> team
      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Always created."
      assert html =~ "Adapter"

      view
      |> form("#team-step-form",
        company: %{
          "engineer_count" => "2",
          "engineer_names" => ["Ada", "Grace"],
          "adapter" => "claude_code",
          "runtime_command" => "cz",
          "runtime_model" => "claude-sonnet-5"
        }
      )
      |> render_change()

      # team -> launch
      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Launch autonomous company"
      assert html =~ "Ada"

      html = view |> element("button", "Launch autonomous company") |> render_click()
      assert html =~ "all set!"
      assert html =~ "Enter Cympho"

      company = Companies.get_company_by_slug("wizard-co")
      assert company

      # The signed-in LiveCase user must own the new company. list_memberships/1
      # preloads :user, so identity is assertable without a LiveCase helper.
      assert [membership] = Companies.list_memberships(company.id)
      assert membership.role == "owner"
      assert membership.is_board_member
      assert membership.user.email =~ "live-user-"

      agents = Companies.list_company_agents(company.id)
      engineer_names = agents |> Enum.filter(&(&1.role == :engineer)) |> Enum.map(& &1.name)
      assert Enum.sort(engineer_names) == ["Ada", "Grace"]

      for agent <- agents do
        assert agent.runtime_config["command"] == "cz"
        assert agent.runtime_config["env"]["ANTHROPIC_MODEL"] == "claude-sonnet-5"
      end

      # A second launch click is ignored: a duplicate would get slug wizard-co-1.
      render_click(view, "start_autonomous_company")
      assert Companies.get_company_by_slug("wizard-co-1") == nil
    end

    test "blocks the company step on an invalid issue prefix", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      view |> element("button", "Continue") |> render_click()
      view |> element("button", "Continue") |> render_click()

      view
      |> form("#company-step-form",
        company: %{"name" => "Bad Prefix Co", "issue_prefix" => "bad"}
      )
      |> render_change()

      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Issue prefix must be 2-7 uppercase letters."
      assert html =~ "Step 3 of 6"
    end

    test "blocks the company step when the goal is blank", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      view |> element("button", "Continue") |> render_click()
      view |> element("button", "Continue") |> render_click()

      view
      |> form("#company-step-form",
        company: %{"name" => "Goalless Co", "goal_title" => "   ", "issue_prefix" => "GOAL"}
      )
      |> render_change()

      html = view |> element("button", "Continue") |> render_click()
      assert html =~ "Company goal is required."
      assert html =~ "Step 3 of 6"
    end

    test "shows the error banner when the launch transaction fails", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      # A 256-char goal passes the wizard's blank check but fails
      # Goal.changeset's max-255 validation inside the launch transaction.
      render_change(view, "update_company_form", %{
        "company" => %{
          "name" => "Banner Co",
          "goal_title" => String.duplicate("g", 256),
          "issue_prefix" => "BAN"
        }
      })

      html = render_click(view, "start_autonomous_company")
      assert html =~ "Could not create company:"
      assert Companies.get_company_by_slug("banner-co") == nil
    end

    test "coerces a tampered adapter to claude_code", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      # The <select> constrains the browser, not the client: push the change
      # event directly, as a tampered payload would.
      render_change(view, "update_company_form", %{
        "company" => %{"name" => "Tamper Co", "issue_prefix" => "TMP", "adapter" => "process"}
      })

      render_click(view, "start_autonomous_company")

      company = Companies.get_company_by_slug("tamper-co")
      assert company

      for agent <- Companies.list_company_agents(company.id) do
        assert agent.adapter == :claude_code
      end
    end

    test "changing the blueprint refills goal and prefix", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      view |> element("button", "Continue") |> render_click()

      view
      |> form("#blueprint-form", company: %{"blueprint" => "go_to_market"})
      |> render_change()

      html = view |> element("button", "Continue") |> render_click()
      assert html =~ ~s(value="GTM")
      assert html =~ "Launch a repeatable go-to-market motion for the offer"
    end

    test "skip navigates users who already have a company", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      assert {:error, {:live_redirect, %{to: "/issues"}}} =
               view |> element("button", "Skip setup") |> render_click()
    end

    test "skip is refused while the user has no company" do
      {:ok, user} =
        Cympho.Users.create_user(%{
          email: "wizard-solo-#{System.unique_integer([:positive])}@example.com",
          name: "Wizard Solo",
          password: "password1234"
        })

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, user.id)

      {:ok, view, _html} = live(conn, "/onboarding")

      html = render_click(view, "skip")
      assert html =~ "Finish setup to enter Cympho."
    end

    test "filters the larger blueprint catalog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/onboarding")

      html =
        view
        |> element("button", "Continue")
        |> render_click()

      assert html =~ "17 of 17"

      html =
        view
        |> form("#blueprint-search-form", blueprint_query: "security")
        |> render_change()

      assert html =~ "Security compliance company"
      assert html =~ "1 of 17"
      refute html =~ "Training academy company"

      html =
        view
        |> form("#blueprint-search-form", blueprint_query: "training")
        |> render_change()

      assert html =~ "Training academy company"
      assert html =~ "1 of 17"
      refute html =~ "Security compliance company"
    end
  end
end
>>>>>>> REPLACE
```

  - **Troubleshooting:** `None — whole-file replacement of a test file.`
  - **Done when:** all six tests pass.
  - **Verify:** `mix test test/cympho_web/live/onboarding_live_test.exs` — expected output contains `0 failures`.

- [ ] **TASK-022** [migration] Add the orphan-adoption + NOT NULL migration for `projects.company_id` (Deploy B).
  - **Paths:** `priv/repo/migrations/20260715000000_require_company_on_projects.exs` (created)
  - **Implements:** `REQ-008`, `DES-009` (covers `AC-027`, `AC-028`, `EDGE-008` — verified manually per the Rollout Plan's Phase B script, not by an automated test: the local dev/test databases never contain orphans, so the adoption and raise branches only execute against production data) · **Verifies:** `N/A — mix ecto.migrate exercises only the no-orphan branch locally` · **Depends:** `TASK-004`
  - **Context:** After the changeset hardening (TASK-004), the DB column `projects.company_id` is still nullable, and production holds one orphan project ("AILogic", prefix "AILGC"). This migration adopts orphans into the oldest company (ordered `inserted_at ASC, id ASC`) and sets the column NOT NULL; it raises with the exact message "orphan projects exist but no company to adopt them" when orphans exist but no company does. **Production ordering:** this file must NOT be present in the tree during the Phase A deploy (see the Rollout Plan) — production has an orphan and zero companies until the operator completes onboarding, so a combined deploy would abort.
  - **Steps:**
    1. Create the file at the exact path above with the contents in Code.
    2. Exports: `Cympho.Repo.Migrations.RequireCompanyOnProjects.up/0`, `Cympho.Repo.Migrations.RequireCompanyOnProjects.down/0`.
  - **Code:** complete contents of `priv/repo/migrations/20260715000000_require_company_on_projects.exs`:
    ```elixir
    defmodule Cympho.Repo.Migrations.RequireCompanyOnProjects do
      use Ecto.Migration

      def up do
        # Adopt legacy orphan projects (created before the company gate existed)
        # into the oldest company, then lock the column. Fails loudly if orphans
        # exist with no company to adopt them — create a company first.
        execute """
        DO $$
        DECLARE
          adopt_company_id uuid;
          orphan_count integer;
        BEGIN
          SELECT count(*) INTO orphan_count FROM projects WHERE company_id IS NULL;
          IF orphan_count > 0 THEN
            SELECT id INTO adopt_company_id
              FROM companies ORDER BY inserted_at ASC, id ASC LIMIT 1;
            IF adopt_company_id IS NULL THEN
              RAISE EXCEPTION 'orphan projects exist but no company to adopt them';
            END IF;
            UPDATE projects SET company_id = adopt_company_id WHERE company_id IS NULL;
          END IF;
        END $$;
        """

        execute "ALTER TABLE projects ALTER COLUMN company_id SET NOT NULL"
      end

      def down do
        execute "ALTER TABLE projects ALTER COLUMN company_id DROP NOT NULL"
      end
    end
    ```
  - **Troubleshooting:**
    - `orphan projects exist but no company to adopt them` during `mix ecto.migrate` → the database has NULL-company projects and zero companies → create a company first (complete onboarding), then re-run.
    - `column "company_id" of relation "projects" contains null values` → the adoption UPDATE did not run before the NOT NULL → confirm the `DO $$ ... $$;` block precedes the `ALTER TABLE` in `up/0`.
  - **Done when:** `mix ecto.reset` applies the migration cleanly on a fresh dev DB and the full suite passes.
  - **Verify:** `mix ecto.migrate` — output contains `Migrated 20260715000000`.

- [ ] **TASK-023** [verification] Run the full verification sweep.
  - **Paths:** `N/A — verification only; no file changes`.
  - **Implements:** `N/A` · **Verifies:** `TEST-007` covering `AC-007`, `AC-034` · **Depends:** `TASK-022`
  - **Context:** All implementation and test tasks are complete. This confirms formatting, a warning-free build, and a green suite across every touched subsystem (engine, gates, setup, registration, wizard, migration).
  - **Steps:**
    1. Run `mix format --check-formatted`; expect exit 0 with no output.
    2. Run `mix compile --warnings-as-errors`; expect exit 0.
    3. Run `mix test`; expect output ending with `0 failures`.
  - **Code:** None — no file changes.
  - **Troubleshooting:**
    - A failure in `test/cympho/adapters/registry_extended_test.exs` ("resolves agent without config key using empty config" expecting `{:error, :no_adapter}` but getting `{:ok, Cympho.Adapters.ClaudeCodeAdapter, %{}}`) is **pre-existing and environment-dependent**, not caused by this spec: on machines where a Claude-compatible wrapper is configured (e.g. via `$HOME/.cld` / `CYMPHO_CLAUDE_COMMAND`), the fallback chain resolves an adapter the test expects to be unavailable. Verify it also fails on the unmodified base commit (`git stash && mix test test/cympho/adapters/registry_extended_test.exs && git stash pop`); if so, it does not block this task.
    - Any other failure belongs to an earlier task; follow Execution Protocol rule 8 against that task.
  - **Done when:** all three commands succeed in order (modulo the documented pre-existing environment-dependent failure above, if it reproduces on the base commit).
  - **Verify:** `mix test` — output ends with `0 failures`.

---

## Short Summary

A fresh Cympho deploy currently greets its operator with a login form no one can pass and lets signed-in users create data that belongs to no company. This spec adds a first-run path: when zero users exist, the app routes to a `/setup` page that creates the owner account (with email normalization and a race-safe advisory lock), then a six-step onboarding wizard (welcome, blueprint, company, team, review, done) launches their autonomous company. The wizard always creates a CEO and CTO, and asks how many engineering agents to hire, what to name them, and which adapter, command, and model run them — the launch creates the company, the owner's membership, all agents, a goal, a project, and seed issues in one transaction, with server-side validation (name, goal, prefix, adapter whitelist) and a rescue that turns engine failures into an error banner instead of a crash. Users with no company membership are gated into the wizard everywhere, public API registration becomes invite-only, and projects are hardened so they can never again be created without a company: the changeset requires `company_id` immediately (with the ~26 existing test fixtures updated to match), and the existing orphan project is adopted by a follow-up migration on the second deploy. Browser-based invite flows, per-engineer budgets/API keys, wizard state persistence across refreshes, and password reset are out of scope.

---

## Execution Protocol

Instructions for the implementing agent. This spec is the single source of truth.

1. **Reading order.** Read the metadata header, this Execution Protocol, the Build & Verification Commands tables, and the File Manifest. Then read ONLY the current task block. All other sections are reference material — consult them only when the current task block names them.
2. Set `status: in-progress` in the metadata header before starting the first task.
3. Work through tasks strictly in the listed order. Never start a task whose `Depends:` entry is not yet checked off.
4. **Transcribe, do not author.** For a Form A ("complete contents") Code block, write the file exactly as given, first line to last. For a Form B (`SEARCH/REPLACE`) block, locate the SEARCH text in the named file — it must occur exactly once — and replace it with the REPLACE text, preserving all whitespace. Never retype from memory, never reformat, never rename, never "improve".
5. Never create, modify, or delete any file that is not listed in the current task's `Paths:`.
6. If a SEARCH block matches zero times or more than once, or a file, path, or symbol named by the task does not exist: stop the task, record the details under `## Blockers`, and halt. Do not guess or approximate.
7. After completing each task: run its `Verify:` command. The task passes only if the exit code is 0 AND the output contains the expected text. Then tick the task's checkbox, append a line to `## Implementation Log` in the format `- YYYY-MM-DD — TASK-NNN — <verify command> → <first line of output>`, and update `last_updated` in the metadata header.
8. If a `Verify:` command fails, fix the current task's work only (check the task's `Troubleshooting:` entry first) and re-run. If it fails a second time, do not improvise a workaround: record the task ID, the command, and the full error output under `## Blockers`, leave the checkbox unticked, and stop.
9. If any instruction in a task is impossible to follow or contradicts another instruction, record it under `## Blockers` and stop — do not guess.
10. **Resuming.** In a fresh session, read the task checkboxes and the `## Implementation Log`, then continue from the first unchecked task whose dependencies are all checked.
11. When every task is checked off and verified, run the final verification tasks, then set `status: complete`.

---

## Blockers

None

---

## Implementation Log

<!-- One line per completed task, appended by the implementing agent: -->
<!-- - YYYY-MM-DD — TASK-NNN — <verify command> → <first line of output> -->

---

## Traceability Matrix

| REQ-ID  | AC-IDs                                                 | DES-IDs                    | TASK-IDs                                | TEST-IDs           |
| ------- | ------------------------------------------------------ | -------------------------- | --------------------------------------- | ------------------ |
| REQ-001 | AC-001, AC-002, AC-003, AC-004, AC-005, AC-029, AC-030 | DES-003, DES-004           | TASK-014, TASK-015, TASK-016            | TEST-004           |
| REQ-002 | AC-006, AC-007                                         | DES-003                    | TASK-015, TASK-016, TASK-017            | TEST-004, TEST-007 |
| REQ-003 | AC-008, AC-009, AC-010, AC-011                         | DES-002, DES-010           | TASK-010, TASK-011, TASK-012, TASK-013  | TEST-003, TEST-007 |
| REQ-004 | AC-012, AC-013                                         | DES-005                    | TASK-018, TASK-019                      | TEST-005           |
| REQ-005 | AC-014, AC-015, AC-016, AC-017                         | DES-006                    | TASK-020, TASK-021                      | TEST-006           |
| REQ-006 | AC-018, AC-019, AC-020, AC-021                         | DES-001, DES-006, DES-007  | TASK-001, TASK-002, TASK-020, TASK-021  | TEST-001, TEST-006 |
| REQ-007 | AC-022, AC-023, AC-024, AC-025, AC-033, AC-034         | DES-001, DES-007, DES-008  | TASK-001, TASK-002, TASK-003, TASK-020, TASK-021 | TEST-001, TEST-006, TEST-007 |
| REQ-008 | AC-026, AC-027, AC-028                                 | DES-009                    | TASK-004, TASK-005, TASK-006, TASK-007, TASK-008, TASK-009, TASK-022 | TEST-002, TEST-007 |
