# Cympho Ego Lite smoke-test guide

This is the exhaustive browser smoke-test runbook for Cympho. It is written for a low-cost agent that follows literal instructions better than it reasons about intent.

The guide covers:

- every browser page declared in `lib/cympho_web/router.ex`;
- public authentication, first-run setup, company switching, and sign-out;
- all 75 Cympho LiveView route shapes;
- Simple and Advanced interface modes;
- desktop and mobile layouts;
- detail-page, empty-state, permission, and tenant-boundary behavior;
- whole-product workflows;
- every browser-native generation/export surface;
- one report row for every check and one final consolidated report.

In this document, **report generation** has two meanings. Both are required:

1. Generate smoke-test evidence and a Markdown result for every page.
2. Test Cympho's browser-generated artifacts: company JSON, tool-trace JSON/CSV, org-chart SVG, and the in-page generated prompt.

JSON APIs are not pages and are not exhaustively opened as browser pages. They are tested only when a UI flow depends on them, such as runtime previews and downloads. WebSocket endpoints and static assets are supporting resources, not pages.

## 1. Non-negotiable rules

1. Use **Ego Lite only** for browser work. Use `ego-browser nodejs` and the helpers described below. Do not substitute Playwright, Selenium, Safari, Chrome automation, `curl`, or a text-only HTTP fetch for a browser result.
2. Create one Ego Lite task space for the run. Reuse its numeric ID for every browser command.
3. After every navigation or meaningful interaction, observe the new state before claiming success.
4. Use `snapshotText()` for semantic checks and `captureScreenshot(path)` for visual evidence. A screenshot alone is not proof that a control works.
5. Never mark a page `PASS` merely because it returned HTML. Verify the final URL, title or heading, expected content or explicit empty state, LiveView connection, browser errors, and layout.
6. Never convert missing data, missing permission, or an unavailable optional service into a pass. Use `SKIP` or `BLOCKED` as defined below.
7. Run against a confirmed local or isolated environment. Do not enable autonomous dispatch for an ordinary UI smoke. Keep all `CYMPHO_START_*` flags, `CYMPHO_SCHEDULE_ROUTINE_TRIGGERS`, and `CYMPHO_ORCHESTRATOR_ENABLED` unset. Server startup can still repair stale runtime rows, restore enabled local-catalog plugins, and assign visible unassigned backlog issues after five minutes, so “read-only” in this guide describes browser actions, not a guarantee that the application performs no writes.
8. Do not click controls that run agents, contact providers, spend money, rotate credentials, import data, stop work, or delete pre-existing data unless the run is explicitly authorized for those side effects.
9. Never enter, print, copy into a report, or screenshot a real secret, API key, access token, password, prompt body containing secrets, or private repository URL.
10. Use existing rows read-only. Every tester-controlled name or title created by the smoke must start with the exact run prefix `EGSMOKE-<UTC run ID>`. Onboarding also creates fixed-name descendants such as `CEO`, `CTO`, and starter issues; record every generated UUID under the smoke company UUID instead of expecting those names to carry the prefix.
11. Maintain an ID-based creation ledger. Never delete Cympho Labs, any pre-existing row, or any UUID absent from the current run's ledger. Never decide ownership from a visible name alone, and never run `mix ecto.reset` as part of this guide.
12. Finish by restoring Simple mode and closing the Ego Lite task space. Closing the task space is required even after failures.
13. Treat screenshots, snapshots, downloads, and reports as potentially sensitive. Use private artifact permissions, collect only necessary evidence, redact secrets and private content, and record a retention or deletion decision at the end.

## 2. Result vocabulary

Use exactly one of these results for every planned check:

| Result | Meaning |
|---|---|
| `PASS` | The check ran, the expected state was observed, and its required evidence exists. |
| `FAIL` | The check ran and produced a reproducible wrong result, browser error, broken artifact, wrong redirect, unusable control, or layout defect. |
| `SKIP` | The page or state is optional in this environment and its named prerequisite is absent, such as no board-approval fixture. Record the exact missing prerequisite. |
| `BLOCKED` | The check could not run because Ego Lite, the server, authentication, the database, or another required dependency was unavailable. |

Rules:

- An explicit, correct empty state can `PASS` the list page.
- The corresponding detail route is `SKIP` when no valid fixture exists.
- A 404 on a dev-only page in production is `SKIP` with reason `dev-only route not compiled`.
- A board-only redirect for a known non-board fixture can `PASS` the authorization check. It does not pass the board page's content check.
- A release-level run passes only when there are zero `FAIL` and zero `BLOCKED` results. Every `SKIP` must have an accepted reason.

## 3. Safe local setup

### 3.1 Start the application

Run from the repository root only after confirming this is a disposable/local database. `mix setup` creates or migrates the database. Run the server in its own terminal or managed process because `mix phx.server` stays in the foreground:

```bash
mix setup
mix assets.build
mix phx.server
```

Development serves at `http://localhost:4329`. Keep the exact server terminal or PID so only that process is stopped during cleanup; never use a broad `pkill`. It starts in review mode. Do not add autonomous-runtime environment flags. Even in review mode, boot recovery can update orphaned runs, stale checkouts, or in-progress issues. Startup also restores every tenant's enabled local-catalog plugin worker and can rewrite a plugin's status/error metadata if restoration succeeds or fails. In addition, `Cympho.Issues.AutoAssignmentReassigner` always starts: every five minutes it scans up to five companies with visible unassigned backlog issues and can assign/queue that work; an idle-heartbeat event can trigger the same operation sooner. The runtime flags above do not disable plugin restoration or this reassigner. Use an isolated database, or first prove there are no enabled local-catalog plugins, no such pre-existing issues, and no heartbeats that can arrive. Do not start a full smoke on an unapproved shared database.

Do not begin route checks until the server terminal reports that the endpoint is running and the first Ego Lite navigation in section 4 reaches a real Cympho page. If the port bind fails, the page is a browser error page, or startup exits, record `BLOCKED` and stop; do not keep retrying against an unknown process.

On a database with zero companies, the seed creates Cympho Labs with a project, goal, CEO, CTO, product lead, design lead, three engineers, five starter issues, and a blocking monthly budget policy. If any company already exists, the seed skips all of that work. Inventory the current UI and make detail checks fixture-dependent; never assume the fresh-seed counts on an existing database. The seed does not create a user.

The development login shortcut creates or reuses this local owner:

```text
Email: owner@cympho.local
Password: password1234
Shortcut: http://localhost:4329/dev/login
```

The password is guaranteed only when the shortcut creates the account. If that email already exists, the shortcut reuses the account without resetting its password. Prefer the shortcut itself over typing the documented password.

The shortcut is an authentication-bootstrap mutation: it can create the user, create or promote membership to owner plus board, and rewrite the user's persistent default company to the oldest company. Use it only on a confirmed local/isolated database, record those side effects, and verify which company was selected. It exists only in development and test builds. On staging or production, use a supplied test account through `/login`; never invoke or expect `/dev/login`.

### 3.2 Create the artifact directory

Set a UTC run ID once and keep it unchanged:

```bash
export CYMPHO_EG_BASE_URL="http://localhost:4329"
export CYMPHO_EG_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
export CYMPHO_EG_ISSUE_PREFIX="EG$(date -u +%d%H%M%S)"
export CYMPHO_EG_ARTIFACT_ROOT="/tmp/cympho-eg-smoke/$CYMPHO_EG_RUN_ID"
umask 077
mkdir -p "$CYMPHO_EG_ARTIFACT_ROOT/screens" "$CYMPHO_EG_ARTIFACT_ROOT/downloads" "$CYMPHO_EG_ARTIFACT_ROOT/pages" "$CYMPHO_EG_ARTIFACT_ROOT/findings"
```

`CYMPHO_EG_ISSUE_PREFIX` is exactly ten uppercase alphanumeric characters and satisfies the company schema. Do not use the full `EGSMOKE-...` label as an issue prefix; hyphens are forbidden and prefixes are limited to 2–10 characters.

Required final files:

```text
/tmp/cympho-eg-smoke/<run ID>/run-report.md
/tmp/cympho-eg-smoke/<run ID>/route-results.tsv
/tmp/cympho-eg-smoke/<run ID>/side-effects.md
/tmp/cympho-eg-smoke/<run ID>/screens/
/tmp/cympho-eg-smoke/<run ID>/downloads/
/tmp/cympho-eg-smoke/<run ID>/pages/
/tmp/cympho-eg-smoke/<run ID>/findings/
```

Use the agent's normal file-editing tool to create and update those files. Do not put credentials in them. The artifact root is outside the repository so normal smoke evidence does not dirty the worktree.

At the start, record who may read the artifact directory and how long it may remain. At the end, either move the sanitized evidence to the approved retention location or remove only the exact current-run directory after operator approval. Do not leave raw company exports or prompt-bearing evidence in `/tmp` indefinitely.

### 3.3 Confirm the route manifest

Before browsing, run:

```bash
mix phx.routes
```

Compare the browser `GET` routes with the catalog in section 8. If the router contains a page not listed here, add an `UNMAPPED-<number>` row to the run report and mark it `FAIL: guide route manifest is stale`. Do not silently ignore new routes.

## 4. Start and reuse Ego Lite

On a confirmed local development database, create the task space and use the development shortcut below. Record the shortcut's bootstrap mutations from section 3.1. On any other environment, replace `/dev/login` with `/login` and use the supplied smoke account without logging its credentials.

```bash
ego-browser nodejs <<'EOF'
const runId = process.env.CYMPHO_EG_RUN_ID
const baseUrl = process.env.CYMPHO_EG_BASE_URL
const task = await useOrCreateTaskSpace(`cympho full smoke ${runId}`)
cliLog(`CYMPHO_EG_TASK_ID=${task.id}`)
await openOrReuseTab(`${baseUrl}/dev/login`, {wait: true, timeout: 30})
await waitForNetworkIdle({timeout: 15}).catch(() => null)
cliLog(JSON.stringify(await pageInfo()))
cliLog((await snapshotText()).slice(0, 12000))
EOF
```

Copy the printed number into an environment variable:

```bash
export CYMPHO_EG_TASK_ID="REPLACE_WITH_PRINTED_NUMERIC_ID"
```

Every later Ego Lite heredoc must begin with:

```javascript
const taskId = Number(process.env.CYMPHO_EG_TASK_ID)
await useOrCreateTaskSpace(taskId)
```

Do not create a second task space for the same run.

## 5. The mechanical page-check loop

Run the following sequence for every route and state in section 8.

### Step 1: set the viewport and interface mode

The full run requires these four render variants for every Cympho LiveView page:

| Variant | Viewport | Interface mode |
|---|---:|---|
| `desktop-simple` | 1440 x 900 | Simple |
| `desktop-advanced` | 1440 x 900 | Advanced |
| `mobile-simple` | 390 x 844 | Simple |
| `mobile-advanced` | 390 x 844 | Advanced |

Auth/setup pages do not use the Cympho shell, so test them at desktop and mobile once each. Operator dashboard pages do not use Cympho's Simple/Advanced modes, so test each available operator page at desktop and mobile once each.

Use CDP for a deterministic viewport and local storage for deterministic mode. Replace `MODE` with `simple` or `advanced`, and set the dimensions for the planned variant:

```bash
ego-browser nodejs <<'EOF'
const taskId = Number(process.env.CYMPHO_EG_TASK_ID)
await useOrCreateTaskSpace(taskId)
await cdp('Emulation.setDeviceMetricsOverride', {
  width: 1440,
  height: 900,
  deviceScaleFactor: 1,
  mobile: false,
  screenWidth: 1440,
  screenHeight: 900
})
await js(String.raw`localStorage.setItem('cympho-ui-mode', 'simple')`)
cliLog(JSON.stringify(await pageInfo()))
EOF
```

For mobile use `width: 390`, `height: 844`, `screenWidth: 390`, `screenHeight: 844`, and `mobile: true`.

Use the visible mode toggle at least once in the global-shell test. Local-storage setup is allowed for the repetitive route matrix only after the visible toggle has worked.

### Step 2: navigate, inspect, and capture evidence

Set three variables for each check before running the snippet:

```bash
export CYMPHO_EG_CHECK_ID="LV05-desktop-simple"
export CYMPHO_EG_ROUTE="/issues"
export CYMPHO_EG_EXPECTED_HEADING="All Issues"
```

Then run:

```bash
ego-browser nodejs <<'EOF'
const taskId = Number(process.env.CYMPHO_EG_TASK_ID)
const baseUrl = process.env.CYMPHO_EG_BASE_URL
const artifactRoot = process.env.CYMPHO_EG_ARTIFACT_ROOT
const checkId = process.env.CYMPHO_EG_CHECK_ID
const route = process.env.CYMPHO_EG_ROUTE
const expectedHeading = process.env.CYMPHO_EG_EXPECTED_HEADING

await useOrCreateTaskSpace(taskId)
await cdp('Runtime.enable')
await cdp('Log.enable')
await cdp('Network.enable')
await drainEvents()

let navigationError = null
try {
  await gotoAndWait(`${baseUrl}${route}`, {timeout: 30, settle: 0.5})
  await waitForNetworkIdle({timeout: 10}).catch(() => null)
} catch (error) {
  navigationError = String(error)
}

const info = await pageInfo()
if (info.dialog) {
  cliLog(JSON.stringify({checkId, route, navigationError, dialog: info.dialog}))
} else {
  const semantic = await snapshotText()
  const dom = await js(String.raw`(() => {
    const visible = element => Boolean(element && element.getClientRects().length)
    const headings = [...document.querySelectorAll('h1')]
      .filter(visible)
      .map(element => element.innerText.trim())
      .filter(Boolean)
    const visibleErrors = [...document.querySelectorAll(
      '[role="alert"], .alert-danger, [data-kind="error"], .phx-error, .phx-disconnected'
    )]
      .filter(visible)
      .map(element => element.innerText.trim())
      .filter(Boolean)
    const brokenImages = [...document.images]
      .filter(image => image.complete && image.naturalWidth === 0)
      .map(image => image.currentSrc || image.src || image.alt)
    const unlabeledButtons = [...document.querySelectorAll('button')]
      .filter(visible)
      .filter(button => !(
        button.innerText.trim() ||
        button.getAttribute('aria-label') ||
        button.getAttribute('title')
      ))
      .length

    return {
      readyState: document.readyState,
      title: document.title,
      headings,
      expectedHeadingPresent: headings.some(text => text.includes(${JSON.stringify(expectedHeading)})),
      liveViewMainPresent: Boolean(document.querySelector('[data-phx-main]')),
      liveViewDisconnected: Boolean(document.querySelector('.phx-disconnected')),
      visibleErrors,
      brokenImages,
      unlabeledButtons,
      documentWidth: document.documentElement.scrollWidth,
      viewportWidth: document.documentElement.clientWidth,
      horizontalOverflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
      uiMode: document.documentElement.dataset.uiMode || null
    }
  })()`)
  const events = await drainEvents()
  const browserErrors = events.filter(event => {
    const method = String(event.method || event.type || '')
    const body = JSON.stringify(event)
    return method === 'Runtime.exceptionThrown' ||
      method === 'Network.loadingFailed' ||
      (method === 'Runtime.consoleAPICalled' && /"type":"error"/.test(body)) ||
      (method === 'Log.entryAdded' && /"level":"error"/.test(body)) ||
      (method === 'Network.responseReceived' && /"status":5\d\d/.test(body))
  })
  const screenshot = await captureScreenshot(`${artifactRoot}/screens/${checkId}.png`)
  cliLog(JSON.stringify({
    checkId,
    requestedRoute: route,
    navigationError,
    pageInfo: info,
    dom,
    browserErrorCount: browserErrors.length,
    browserErrors: browserErrors.slice(0, 20),
    screenshot,
    semanticPreview: semantic.slice(0, 4000)
  }))
}
EOF
```

The snippet is a baseline, not the whole assertion. Compare its output with the route-specific expectation in section 8.

Do **not** run the baseline unchanged when it could collect private content. Use sanitized DOM assertions and withhold the screenshot when redaction cannot be proved. This applies at minimum to:

- secret metadata/version drawers and one-time integration credentials;
- agent instruction files, private repository URLs, issue bodies/comments, audit payloads, and tool-trace payload drawers;
- generated company/tool-trace download links, whose `data:` URL can contain the complete artifact;
- Prompt Inspector after a prompt has been generated.

Close sensitive drawers before evidence capture. Inspect only counts, redaction markers, headings, button labels, and pass/fail signals with a targeted `js()` expression. Write `withheld: sensitive content` in the screenshot field when no safe screenshot exists. Never weaken redaction merely to satisfy the evidence template.

### Step 3: perform the route-specific safe interaction

Use selectors from the latest `snapshotText()` output. Prefer stable `loc=` values, accessible labels, `data-testid`, or explicit CSS selectors. `@N` references are valid only for the latest snapshot.

For each interaction:

1. Observe.
2. Act once.
3. Observe again.
4. Verify the exact new state.
5. Capture the post-action screenshot.
6. Record any data created or changed.

Never continue a scripted click sequence after the page differs from the expected state.

### Step 4: inspect the whole page

`snapshotText()` covers the full semantic page, but screenshots normally cover the viewport. For a page taller than the viewport:

1. Capture the top.
2. Scroll through each major section.
3. Capture the bottom.
4. Return to the top before the next route.

Visually reject:

- overlapping controls or text;
- clipped dialogs, menus, dropdowns, tables, or sticky actions;
- content hidden behind the mobile navigation;
- unreadable text or missing contrast;
- unintended horizontal page scrolling;
- empty white/black regions where content should render;
- controls that move outside the viewport when focused.

### Step 5: write the page result immediately

Do not wait until the end of the run. Create one page file under `pages/` using the template in section 12. Then append one summary row to `route-results.tsv`.

## 6. Fixtures and mutation levels

### 6.1 Read-only run

The default run is read-only. Use existing rows discovered from index pages. Do not hardcode UUIDs from this document or from an earlier run. “Read-only” means no deliberate business mutation. A few pages mutate personal/runtime state merely by opening; disclose them before the run:

- `/issues/:id` ensures an issue-read-state row for the signed-in user;
- `/settings/adapters` and `/settings/adapters/:key` automatically run health checks and may contact configured providers;
- `/agents/remote` can contact Agrenting on mount;
- `/settings/adapters/process` can execute an assigned agent's configured local command with `--health-check` on mount;
- a Claude Code agent detail can run a shell command and source the local `$HOME/.cld` while calculating readiness;
- `/dev/login` can bootstrap/promote the owner and rewrite the persistent default company;
- server boot can repair stale runtime rows and restore enabled local-catalog plugin workers, updating plugin status/error metadata;
- the always-on auto-assignment reassigner can assign/queue visible unassigned backlog issues on an idle-heartbeat event or its five-minute sweep.

Use a disposable user where possible, ledger these automatic effects, and obtain network authority before opening auto-fetch pages. Do not advance onboarding, change appearance, or submit a nonblank search on a pre-existing user.

Discover valid detail URLs with browser state:

```bash
ego-browser nodejs <<'EOF'
const taskId = Number(process.env.CYMPHO_EG_TASK_ID)
await useOrCreateTaskSpace(taskId)
const links = await js(String.raw`(() => [...document.querySelectorAll('a[href]')]
  .map(anchor => anchor.getAttribute('href'))
  .filter(Boolean)
  .filter(href => /^\/(issues|projects|goals|agents|routines|approvals|board-approvals|budgets|skills|plugins|workspaces)\//.test(href)))()`)
cliLog(JSON.stringify([...new Set(links)]))
EOF
```

Record the chosen same-company link in `side-effects.md` as a read-only fixture. If no link exists, pass the correct empty-state check and skip the detail route with the missing fixture named.

### 6.2 Disposable mutation run

Run mutation workflows only when all of these are true:

- the target is a confirmed local or isolated staging instance;
- the operator explicitly authorized data creation;
- autonomous dispatch remains disabled unless the runtime flow itself is authorized;
- every tester-controlled name or title begins with `EGSMOKE-<run ID>`;
- every created URL or UUID is recorded immediately;
- the agent understands that company cleanup may be blocked by non-cascading foreign keys.

The safest broad fixture is a dedicated company created through `/onboarding` with a name such as `EGSMOKE-20260819T081500Z`. Use `$CYMPHO_EG_ISSUE_PREFIX` for its issue prefix. That path creates membership, board access, a project, a goal, a team, starter issues, and a hard-stop budget policy. Its generated agents and starter issues have fixed names, so add every returned/generated UUID to the ledger under the smoke company UUID.

Delete only UUIDs in the current-run ledger, in reverse creation order, when the UI exposes a safe delete. Switch back to the original company before attempting to remove the smoke company. If cleanup is not possible, leave the named fixture in place and record it. Do not improvise direct database deletion.

Creating an issue can also create activity, assignment, wake, notification, heartbeat, and dispatch-related state because auto-ignite defaults on. Keep runtime dispatch disabled, create only inside the disposable company, and add all resulting IDs/states to the ledger. A successful issue deletion does not prove those related rows were removed.

Onboarding changes the user's persistent default company; `/switch-company/:id` changes only the current session. For the local dev owner, finish cleanup with `/dev/login?return_to=/dashboard`, which resets the persistent default to the oldest baseline company, then sign out/in once and verify the baseline company. For any other user, use an approved restoration path or record the persistent-default residue as `BLOCKED`.

### 6.3 Side-effecting controls

Unless the disposable workflow explicitly calls for them, do not activate:

- Low power, Pause, Stop, Resume, release, relaunch, prioritize, or recovery controls;
- agent heartbeat, session kill, pause, termination, runtime presets, configuration save, or provider tests;
- approval, review, owner-verification, or board-vote decisions;
- manual routine runs or trigger rotation;
- secret creation, editing, rotation, deletion, or one-time key generation;
- adapter, proxy, webhook, Telegram, Agrenting, or marketplace tests;
- workspace creation/deletion, prompt writes, service controls, leases, or filesystem operations;
- company import;
- onboarding path selection, Back/Next, or form edits on a pre-existing user, because these persist an onboarding draft;
- appearance changes or nonblank searches on a pre-existing user, because they persist theme or recent-search rows;
- destructive delete/archive controls on pre-existing rows.

If one of these confirmations appears unexpectedly, cancel it and record the attempted control:

```text
Stop your agents and clear the queue?
Delete this issue?
Delete this agent?
Terminate this agent? This will stop any running sessions.
Delete this local workspace directory?
Delete this company workspace from the fleet and cannot be undone?
Return this work for changes? The assignee will be cleared and the issue sent back to To Do.
Accept this CEO owner update and close the issue?
Request a CEO revision, reopen this issue to To Do, and queue focused dispatch?
Rollback this revision? This will create a new revision with the content from that revision.
```

The exact company-workspace confirmation can include the workspace name. Treat any confirmation that says the action cannot be undone as destructive.

## 7. Global shell and cross-page checks

Run these once at desktop and once at 390 x 844 before the route catalog:

Write separate result rows named `SHELL01-desktop`, `SHELL02-mobile`, `A11Y01-desktop`, `A11Y02-mobile`, `LIVE01-desktop`, and `LIVE02-mobile`. A later route failure does not replace these global checks.

### Shell check

- Simple mode is the default for a new local-storage state.
- The visible Simple/Advanced control changes `document.documentElement.dataset.uiMode` and its pressed state.
- Simple mode exposes Home, Board, Inbox, Projects, Team, and Settings.
- Advanced mode additionally exposes Approvals, Reviews, Operations, Issues, Launch Tracker, Goals, Routines, project shortcuts, and the user-menu entries Org chart, Costs, Activity, Workspaces, Plugins, Skills, and Tool traces.
- The user menu opens, closes on Escape, and returns focus to its trigger.
- Search/command palette opens and closes without navigating unexpectedly.
- Desktop sidebar collapse/expand works. Its width can be resized without hiding content.
- Mobile navigation contains Home, Board, New, Inbox, and Team.
- Mobile drawer opens and closes without document-level horizontal overflow.
- The global quick-create modal opens from the New issue control and closes without submitting.
- Runtime controls are visible only to an authorized manager. Do not submit them in the read-only run.
- Inbox and approval badges, when present, are non-negative integers and do not cover their labels.

### Shared accessibility check

- `Skip to main content` focuses or navigates to `#main-content`.
- Every visible icon-only button has an accessible name.
- Tab reaches all visible controls in a logical order.
- Focus is visible.
- Escape closes open menu/dialog surfaces.
- A form error is associated with the failing field and is not conveyed only by color.

### Shared LiveView check

- `[data-phx-main]` exists on Cympho LiveViews.
- `.phx-disconnected` is not visible after settling.
- A LiveView link changes the URL and main content without leaving a permanent loading bar.
- Browser back returns to the previous page and preserves a reasonable filter/query state.

## 8. Exhaustive page catalog

Every `LV` row is a distinct LiveView route declared by the router. Execute all four render variants from section 5. The safe interaction is the minimum interaction for that page. More detailed workflow actions appear in section 9.

### 8.1 Authentication and onboarding

| ID | Route | Page and required state | Minimum safe interaction |
|---|---|---|---|
| `AUTH01` | `/login` | Standalone **Sign in to Cympho** form. On an established database, fields Email and Password and a Sign in button are present. On a database with zero users it redirects to `/setup`. | Submit an incorrect password and verify `Invalid email or password`; then use the development owner or `/dev/login`. Do not record the password. |
| `AUTH02` | `/setup` | One-time **Create your owner account** page with Name, Email, and Password of at least eight characters. On an established database it must redirect to `/login`. | On the normal seeded run, verify the redirect only. Run first-owner creation only against a separately confirmed empty disposable database. |
| `AUTH03` | `/dev/login?return_to=/dashboard` | Development/test controller action, not a content page. It signs in the local owner, flashes `Signed in as local owner`, and follows the safe return path. It can create/promote membership and rewrite the persistent default company. | Local/isolated mutation run only: record bootstrap effects and verify final URL `/dashboard` plus the selected company. A production 404 is expected because the shortcut is not compiled there. |
| `LV01` | `/onboarding` | Resumable **Get Started** wizard. Existing-company users can choose **Start a company** or **Improve this company**. Company-less users cannot skip. | Read-only: inspect the currently restored step without clicking or editing, because path, field, Back, and Next actions persist a user draft. Test draft resume once with a disposable user in mutation mode. |

### 8.2 Operating and issue pages

| ID | Route | Page and required state | Minimum safe interaction |
|---|---|---|---|
| `LV02` | `/` | Dashboard home alias. Shows current company operating posture, needs-attention actions, health/readiness, activity, inbox, active agents, stuck work, throughput, and routine health as data permits. | Open one read-only dashboard link and return. Do not change runtime or owner verification. |
| `LV03` | `/dashboard` | Same dashboard content as `/`; title is **Dashboard** and main heading is the current home heading such as **Today**. | Compare key counts and company label with `/`. |
| `LV04` | `/operations` | Operations control room: runtime status, dispatch focus, stale work, wakes, owner signoffs, delegation, review nudges, prompt drift, services, staffing, and adapter readiness. | Toggle Compact/Detailed density and inspect a diagnostic link. Do not run recovery, queue, prompt repair, or smoke-issue actions. |
| `LV05` | `/issues` | **All Issues** inventory with status, priority, assignee, project, label, triage, search, density, and pagination controls. A correct empty state is acceptable. | Apply one filter or search, verify the result/query, clear it, and open a same-company issue when available. |
| `LV06` | `/issues/new` | **New issue** intake with title, details, work mode, status, priority, optional project/goal, structured scaffold, and authorized swarm controls. The intake auto-routes ownership; it has no assignee field. | Trigger validation without creating a row, exercise the launch scaffold, and cancel/close. Mobile sticky actions must clear bottom navigation. |
| `LV07` | `/issues/:id` | Same-company issue command/thread: title and identifier, status/priority/assignee, description, comments/timeline, runs, interactions, work products, children, documents, traces, workspace, and review gates as applicable. Opening it ensures a personal issue-read-state row. Missing/foreign ID redirects `/issues`. | With a disposable user or accepted personal-state mutation, record the read-state effect; then expand/read sanitized panels, switch timeline filter, and follow one related link. Skip edits, comments, proof, PR, runtime, nudge, review, and delete actions in read-only mode. |
| `LV08` | `/launch-items` | **Launch Tracker** readiness summary, create form, and launch items or explicit empty state. | Inspect the form and lanes. Do not create an item or change owner/status/blocked state in read-only mode. |
| `LV09` | `/my-issues` | **My Issues** personal views and tab navigation, with issue rows or explicit empty state. | Switch every visible tab and open one issue when available. |
| `LV10` | `/reviews` | **Review queue** with awaiting-review, kicked-back, and CTO-spec lanes or the correct clear state. | Open a linked issue. Do not approve, approve spec, or request changes. |
| `LV11` | `/inbox` | **Inbox** owner-attention queue with agent selector, status groups, Compact/Detailed density, and explicit empty states. | Switch density, agent, and a read-only filter. Do not mark, dismiss, archive, restore, answer, resolve, or decide. |
| `LV12` | `/activity` | Read-only **Activity Feed** company record with action/actor filters and pagination or a correct empty state. | Apply and clear one filter; open a linked issue if present. |
| `LV21` | `/kanban` | **Board** with status columns, project and density filters, collapsible columns, optional swimlanes, cards, and comment modal. | Filter, collapse/reopen one column, open/close comment UI, and open a card. Do not drag, transition, or submit a comment. |
| `LV22` | `/labels` | **Labels** create/edit surface and label inventory or **No labels yet**. | Inspect create/edit UI and cancel. Do not submit or delete in read-only mode. |

### 8.3 Project and goal pages

| ID | Route | Page and required state | Minimum safe interaction |
|---|---|---|---|
| `LV13` | `/projects` | **Projects** portfolio, health/count summaries, pagination, and project rows or explicit empty state. | Open a project and its filtered issue link. Do not archive. |
| `LV14` | `/projects/new` | **New project** form for name, description, prefix, repository URL, status, and color. | Trigger validation and cancel. Submit only in a disposable run. |
| `LV15` | `/projects/:id` | Project command center with identity, recent issues, goals, repository readiness, workspaces, settings, and encrypted environment-key names. Values must remain hidden. Missing/foreign ID redirects `/projects`. | Open related goal/issue/workspace links and return. Do not save identity or add/remove environment values. |
| `LV16` | `/projects/:id/edit` | Current behavior intentionally renders the same `ProjectLive.Show` action as `/projects/:id`; it is not a separate editor route. Missing/foreign ID redirects `/projects`. | Verify it loads the same project command content and record that current behavior. |
| `LV17` | `/goals` | **Goals** strategy/progress report, Compact/Detailed density, linked coverage, and floating-risk issues. | Switch density and open a goal. Do not link or delete. |
| `LV18` | `/goals/new` | **New goal** target form with title, success criteria, type, status, priority, dates, project, and parent as applicable. | Trigger validation and cancel. |
| `LV19` | `/goals/:id` | Same-company goal detail with status, priority, progress, linked issues, children, project, and evidence as applicable. Missing/foreign ID redirects `/goals`. | Open one related issue/project and return. |
| `LV20` | `/goals/:id/edit` | Prefilled goal settings form. Missing/foreign ID redirects `/goals`. | Verify existing values and cancel without saving. |

### 8.4 Approval and governance pages

| ID | Route | Page and required state | Minimum safe interaction |
|---|---|---|---|
| `LV23` | `/approvals` | Ordinary **Approvals** queue with all/pending/approved/denied/cancelled filters, payload summaries, and linked work. | Switch status filter and open a detail. Do not approve or deny. |
| `LV24` | `/approvals/:id` | Owner decision packet with type, status, payload, requester, linked issues, and decision controls when pending. Missing/foreign ID redirects `/approvals`. | Inspect and go Back. Do not decide. |
| `LV25` | `/board-approvals/:id` | Board risk brief with proposal payload, audit/vote history, and decision state. A company user may view; only a board member may cast approve/deny/abstain. Missing/foreign ID redirects `/`. | Compare controls for board and non-board fixtures when available. Do not vote in read-only mode. |

### 8.5 Agent and organization pages

| ID | Route | Page and required state | Minimum safe interaction |
|---|---|---|---|
| `LV26` | `/agents` | **Agents** roster, status/workload summaries, staffing gaps, and org links. | Open an agent and Org Chart. Do not pause, resume, kill, terminate, or delete. |
| `LV27` | `/agents/new` | **New Agent** form with identity, role/reporting line, adapter/runtime, profile, instruction, and credential-readiness fields. | Exercise validation and cancel. Mobile Hire/Cancel actions must clear bottom navigation. |
| `LV28` | `/agents/remote` | **Hire Remote Agent** Agrenting catalog or a clear disconnected-integration state linking to Settings. When Agrenting is configured, mount, search, and Refresh can all call the external service. | If external calls are unauthorized, test only a confirmed disconnected fixture or mark `SKIP`; otherwise authorize network access before opening and record the external call. Never hire in the read-only run. |
| `LV29` | `/agents/:id` | Agent detail tabs **Dashboard**, **Instructions**, **Skills**, **Configuration**, and **Runs**, including file/run selectors and safe previews. Rendering readiness for a Claude Code agent can run Bash and source local `$HOME/.cld`. Missing/foreign ID redirects `/agents`. | Use a non-Claude fixture or first obtain authorization and verify `.cld` plus the configured command are safe to source/check; otherwise `SKIP` the affected detail. Then open tabs/read sanitized files/runs only. Do not heartbeat, mutate config/instructions/skills, restore, test, pause, or resume. |
| `LV30` | `/org-chart` | **Org** reporting hierarchy, Org Health, selectable agent side panel, Company Stats, legend, or **No reporting lines yet**. | Select/close an agent and toggle Company Stats in each route variant. Run the one-time SVG generation check from section 10 separately. |

### 8.6 Routine pages

| ID | Route | Page and required state | Minimum safe interaction |
|---|---|---|---|
| `LV31` | `/routines` | **Routines** health/inventory, status, density, pagination, or explicit empty state. | Switch density and open a routine. Do not pause, resume, or archive. |
| `LV32` | `/routines/new` | **New Routine** form for name, issue brief, owner, project, and concurrency. | Trigger validation and cancel. |
| `LV33` | `/routines/:id` | Routine definition, triggers, and up to 50 run-history rows or explicit empty history. Missing/foreign ID redirects `/`. | Inspect triggers/history and open Edit. Do not create a trigger or run manually. |
| `LV34` | `/routines/:id/edit` | Prefilled routine editor. Missing/foreign ID redirects `/routines`. | Verify existing values and cancel. |

### 8.7 Settings pages

| ID | Route | Page and required state | Minimum safe interaction |
|---|---|---|---|
| `LV35` | `/settings/profile` | **Profile** settings for current user's name and email. | Trigger validation without saving. |
| `LV36` | `/settings/notifications` | **Notifications** channel/event preferences, Telegram link/verify, webhook URL/test controls. Mount can insert missing default preference rows for the user. | Use a disposable user or accept/ledger the default-preference auto-write. Inspect only; controls persist settings or contact external services. |
| `LV37` | `/settings/appearance` | **Appearance** theme choices. | Read-only: inspect choices and current pressed state. Mutation mode with a disposable user: record the original, change once, verify persistence, restore, and verify restoration. |
| `LV38` | `/settings/integrations` | **Integrations** MCP setup/tool registry and Agrenting state. | Inspect only. One-time MCP keys and Agrenting controls are side-effecting and may expose credentials. |
| `LV39` | `/settings/adapters` | **Adapters** catalog with assignments, configuration counts, readiness, and health. Mount automatically runs catalog health checks with empty per-agent config; HTTP/Agrenting normally short-circuit unconfigured, while OpenClaw can fall back to application environment and make a network request. | Open only when an environment-backed OpenClaw check is authorized or known absent/local; otherwise `SKIP: OpenClaw mount check unauthorized`. |
| `LV40` | `/settings/adapters/:key` | Adapter health/configuration, assigned agents, and required-secret guidance. Mount automatically checks that adapter and can contact a configured provider. For `process`, it can execute the first assigned agent's configured local command with its arguments plus `--health-check` in the configured working directory. Current built-ins are `claude_code`, `codex`, `cursor`, `http`, `openai_chat`, `openclaw`, `process`, and `agrenting`. Invalid key redirects to the adapter index. | Before navigation, authorize/audit every external endpoint and, for `process`, the exact executable, arguments, and working directory; otherwise `SKIP` that key. Inspect masked fields only. Do not save or send a test heartbeat. |
| `LV41` | `/settings/secrets` | **Secrets Management** profiles, scopes, redacted metadata, create/edit/version/rotate controls. | Open/close version history only if values remain redacted. Never enter, copy, reveal, log, or screenshot values. |
| `LV42` | `/settings/proxies` | **Proxy Profiles** list and create/edit/test controls. | Open and cancel the form. Do not save, test network access, or delete. |
| `LV43` | `/settings/policies` | **Execution Policies** inventory, governance posture, pagination, or empty-state guidance. | Open a policy when available. Do not delete. |
| `LV44` | `/settings/policies/new` | **New Execution Policy** builder with executor/reviewer/approver stages, actor separation, human/auto-advance flags, and advanced JSON. | Expand the JSON/config view, trigger validation, and cancel. |
| `LV45` | `/settings/policies/:id` | Policy detail and ordered stages. Missing/foreign ID redirects `/settings/policies`. | Inspect and open Edit. |
| `LV46` | `/settings/policies/:id/edit` | Prefilled policy builder. Missing/foreign ID redirects `/settings/policies`. | Expand advanced configuration and cancel. |
| `LV47` | `/settings/audit` | Read-only **Audit Trail** with event, actor, resource, and date filters, payload expansion, and pagination. | Apply/clear one filter and expand one payload when present. |

### 8.8 Company, cost, and budget pages

| ID | Route | Page and required state | Minimum safe interaction |
|---|---|---|---|
| `LV48` | `/companies` | **Companies** accessible-company fleet, blueprints, and onboarding/import entry points. | Open a company. Do not delete. |
| `LV49` | `/companies/new` | New-company form variant of the company index. | Open and cancel. Prefer onboarding for a complete disposable fixture. |
| `LV50` | `/costs` | Read-only **Cost Monitoring** spend/runway report with day windows, daily trend, and goal/agent/issue/model/provider breakdowns or explicit empty states. | Switch 7/30/90-day windows and follow a budget link. |
| `LV68` | `/budgets` | Board-only **Budgets** list, utilization, and policy posture or explicit empty state. | Open a budget when available. Do not delete because deletion also deactivates its finance policy. |
| `LV69` | `/budgets/new` | Board-only **New Budget** form with name, scope, period, amount, hard-stop/warn behavior, threshold, and optional window. | Inspect validation and cancel. |
| `LV70` | `/budgets/:id` | Board-only budget utilization, details, policy, and linked principals as applicable. Missing/foreign ID redirects `/budgets`. | Inspect and open Edit. |
| `LV71` | `/budgets/:id/edit` | Board-only prefilled budget editor. Missing/foreign ID redirects `/budgets`. | Verify values and cancel. |
| `LV72` | `/companies/:id/edit` | Board-only company settings action on the company detail page. Membership is rechecked; inaccessible ID redirects `/companies`. | Verify edit/settings context and cancel or navigate back. Do not save. |
| `LV73` | `/companies/:id/export` | Board-membership-required portability page with export inventory and secret-restore checklist. A non-board user, including admin-only, is redirected to `/` before mount. A board-authorized session that fails the target-company check redirects `/companies`. | Render only in the four-variant route matrix. Run the one-time company JSON generation check from section 10 separately. |
| `LV74` | `/companies/import` | Board-only upload → preview → slug strategy → import → result flow. Upload accepts one `.json` up to 50,000,000 bytes. | Upload a current-run export and validate preview only. Do not click Start Import outside a disposable mutation run. |
| `LV75` | `/companies/:id` | Company dossier with members, runtime/governance status, and portability links. Missing/inaccessible company redirects `/companies`. | Inspect links and members. Do not remove membership or pause/resume runtime. |

### 8.9 Skills and plugins

| ID | Route | Page and required state | Minimum safe interaction |
|---|---|---|---|
| `LV51` | `/skills` | **Skills** inventory/health, accessible-company filter, pagination, or explicit empty state. | Filter company and open a skill. Do not toggle/delete. |
| `LV52` | `/skills/new` | **New Skill** metadata, description, manifest, capabilities, and scope form. | Trigger validation and cancel. |
| `LV53` | `/skills/:id` | Skill manifest/capability/scope/health detail. Missing/foreign ID redirects `/skills`. | Inspect and open Edit. Do not toggle/delete. |
| `LV54` | `/skills/:id/edit` | Prefilled skill form. Missing/foreign ID redirects `/skills`. | Verify values and cancel. |
| `LV55` | `/plugins` | **Plugins** inventory/health with company/status filters, pagination, and manager-only mutations. | Filter and open a plugin. Do not toggle/delete. |
| `LV56` | `/plugins/new` | Plugin metadata, manifest, runtime, permissions, scope, and settings form. Manager-only save. | Trigger validation and cancel/back. |
| `LV57` | `/plugins/marketplace` | **Plugin Catalog** with local search and installed/installable states. | Search locally. Do not install/uninstall because it mutates registry/filesystem state. |
| `LV58` | `/plugins/:id` | Plugin detail, manifest, health, permissions, and status. Missing/foreign ID redirects `/plugins`. | Inspect and open Edit. Do not toggle/delete. |
| `LV59` | `/plugins/:id/edit` | Manager-only plugin metadata/manifest/runtime editor. Missing/foreign ID or insufficient mutation permission redirects `/plugins`. | Verify values and go Back without saving. |
| `LV60` | `/plugins/:id/settings` | Settings action variant of plugin detail with the selected plugin context. Missing/foreign ID redirects `/plugins`. | Verify heading/context and inspect settings without saving. |

### 8.10 Search, workspace, and diagnostic pages

| ID | Route | Page and required state | Minimum safe interaction |
|---|---|---|---|
| `LV61` | `/search` | Cross-domain **Search** for issues, agents, projects, and goals, with query, tabs, filters, and recent searches. | Read-only: inspect controls and any existing results without submitting a nonblank query. Mutation mode with a disposable user: search a current-run title, switch tabs/filter/open a result, and record the recent-search row. |
| `LV62` | `/workspace/:issue_id` | Same-company **Issue Workspace** repository state, prompt material, and local execution directory. Missing/foreign issue redirects `/issues`. | Inspect and return to issue. Do not create/delete workspace or write prompt files. |
| `LV63` | `/workspaces` | Read-only **Workspaces** project-workspace inventory/health or an empty state linking to project creation. | Open a project workspace. |
| `LV64` | `/workspaces/:id` | Project workspace with readiness, execution lanes, runtime services, and previews. Missing/foreign ID redirects `/workspaces`. | Open an execution lane or service preview link only under the preview rules in section 11. |
| `LV65` | `/workspaces/:id/exec/:exec_id` | Execution lane with services/previews, probes, leases, policies, and operation history. The implementation scopes and loads only `:exec_id`; the parent `:id` is currently ignored, so a mismatched parent segment still loads a same-company execution workspace. Missing/foreign `:exec_id` redirects `/workspaces`. | Inspect and go Back. Verify the documented mismatched-parent behavior read-only. Do not start/stop/restart services or mutate leases. |
| `LV66` | `/tool-call-traces` | Tool-call ledger/integrity report with tool/status/agent/issue/run filters, pagination, detail drawer, or explicit empty states. | Filter, clear, open/close a sanitized detail, and Verify Integrity. Run the one-time JSON/CSV generation checks from section 10 separately. |
| `LV67` | `/dev/prompt-inspector` | Development-only read-only **Prompt Inspector** with agent/issue selectors, generated prompt, signal chips, section count, and character count. | Render selectors without generating/copying in the route matrix. Run the one-time sensitive generation check from section 10 separately. Production 404 is expected. |

### 8.11 Compatibility redirects

These are controller routes, not duplicate content pages. Assert the final URL and then reuse the target page's result. Use a current same-company fixture for dynamic IDs.

| ID | Requested route | Expected final route |
|---|---|---|
| `REDIR01` | `/settings` | `/settings/profile` |
| `REDIR02` | `/adapters` | `/settings/adapters` |
| `REDIR03` | `/adapters/:key` | `/settings/adapters/:key` |
| `REDIR04` | `/execution-policies` | `/settings/policies` |
| `REDIR05` | `/execution-policies/new` | `/settings/policies/new` |
| `REDIR06` | `/execution-policies/:id` | `/settings/policies/:id` |
| `REDIR07` | `/execution-policies/:id/edit` | `/settings/policies/:id/edit` |
| `REDIR08` | `/audit-trail` | `/settings/audit` |
| `REDIR09` | `/companies/:id/secrets` | `/switch-company/:id?return_to=/settings/secrets`, then `/settings/secrets` with that accessible company selected |

### 8.12 Company-scoped browser actions

These routes do not render distinct pages, but their browser flows need explicit checks:

| ID | Flow | Expected result |
|---|---|---|
| `ACTION01` | `/switch-company/:id?return_to=/dashboard` | Accessible membership changes the current company and returns to Dashboard. Inaccessible company returns to `/`. Switch back immediately. |
| `ACTION02` | Global quick-create form → `POST /issues/quick-create` | Disposable run only: valid title creates one current-company issue and redirects to its detail; invalid title returns to issues with an error. |
| `ACTION03` | Global runtime Low power/Pause/Stop/Resume forms | Explicit runtime-control run only: manager action returns to a safe path with an audit-backed result; ordinary members receive the authorization error. |
| `ACTION04` | User-menu Sign out → `DELETE /logout` | Session is dropped and final URL is `/login`; a later protected route redirects back to login with `return_to`. |

### 8.13 Operator dashboard

`/beam` is instance-wide and uses separate HTTP Basic Auth. It is not authorized by Cympho owner or board membership.

Development credentials are `cympho` / `cympho`. Production uses separately configured credentials. If the operator dashboard is intentionally disabled, `/beam` returns 404 and the operator group is `SKIP`.

Set Basic Auth once for the entire operator group, keep it active while navigating every canonical subpage, then clear it before returning to app/API checks. Do not log dashboard body data because it is instance-wide:

```bash
ego-browser nodejs <<'EOF'
const taskId = Number(process.env.CYMPHO_EG_TASK_ID)
const baseUrl = process.env.CYMPHO_EG_BASE_URL
await useOrCreateTaskSpace(taskId)
await cdp('Network.enable')
const authorization = `Basic ${Buffer.from('cympho:cympho').toString('base64')}`
await cdp('Network.setExtraHTTPHeaders', {headers: {Authorization: authorization}})
const routes = [
  '/beam', '/beam/home', '/beam/os_mon', '/beam/memory_allocators',
  '/beam/metrics', '/beam/request_logger', '/beam/applications',
  '/beam/processes', '/beam/ports', '/beam/sockets', '/beam/ets',
  '/beam/ecto_stats'
]
const results = []
try {
  for (const route of routes) {
    await gotoAndWait(`${baseUrl}${route}`, {timeout: 30, settle: 0.5})
    const info = await pageInfo()
    results.push({requested: route, finalUrl: info.url, title: info.title})
  }
} finally {
  await cdp('Network.setExtraHTTPHeaders', {headers: {}})
}
cliLog(JSON.stringify(results))
EOF
```

Test each available page:

| ID | Route |
|---|---|
| `BEAM01` | `/beam` |
| `BEAM02` | `/beam/home` |
| `BEAM03` | `/beam/os_mon` |
| `BEAM04` | `/beam/memory_allocators` |
| `BEAM05` | `/beam/metrics` |
| `BEAM06` | `/beam/request_logger` |
| `BEAM07` | `/beam/applications` |
| `BEAM08` | `/beam/processes` |
| `BEAM09` | `/beam/ports` |
| `BEAM10` | `/beam/sockets` |
| `BEAM11` | `/beam/ets` |
| `BEAM12` | `/beam/ecto_stats` |

Also follow one generated node-prefixed link such as `/beam/:node/:page` when available. Inspect tabs, filters, and detail links read-only. Do not enable request logging on a shared instance without operator authorization.

`/beam` normally redirects to `/beam/home`; that is a pass. A canonical subpage can redirect to `/beam/home` when its node capability is disabled, such as unavailable OS monitoring or Ecto statistics. Record that subpage `SKIP: capability disabled`, not `PASS`. Query strings added by Metrics or Request Logger are allowed when the route path remains the requested page.

## 9. Whole-flow smoke scenarios

Route checks prove pages render. These scenarios prove pages work together. Run read-only portions by default and mutation portions only in a disposable run.

### FLOW01: authentication and authorization

1. Open `/login` and verify the standalone form.
2. Submit an invalid password and verify the error.
3. On confirmed local/isolated development only, sign in through `/dev/login?return_to=/dashboard` and record its bootstrap mutations. Else use the supplied test account through `/login`.
4. Verify Dashboard shows the expected owner and company.
5. Open `/setup`; on an established instance it must redirect to `/login`.
6. Open a board-governed page as the dev owner and verify content.
7. If a disposable non-board user/company exists, open the same page and verify redirect to `/` with the board-membership message. This denial writes a governance-audit row; record that retained side effect.
8. Separately, with an unauthenticated tab/state, open `/onboarding`; verify `/login?return_to=%2Fonboarding`.
9. If an authenticated company-less disposable user exists, open `/issues`; verify redirect to `/onboarding` without company data leakage.
10. On a separately confirmed empty disposable database only, submit valid `/setup` owner data and verify the new owner is signed in at `/onboarding`. This is not part of an established-database run.
11. Defer sign-out testing until every later flow and all cleanup are complete.
12. At that final checkpoint, sign out, open `/issues`, and verify the encoded redirect `/login?return_to=%2Fissues`.
13. Sign back in only if a final restoration check remains.

### FLOW02: onboarding

Read-only branch:

1. Open `/onboarding` in each render variant.
2. Inspect only the currently restored path/step, controls, copy, layout, and connection state.
3. Do not select a path, edit a field, or click Back/Next; each can persist or overwrite the signed-in user's onboarding draft.
4. Record the displayed draft state as a prerequisite, not as smoke-created state.

Disposable draft-resume branch:

1. Use a disposable user whose onboarding draft may be changed and later discarded with that user.
2. Select Start a company, choose a blueprint, and move through company/goal/project/budget, team/runtime, and review using current-run values.
3. Use Back and verify draft fields persist after reload.
4. Stop before final launch, switch to Improve this company, and verify its goal/context controls.
5. Discard only the disposable user's draft during cleanup; never clear a pre-existing user's draft.

Disposable branch:

1. Use company name `EGSMOKE-<run ID>` and the valid uppercase-alphanumeric `$CYMPHO_EG_ISSUE_PREFIX`.
2. Complete blueprint → company/goal/project/budget → team/runtime → review → launch → ready.
3. Verify the new company, owner+board membership, project, goal, agents, starter issues, and hard-stop budget policy.
4. Enter Cympho through the switch-company link.
5. Verify company scoping on Dashboard, Issues, Projects, Goals, Agents, and Budgets.
6. Record the company ID and every generated descendant ID, including fixed-name agents and starter issues. Do not assume the company can be cleanly deleted.

Improvement mutation branch:

1. On the disposable company, enter `EGSMOKE-<run ID> improvement` and optional context.
2. Click Create improvement once.
3. Verify one new goal and one linked issue in that company.
4. Refresh and verify the submission is not duplicated.

### FLOW03: work delivery

Disposable UI-only branch:

1. Create `EGSMOKE-<run ID> delivery issue` from `/issues/new`.
2. Verify it appears in `/issues`, `/kanban`, and the appropriate `/my-issues` tab.
3. Open its detail page and verify identifier, company, project/goal, role/assignee, work mode, status, and priority.
4. Exercise title/description editing only on this issue and verify persistence after reload.
5. Add a current-run comment and verify Activity and Inbox reflect the event where applicable.
6. Follow its issue-workspace page without creating filesystem state unless authorized.

Provider/runtime branch:

1. Run only when the adapter, secret, budget, project workspace, and execution workspace are configured and autonomous runtime is explicitly authorized.
2. Start with one focused issue, never the whole queue.
3. Inspect runs, comments, work products, documents, children, tool traces, and handoff state.
4. Submit review evidence.
5. Verify the item appears in Review queue.
6. Approve or request changes only on the owned fixture.
7. Verify owner verification on Dashboard/Operations, then Activity, Inbox, and Audit Trail.
8. If provider runtime is optional for this run and a prerequisite is missing, mark this branch `SKIP` with the exact missing fixture. Use `BLOCKED` only when the run contract explicitly requires provider runtime and a required dependency fails. Do not fake completion by editing unrelated records.

### FLOW04: governance

1. Require operator-prepared URLs for one disposable pending ordinary approval and one disposable pending board approval. If absent and governance mutation is optional, `SKIP`; do not manufacture a vote on existing business data.
2. Verify ordinary approval in list and detail, including requester, payload, linked work, and pending state.
3. Verify board risk brief, proposal, history, and vote counts.
4. Verify a non-board company user can view valid board detail but cannot vote.
5. With explicit mutation authority, cast one vote as the board fixture.
6. Verify persistence after reload, linked issue/company state, and audit record.
7. Never vote on a pre-existing business decision.

### FLOW05: strategy and workspace

1. Create current-run project, goal, and scoped issue only in the disposable company.
2. Verify project index/detail and filtered issue list.
3. Verify goal index/detail and progress/linked work.
4. Verify the issue references the correct project and goal.
5. Inspect `/workspaces`, the project-workspace detail, and an execution lane if provisioned.
6. Verify service/preview state under section 11.
7. Confirm a different company cannot load these IDs.

### FLOW06: routine

1. Create `EGSMOKE-<run ID> routine` with a current-run brief, owner, and project.
2. Verify index, detail, and edit pages.
3. Create a schedule trigger only when scheduler-side mutation is authorized.
4. Run manually only when agent execution is authorized.
5. Verify a generated issue and run-history result.
6. Verify pause/resume/archive only on the current-run routine.

### FLOW07: company portability

1. Generate the company JSON using section 10.
2. Validate the actual downloaded file, not only the link data.
3. Open `/companies/import` and upload that JSON.
4. Verify preview counts, warnings, company/slug plan, and secret-restore manifest.
5. Toggle **Auto-generate suffix** and **Fail on collision**; use suffix as the safe default.
6. Stop before Start Import in a read-only run.
7. In a disposable run, start import once, verify the new company and restore checklist, and record every created ID.

### FLOW08: company switching and tenant isolation

1. Use two companies accessible to the same fixture user.
2. In Company A, record counts and one entity URL per domain.
3. Switch to Company B using `/switch-company/:id?return_to=/dashboard`.
4. Verify shell label, counts, lists, search, settings, costs, traces, workspaces, and audit use Company B.
5. Directly request one Company A entity while Company B is active. Verify the documented not-found redirect and no leaked title/body.
6. Switch back to Company A and verify its state is unchanged.
7. Restore the user's persistent default company using the approved path from section 6.2, then sign out/in and verify it.

### FLOW09: agent hire, configuration, and readiness

Mutation mode only:

1. Require the disposable company, an authorized manager/board fixture, and a local adapter profile that does not contact a provider. If no such profile exists, `SKIP: safe local adapter fixture missing`.
2. Open `/agents/new`, enter `EGSMOKE-<run ID> engineer`, choose Engineer, choose the current-run CTO as **Reports to**, and select the approved local adapter/profile.
3. Confirm the Hire checklist has no unexpected credential or governance blocker. Click the visible **Hire Engineer** action once.
4. If hiring returns a current-run board-approval URL, record it and stop unless board-vote mutation is explicitly authorized. Otherwise verify the new agent appears in `/agents` and `/org-chart`.
5. Open the new agent and verify Dashboard, Instructions, Skills, Configuration, and Runs. Do not click Test adapter, Run heartbeat, Pause, Resume, Terminate, or assign a real task.
6. Record the agent, membership/approval, audit, and any auto-assignment side effects by UUID. Cleanup may delete only those current-run UUIDs.

### FLOW10: credential to adapter readiness

Sensitive mutation mode only:

1. Require the disposable company and an operator-approved fake sentinel such as `EGSMOKE-<run ID>-NOT-A-REAL-KEY`. Never use a real provider key in smoke evidence.
2. In `/settings/secrets`, create one company-scoped secret with the exact key required by the chosen adapter, the sentinel value, and a current-run description. Record the secret UUID; never snapshot or screenshot the value field.
3. Reload the secrets list and verify only redacted metadata appears.
4. Open `/agents/new` with the chosen adapter and verify its Hire checklist recognizes that the required key exists. Do not hire or execute with the fake value.
5. Open `/settings/adapters/:key` only when its automatic health request to the configured endpoint is authorized. Otherwise mark that substep `SKIP: provider health call unauthorized` while retaining the secret-to-readiness result.
6. Delete or retain only the recorded sentinel secret through the supported UI and record the result. Verify the adapter returns to its prior readiness state after cleanup.

### FLOW11: skill, plugin, and agent assignment

Mutation mode only:

1. Require operator-approved, inert test manifests and runtime settings. Do not invent or execute shell commands, marketplace installs, or remote plugin endpoints.
2. Create `EGSMOKE-<run ID> skill` through `/skills/new`; verify it in skill index, show, and edit, including manifest health and scope.
3. Create `EGSMOKE-<run ID> plugin` through `/plugins/new`; verify it in plugin index, show, edit, and settings. Record filesystem/registry effects as well as the plugin UUID.
4. Open the current-run agent from FLOW09, choose **Skills**, and tick only the current-run plugin in the skill library.
5. Verify Assigned increases by one and the plugin reports **Prompt ready**. Reload and verify persistence.
6. Untick it and verify the assignment is removed. Do not execute the plugin. Cleanup the current-run plugin and skill only when their UUIDs and any generated files are in the ledger.

### FLOW12: budget, costs, and incident linkage

1. In the disposable company, use its onboarding-created hard-stop budget or create `EGSMOKE-<run ID> budget` through `/budgets/new` when explicit finance mutation is authorized.
2. Verify `/budgets`, `/budgets/:id`, `/budgets/:id/edit`, and `/costs` agree on scope, period, amount, utilization, and zero/nonzero spend.
3. Do not create provider spend merely to populate this report. An explicit zero-spend state is valid.
4. Test warning/hard-stop incident linkage only with an operator-prepared current-run budget incident. Verify it in Costs, Operations, Inbox, and Audit Trail without dismissing it.
5. Budget deletion also deactivates its finance policy. Delete only a current-run budget when that policy effect is authorized; otherwise retain it under the disposable company ledger.

### FLOW13: launch tracker lifecycle

Mutation mode only:

1. Open `/launch-items`; enter `EGSMOKE-<run ID> launch item`, select the disposable owner, choose **Planned**, leave **Blocked** off, and click **Create launch item** once.
2. Locate the row by its exact title, extract its UUID from that row's event values, and add it to the ledger.
3. Click **Mark blocked** and verify the blocked count and row badge increase/change.
4. Click **In progress**, reload, and verify it remains selected.
5. Click **Completed** and verify completion count/percentage changes once.
6. The page has no delete control. Retain this row under the disposable company unless an approved supported cleanup path exists; never delete it directly from the database.

### FLOW14: inbox item lifecycle

Mutation mode only:

1. Require an inbox item whose source issue, approval, interaction, or incident is in the current-run ledger. If none exists, `SKIP: current-run inbox fixture missing`.
2. Open `/inbox?status=all&agent_id=all`, locate the row by the exact current-run title/source, and record its item and agent IDs.
3. Click **Mark read** once; verify the unread count decrements once and the row appears under **Read**.
4. Click **Archive** on that same row; verify it leaves the active view and appears under **Archived**.
5. Click **Restore**; verify it returns to the documented status. Do not approve, deny, answer, resolve, dismiss a budget incident, or perform a review decision unless that exact current-run decision is separately authorized.
6. Record the final inbox state; do not alter any pre-existing item.

### FLOW15: final restoration and authentication teardown

Run only after FLOW02–FLOW14 and all supported cleanup:

1. Verify every current-run UUID is either removed through supported UI or listed as retained residue.
2. Restore the original theme, Simple mode, cleared extra HTTP headers, desktop metrics, and the original company session.
3. Restore the persistent default company using section 6.2, sign out, and sign in once to prove restoration.
4. Sign out again, open `/issues`, and verify final URL `/login?return_to=%2Fissues` by parsing the `return_to` query value as `/issues`.
5. Finish reports, then close the Ego Lite task space with the dedicated final command in section 13.

## 10. Browser-native generation and download checks

Downloads must be validated from the bytes written to disk. A visible Download link or valid in-memory data does not prove the downloaded file is complete.

Run `GEN01` through `GEN05` once each, normally at 1440×900 in Advanced mode. They are separate report rows, not actions to repeat in every route-render variant. Before generating, remove or rename only current-run files with the same expected filename so an old download cannot be mistaken for the new one.

Before a download group, configure the download directory:

```javascript
await cdp('Browser.setDownloadBehavior', {
  behavior: 'allow',
  downloadPath: `${process.env.CYMPHO_EG_ARTIFACT_ROOT}/downloads`,
  eventsEnabled: true
}).catch(async () => {
  await cdp('Page.setDownloadBehavior', {
    behavior: 'allow',
    downloadPath: `${process.env.CYMPHO_EG_ARTIFACT_ROOT}/downloads`
  })
})
```

Wait for `Browser.downloadProgress` with `state: "completed"`. If the fallback `Page.setDownloadBehavior` was used, accept `Page.downloadProgress`; otherwise poll until the file size stops changing. Never validate a partially downloaded file.

### GEN01: company JSON

Page: `/companies/:id/export`

1. Assert the heading is `Export <company name>`.
2. Assert **Generate a portable operating export** and **Secret restore checklist** are present.
3. Click **Generate export** once.
4. Wait for **Download JSON** and **Export inventory**.
5. Verify inventory counts for Projects, Agents, Issues, Goals, Labels, and Members against the UI/source company.
6. Verify filename `<company slug>-export-<YYYY-MM-DD>.json`.
7. Click Download JSON.
8. Verify the actual downloaded file is nonzero and parses as JSON.
9. Verify `version`, `exported_at`, company identity, and array counts.
10. Verify secret-manifest entries contain only identifiers, scope, description, and restore metadata. Fail if any secret value, encrypted payload, hash, password, token, or API key value appears.
11. Verify comments and operating metadata expected for portability are present.
12. Click **Regenerate export**, download again, and verify the new file is complete.

Important: a company export is a portability package, not a full database or object-storage backup.

### GEN02: tool-trace JSON

Page: `/tool-call-traces`

1. Click **Verify Integrity**.
2. If integrity fails, record `FAIL` and do not claim the export is trustworthy.
3. Apply a known filter and record it.
4. Click **Export JSON**, then **Download JSON**.
5. Verify filename `tool-traces-<YYYY-MM-DD>.json`.
6. Parse the actual downloaded file.
7. Verify it is a JSON array and its rows match the full filtered result set, not only the currently loaded page.
8. An empty array is valid only when the filtered UI explicitly has zero rows; record `rows=0`.
9. Check exported fields for unexpected secrets before attaching evidence.

### GEN03: tool-trace CSV

Page: `/tool-call-traces`

1. Keep the same known filter as GEN02.
2. Click **Export CSV**, then **Download CSV**.
3. Verify filename `tool-traces-<YYYY-MM-DD>.csv`.
4. Verify the actual file is nonzero and starts with the expected header fields, including Sequence, Type, Tool, Status, Occurred At, Agent ID, and Issue ID.
5. Verify CSV data-row count matches GEN02's filtered JSON row count.
6. Verify quoting/newlines do not corrupt row structure.

### GEN04: org-chart SVG

Page: `/org-chart`

1. Verify `#org-chart-export-area` exists and has nonzero width and height.
2. If the page shows **No reporting lines yet**, mark generation `SKIP: reporting-tree fixture missing`.
3. Click **Export SVG**.
4. Verify filename `org-chart-<YYYY-MM-DD>.svg`.
5. Verify the actual file is nonzero XML containing `<svg`, `viewBox`, and `foreignObject`.
6. Verify the SVG dimensions are nonzero and its text includes at least the expected root agent/company context.
7. Treat a browser console error `Org chart container not found` as `FAIL`.

### GEN05: generated prompt

Page: `/dev/prompt-inspector`

1. Select a same-company issue. The agent selection is optional.
2. Verify **Generated Prompt** appears.
3. Verify section count and character count are both greater than zero.
4. Verify Prompt Signals render for Action contract, Digest checklist, and Owner revision.
5. Click **Copy prompt** and verify the button changes to **Copied**.
6. Do not print or screenshot the prompt body when it includes private issue context. Capture the counts and signal chips instead.
7. While still on the generated page, replace only the button's copy payload with a safe marker, click it through Ego Lite so the existing user-gesture copy hook runs, and verify the success label:

   ```javascript
   await js(String.raw`(() => {
     const button = document.querySelector('[data-copy-label="Copy prompt"]')
     button.dataset.copyText = 'EGSMOKE CLIPBOARD CLEARED'
     button.dataset.copySuccessLabel = 'Clipboard cleared'
     return true
   })()`)
   await click('[data-copy-label="Copy prompt"]', {label: 'clear copied prompt'})
   await wait(0.5)
   const label = await js(String.raw`document.querySelector('[data-copy-label="Copy prompt"]')?.innerText.trim()`)
   let clipboardText = null
   let clipboardReadError = null
   try {
     clipboardText = await js(String.raw`navigator.clipboard.readText()`)
   } catch (error) {
     clipboardReadError = String(error)
   }
   cliLog(JSON.stringify({
     clipboardCleanupLabel: label,
     clipboardMatchesMarker: clipboardText === 'EGSMOKE CLIPBOARD CLEARED',
     clipboardReadError
   }))
   ```

   Require `label == "Clipboard cleared"` **and** `clipboardMatchesMarker == true`. Never print the clipboard text itself: a failed replacement could leave the private prompt there. The label alone does not prove the clipboard changed. If clipboard readback is unavailable or either value differs, record `BLOCKED` and tell the operator that prompt content may remain in the clipboard.
8. This generation is in-page only; no downloaded file is expected.

### Not product report-generation surfaces

- Company import consumes a portability report; it does not generate one.
- Attachment downloads are user artifacts, not reports.
- `/api/companies/:company_id/export` is API coverage, not a browser-page flow.
- `mix cympho.llmotions_smoke` generates a CLI report outside this browser guide.

## 11. Runtime preview and responsive checks

### 11.1 Runtime previews

Workspace preview anchors use `/api/preview/:service_id/proxy/*path`. Those routes require a Bearer **user JWT**, while ordinary Cympho page navigation uses a browser session cookie. Following the visible anchor without a Bearer token can return 401 JSON. Record that as `preview auth-boundary result`, not as a crash of `/workspaces/:id`.

For an authorized preview test, record three supporting checks. These are API-backed derived checks, not additional page routes:

1. Require a running service with an allowed loopback target and a same-company execution workspace.
2. Obtain the user JWT through `POST /api/login` without logging it.
3. Set `Authorization: Bearer <token>` and `X-Company-ID: <current non-secret company UUID>` through CDP inside a `try` block. API company scope comes from `X-Company-ID`, then the JWT/default company—not from the browser's switched-company session—so omitting it can test the wrong tenant. Always clear both headers in `finally`.
4. `PREVIEW-META-<service ID>`: request `GET /api/preview/:service_id`; verify 200 JSON is scoped to the service and contains the expected generated preview URL without exposing another tenant's target.
5. `PREVIEW-LIST-<exec ID>`: request `GET /api/exec-workspaces/:id/previews`; verify 200 JSON lists only services belonging to the same-company execution workspace, preserves each service's reported status, and includes the fixture service once. Do not assume every returned service is currently previewable.
6. `PREVIEW-PROXY-<service ID>`: open `/api/preview/:service_id/proxy/`; verify the proxied application's heading/content, local resources, navigation, status, and errors as a separate derived page result.
7. Verify foreign-company service and execution-workspace IDs return not found and expose no target URL.
8. In `finally`, clear both extra headers, then verify ordinary application navigation uses neither Bearer authorization nor `X-Company-ID`.

Never put the JWT in a URL, screenshot, CLI log, or report.

### 11.2 Mobile matrix

Every `LV` page gets `mobile-simple` and `mobile-advanced` at 390 x 844. In addition, run these focused geometry checks:

Record the focused portrait group as `RESP01-portrait` and the focused landscape group as `RESP02-landscape`, with one child row per named route below.

- `/onboarding`: both paths fit the content width; long forms scroll; primary actions clear mobile navigation.
- `/inbox?agent_id=all&density=detailed`: diagnostics wrap and filters remain reachable.
- `/kanban`: board uses its mobile board height; cards scroll inside columns above bottom navigation.
- `/issues/new`: sticky submit actions stay above bottom navigation.
- `/agents/new`: Hire/Cancel actions stay above bottom navigation.
- every modal/drawer/detail panel: close control is visible and Escape works.
- every table/report: content scrolls inside its intended container without widening the document.

For form/keyboard behavior, focus a lower-page input, set the viewport to 390 x 500, scroll its action into view, and verify the action's bottom is above the mobile navigation's top.

Run landscape at 844 x 390 for:

- global shell and mobile drawer;
- onboarding;
- issue creation;
- agent creation;
- Inbox detailed mode;
- Kanban;
- one settings form;
- company import preview;
- any page that failed portrait geometry.

For every responsive check require:

```text
document.documentElement.scrollWidth <= document.documentElement.clientWidth
```

An intentionally horizontally scrollable inner table/board is allowed only when the document itself does not overflow and all controls remain reachable.

## 12. Report generation format

### 12.1 Per-page Markdown file

Create `pages/<check ID>.md` immediately after each check:

```markdown
# <check ID> — <requested route>

- Result: PASS | FAIL | SKIP | BLOCKED
- Requested route: <route>
- Final URL: <URL after navigation>
- Page title: <document title>
- Visible heading: <main heading or explicit empty-state title>
- Viewport: <width>x<height>
- Interface mode: Simple | Advanced | not applicable
- Authenticated role: <role>
- Board member: yes | no | not applicable
- Current company: <company name and non-secret ID>
- Fixture: <seeded row, current-run row, or missing prerequisite>
- Expected state: <literal expectation from section 8>
- Interaction: <single action performed>
- Observed state: <literal result after interaction>
- LiveView connected: yes | no | not applicable
- Horizontal document overflow: yes | no
- Console/page exceptions: <count and sanitized summary>
- Network failures/5xx: <count and sanitized summary>
- Broken images: <count and sanitized summary>
- Screenshot: <absolute artifact path>
- Download: <absolute path, size, parse result, or not applicable>
- Created/changed IDs: <current-run IDs or none>
- Automatic side effects: <read state, health request, external request, boot recovery, or none>
- Cleanup: <done, residual recorded, or not applicable>
- Notes: <concise evidence or exact skip/block reason>
```

Do not leave a field blank. Use `not applicable` or `none`.

### 12.2 Route-results TSV

Use one tab-separated row per check with this header:

```text
check_id	requested_route	final_url	viewport	mode	role	board_member	company	fixture	expected	interaction	result	evidence	error	created_ids	automatic_side_effects
```

There must be four rows for every `LV01` through `LV75`, except a build-gated route whose missing-build reason is recorded. Auth, redirect, action, BEAM, preview, and generation rows are additional. Add one consolidated result row for every `FLOW01` through `FLOW15`; optional operator-prepared branches may be `SKIP` with their exact missing fixture. Also add the global and focused responsive check rows named in sections 7 and 11.

### 12.3 Finding file

Create `findings/FINDING-<number>.md` for every unique defect:

```markdown
# FINDING-<number> — <short defect title>

- Severity: blocker | high | medium | low
- First failing check: <check ID>
- Route: <requested route>
- Environment: <base URL, build/commit, viewport, mode, role, company>
- Preconditions: <literal fixture and state>
- Reproduction:
  1. <first concrete action>
  2. <second concrete action>
  3. <final concrete action>
- Expected: <one observable result>
- Actual: <one observable result>
- Reproducibility: <attempts that failed>/<attempts run>
- Browser evidence: <screenshot and sanitized error/event paths>
- Download evidence: <path, size, parser result, or not applicable>
- Side effects: <created/changed IDs or none>
- Security note: <redaction performed or not applicable>
```

Do not create duplicate findings for the same root symptom. Reference the existing finding from later failed rows.

### 12.4 Final run report

Create `run-report.md` with these sections in this order:

```markdown
# Cympho Ego Lite smoke report — <run ID>

## Run identity

- Base URL:
- Git commit/build:
- Start UTC:
- End UTC:
- Ego Lite task-space ID:
- Operator:
- Mutation mode: read-only | disposable
- Initial company:
- Roles tested:
- Board membership states tested:
- Artifact retention/deletion decision:

## Coverage totals

- Planned checks:
- Executed checks:
- PASS:
- FAIL:
- SKIP:
- BLOCKED:
- LiveView route IDs represented out of 75:
- Render variants represented out of 4 per LiveView route:
- Compatibility redirects represented out of 9:
- Available BEAM pages represented:
- Generated artifacts represented out of 5:
- Whole-product flows represented out of 15:
- Preview metadata/list/proxy checks represented:
- Global shell/accessibility/LiveView checks represented:
- Focused responsive checks represented:

## Release verdict

PASS | FAIL

<One sentence based on zero FAIL/BLOCKED and accepted skips.>

## Failed checks

| Check ID | Route | Finding | Evidence |
|---|---|---|---|

## Blocked checks

| Check ID | Route | Blocker | Required next action |
|---|---|---|---|

## Skipped checks

| Check ID | Route | Missing optional prerequisite | Why skip is acceptable |
|---|---|---|---|

## Generated artifacts

| Generation ID | Page | File/state | Bytes | Validation | Result |
|---|---|---|---:|---|---|

## Browser errors

| Check ID | Type | Sanitized message | Finding |
|---|---|---|---|

## Side effects and cleanup

| Entity/action | ID | Created/changed | Cleanup result |
|---|---|---|---|

## Residual risk

<Exact untested providers, permissions, physical-device limits, or retained fixtures.>
```

The final report must never claim `PASS` while any row is `FAIL` or `BLOCKED`.

## 13. Final audit and cleanup

Before closing the browser:

1. Confirm every `LV01` through `LV75` appears in `route-results.tsv` for all four render variants, or has an explicit build/prerequisite result.
2. Confirm `AUTH01` through `AUTH03`, `REDIR01` through `REDIR09`, `ACTION01` through `ACTION04`, `FLOW01` through `FLOW15`, available BEAM pages, every preview metadata/list/proxy fixture, `GEN01` through `GEN05`, and global/responsive check groups are represented.
3. Re-run every failed check once from a known state. Do not retry a destructive action.
4. Verify every generated download from the actual disk bytes.
5. Verify all findings contain reproduction evidence and no secrets.
6. Restore the original theme.
7. Restore Simple mode:

```bash
ego-browser nodejs <<'EOF'
const taskId = Number(process.env.CYMPHO_EG_TASK_ID)
const baseUrl = process.env.CYMPHO_EG_BASE_URL
await useOrCreateTaskSpace(taskId)
await js(String.raw`localStorage.setItem('cympho-ui-mode', 'simple')`)
await cdp('Network.setExtraHTTPHeaders', {headers: {}}).catch(() => null)
await cdp('Emulation.clearDeviceMetricsOverride').catch(() => null)
await gotoAndWait(`${baseUrl}/dashboard`, {timeout: 30, settle: 0.5})
const uiMode = await js(String.raw`document.documentElement.dataset.uiMode`)
if (uiMode !== 'simple') throw new Error(`Simple-mode restoration failed: ${uiMode}`)
cliLog(JSON.stringify({pageInfo: await pageInfo(), uiMode}))
EOF
```

8. Clean only UUIDs in the current-run ledger that can be safely removed. Record every retained row and automatic side effect.
9. Restore and verify the persistent default company, then finish the deferred sign-out/auth-guard check from FLOW15.
10. Record whether the exact artifact directory is retained in an approved location or removed after approval; never broadly delete `/tmp/cympho-eg-smoke`.
11. Complete `run-report.md` and confirm its totals match `route-results.tsv`.
12. Close the Ego Lite task space in its own final command. Run this only after the prior command confirms the report is complete:

```bash
ego-browser nodejs <<'EOF'
const taskId = Number(process.env.CYMPHO_EG_TASK_ID)
const result = await completeTaskSpace(taskId, {keep: false})
cliLog(JSON.stringify(result))
EOF
```

The cleanup is complete only when the result contains `done: true`. If it is skipped, record the reason and resolve ownership before claiming the Ego Lite session is closed.

After the task space reports `done: true`, stop only the exact server terminal/PID recorded in section 3.1, normally by sending Ctrl-C to that terminal, and verify that process exits. Do not use a broad process-kill command. If the server was supplied and owned by someone else, leave it running and record `server lifecycle: externally owned`.

## 14. Quick failure decisions for a low-capability agent

Use this final decision table when uncertain:

| Situation | Result and action |
|---|---|
| Correct empty-state text, no fixture | List page `PASS`; dependent detail page `SKIP`. |
| Redirected to login while expecting authenticated content | `BLOCKED` if the session unexpectedly expired; otherwise expected auth result. |
| Redirected home from a board page as a non-board user | Authorization check `PASS`; board-content check still needs a board fixture. |
| Wrong final URL or another tenant's title/body appears | `FAIL`, high severity, stop tenant-boundary mutation tests. |
| Visible `.phx-disconnected` after settling | `FAIL`. |
| Browser exception, local asset failure, or 5xx | `FAIL`; capture sanitized events. |
| Third-party font/CDN failure but app remains usable | Record a warning/finding; fail if a required control such as SortableJS no longer works. |
| Document-level horizontal overflow | `FAIL` unless the route expectation explicitly allows it, which this guide does not. |
| Preview anchor returns 401 JSON without Bearer JWT | Record expected preview auth-boundary result; do not fail the workspace page. |
| Download link appears but disk file is missing, truncated, or unparsable | Generation `FAIL`. |
| Secret appears in page text, snapshot, screenshot, URL, log, or export value | Stop, redact evidence, and file a high-severity security finding. |
| Unexpected confirmation dialog appears | Cancel it, record the control, and do not retry without authorization. |
| User takes control of the Ego Lite task space | Stop browser work and ask the user before taking control back. |
| Ego Lite task space cannot be closed | Final cleanup `BLOCKED`; do not claim completion. |
