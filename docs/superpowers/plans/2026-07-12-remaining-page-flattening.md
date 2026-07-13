# Remaining Page Flattening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate remaining high-density pages from nested bordered cards to Cympho’s adaptive operational-console, editorial-detail, and calm-form archetypes.

**Architecture:** Reuse the interaction and flat-layout primitives delivered by the first two plans. Migrate one page family at a time, preserving LiveView state/events and creating a browser acceptance checkpoint after each family. Advanced mode retains density through bands, rows, split panes, and disclosures; simple mode preserves only primary decisions and actions.

**Tech Stack:** Phoenix LiveView, HEEx function components, Tailwind CSS, shared Cympho components, ExUnit LiveView tests, Playwright browser verification.

---

## File Structure

Shared:

- Modify `lib/cympho_web/components.ex` only when a genuinely reusable primitive is missing.
- Modify `assets/css/app.css` for shared archetype classes; no page-specific selector pileups.
- Create `docs/verification/page-flattening.md` for responsive acceptance.
- Create `docs/verification/page-flattening.md` for the visual checklist.

Operational console family:

- `lib/cympho_web/live/operations_live/index.html.heex`
- `lib/cympho_web/live/dashboard_live/index.html.heex`
- `lib/cympho_web/live/cost_live/index.html.heex`
- `lib/cympho_web/live/tool_call_traces_live.ex`
- `lib/cympho_web/live/kanban_live/index.html.heex`

Editorial detail/list family:

- `lib/cympho_web/live/agent_live/show.html.heex`
- `lib/cympho_web/live/project_live/show.html.heex`
- `lib/cympho_web/live/goal_live/index.html.heex`
- `lib/cympho_web/live/project_live/index.html.heex`
- `lib/cympho_web/live/approval_live/index.html.heex`
- `lib/cympho_web/live/review_queue_live/index.html.heex`

Calm form/settings family:

- `lib/cympho_web/live/agent_live/new.html.heex`
- `lib/cympho_web/live/issue_live/new.html.heex`
- `lib/cympho_web/live/project_live/new.html.heex`
- `lib/cympho_web/live/project_live/form_component.html.heex`
- `lib/cympho_web/live/goal_live/new.html.heex`
- `lib/cympho_web/live/goal_live/edit.html.heex`
- `lib/cympho_web/live/settings_live/integrations.html.heex`
- `lib/cympho_web/live/onboarding_live/index.html.heex`
- `lib/cympho_web/live/company_import_live.ex`
- `lib/cympho_web/live/company_export_live.ex`

### Task 1: Add Archetype Contract Tests

**Files:**
- Create: `test/cympho_web/components/page_archetype_test.exs`
- Create: `docs/verification/page-flattening.md`
- Modify: `assets/css/app.css`

- [ ] **Step 1: Write failing markup contract tests**

```elixir
defmodule CymphoWeb.Components.PageArchetypeTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  test "instrument band renders metrics without card elevation" do
    html = render_component(&CymphoWeb.Components.instrument_band/1, %{
      metrics: [%{label: "Ready", value: 12}, %{label: "Blocked", value: 2}]
    })

    assert html =~ "Ready"
    assert html =~ "Blocked"
    refute html =~ "shadow-card"
    refute html =~ "rounded-xl"
  end

  test "form section renders a divider hierarchy without a panel" do
    html = render_component(&CymphoWeb.Components.form_section/1, %{
      title: "Operating boundary",
      description: "Describe what belongs here.",
      inner_block: [%{inner_block: fn _, _ -> "Fields" end}]
    })

    assert html =~ "Operating boundary"
    refute html =~ "bg-panel"
  end
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mix test test/cympho_web/components/page_archetype_test.exs`

Expected: FAIL if `instrument_band/1` or `form_section/1` is not already delivered by the issue plan.

- [ ] **Step 3: Implement missing primitives only**

```elixir
attr :metrics, :list, required: true
attr :class, :any, default: nil

def instrument_band(assigns) do
  ~H"""
  <dl class={["instrument-band", @class]}>
    <div :for={metric <- @metrics} class="instrument-band__item">
      <dt class="text-eyebrow uppercase text-ink-tertiary">{metric.label}</dt>
      <dd class="mt-1 font-mono text-2xl font-590 tabular-nums text-ink">{metric.value}</dd>
      <p :if={metric[:hint]} class="text-caption text-ink-subtle">{metric.hint}</p>
    </div>
  </dl>
  """
end

attr :title, :string, required: true
attr :description, :string, default: nil
attr :class, :any, default: nil
slot :inner_block, required: true

def form_section(assigns) do
  ~H"""
  <section class={["form-section", @class]}>
    <div class="mb-5">
      <h2 class="text-eyebrow uppercase text-ink-tertiary">{@title}</h2>
      <p :if={@description} class="mt-1 text-body-sm text-ink-subtle">{@description}</p>
    </div>
    {render_slot(@inner_block)}
  </section>
  """
end
```

- [ ] **Step 4: Add archetype CSS**

```css
.instrument-band { display: grid; border-block: 1px solid var(--color-hairline); }
.instrument-band__item { min-width: 0; padding: 1rem 1.25rem; }
.instrument-band__item + .instrument-band__item { border-left: 1px solid var(--color-hairline); }
.form-section { padding-block: 2rem; }
.form-section + .form-section { border-top: 1px solid var(--color-hairline); }
@media (max-width: 767px) {
  .instrument-band { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .instrument-band__item:nth-child(odd):not(:first-child),
  .instrument-band__item:nth-child(even):not(:nth-child(2)) { border-top: 1px solid var(--color-hairline); }
}
```

Use component-supplied CSS grid column count or utility classes for variable metric counts.

- [ ] **Step 5: Run test/build and commit**

```bash
mix test test/cympho_web/components/page_archetype_test.exs
mix tailwind cympho
git add lib/cympho_web/components.ex assets/css/app.css test/cympho_web/components/page_archetype_test.exs docs/verification/page-flattening.md
git commit -m "feat: add adaptive page archetypes"
```

### Task 2: Flatten Agent Detail

**Files:**
- Modify: `lib/cympho_web/live/agent_live/show.html.heex`
- Modify: `test/cympho_web/live/agent_live_test.exs`
- Modify: `docs/verification/page-flattening.md`

- [ ] **Step 1: Write failing structural assertions**

```elixir
test "agent detail uses one command workspace and flat diagnostic sections", %{conn: conn, agent: agent} do
  {:ok, view, html} = live(conn, ~p"/agents/#{agent.id}")

  assert has_element?(view, "#agent-command-workspace")
  assert has_element?(view, "#agent-instrument-band")
  assert has_element?(view, "#agent-context-actions")
  refute html =~ ~r/id="agent-command-workspace"[\s\S]*shadow-card[\s\S]*shadow-card[\s\S]*shadow-card/
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mix test test/cympho_web/live/agent_live_test.exs --trace`

Expected: FAIL on missing new structure.

- [ ] **Step 3: Restructure dashboard tab**

- Replace four small stat cards with `instrument_band`.
- Convert Run readiness to the primary unboxed command section.
- Keep latest run and recent issues as repeated-row sections.
- Move Wake History and raw runtime diagnostics to advanced-only disclosure sections.
- Keep Instructions, Skills, Configuration, Runs tab event names and values unchanged.

Use IDs from Step 1 and retain every existing `phx-click`, `phx-value-*`, `data-testid`, and form ID.

- [ ] **Step 4: Convert secondary buttons to icon controls**

Use `icon_button/1` for pause/resume, heartbeat, edit, copy, delete, and overflow actions where text is redundant. Retain visible text for Assign Task, Dispatch Queue, Tune Guide, and other workflow-specific actions.

- [ ] **Step 5: Run tests and browser acceptance**

```bash
mix test test/cympho_web/live/agent_live_test.exs
Invoke `/verify` and drive the page-flattening scenarios matching `agent detail`
```

Browser case checks 1440×900 and 390×844, both UI modes, no horizontal overflow, and tab changes.

- [ ] **Step 6: Commit**

```bash
git add lib/cympho_web/live/agent_live/show.html.heex test/cympho_web/live/agent_live_test.exs docs/verification/page-flattening.md
git commit -m "feat: flatten agent command workspace"
```

### Task 3: Flatten Operations Console

**Files:**
- Modify: `lib/cympho_web/live/operations_live/index.html.heex`
- Modify: `test/cympho_web/live/operations_live_test.exs`
- Modify: `docs/verification/page-flattening.md`

- [ ] **Step 1: Write failing structure test**

```elixir
test "operations uses one instrument band and flat operational sections", %{conn: conn} do
  {:ok, view, html} = live(conn, ~p"/operations")

  assert has_element?(view, "#operations-command-header")
  assert has_element?(view, "#operations-instrument-band")
  assert has_element?(view, "#runtime-capacity")
  refute html =~ ~r/id="operations-instrument-band"[\s\S]*rounded-xl[\s\S]*rounded-xl/
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mix test test/cympho_web/live/operations_live_test.exs --trace`

- [ ] **Step 3: Migrate sections**

- Runtime mode, ready, queue, and capacity metrics → one instrument band.
- Delegated queue and CEO flow → dominant working sections with row dividers.
- Adapter health, staffing gaps, host footprint → advanced flat sections.
- Repair/cleanup actions → warning bands only when action is needed.
- Remove decorative outer panel when the section already has a table/list boundary.

Do not change event names, IDs referenced in tests, or anchors linked from other pages.

- [ ] **Step 4: Run tests/browser and commit**

```bash
mix test test/cympho_web/live/operations_live_test.exs
Invoke `/verify` and drive the page-flattening scenarios matching `operations`
git add lib/cympho_web/live/operations_live/index.html.heex test/cympho_web/live/operations_live_test.exs docs/verification/page-flattening.md
git commit -m "feat: flatten operations console"
```

### Task 4: Flatten Dashboard, Costs, and Tool Traces

**Files:**
- Modify: `lib/cympho_web/live/dashboard_live/index.html.heex`
- Modify: `lib/cympho_web/live/cost_live/index.html.heex`
- Modify: `lib/cympho_web/live/tool_call_traces_live.ex`
- Modify: `test/cympho_web/live/dashboard_live_test.exs`
- Modify: `test/cympho_web/live/cost_live_test.exs`
- Modify: `test/cympho_web/live/tool_call_traces_live_test.exs`
- Modify: `docs/verification/page-flattening.md`

- [ ] **Step 1: Add failing page-archetype tests**

For each page assert a command header, instrument band, dominant work surface, and no nested metric-card grid. Example:

```elixir
assert has_element?(view, "#cost-instrument-band")
refute html =~ ~r/id="cost-instrument-band"[\s\S]*shadow-card[\s\S]*shadow-card/
```

- [ ] **Step 2: Run and verify RED**

```bash
mix test test/cympho_web/live/dashboard_live_test.exs test/cympho_web/live/cost_live_test.exs test/cympho_web/live/tool_call_traces_live_test.exs
```

- [ ] **Step 3: Migrate Dashboard**

- Keep “What’s up next?” as the primary command surface.
- Collapse operating mode/capacity/blocked metrics into one band.
- Remove nested shells around owner action plan.
- Preserve simple cards only in simple mode; advanced mode uses row/band layout.

- [ ] **Step 4: Migrate Costs**

- Top spend/budget values → instrument band.
- Active budgets → dominant list/table surface.
- Charts and provider/model breakdowns → advanced flat sections separated by rules.
- Preserve warning banners for unpriced usage and budget risk.

- [ ] **Step 5: Migrate Tool Traces**

- Filters → one toolbar.
- Trace rows → divided list/table.
- Selected trace → split pane on desktop, stacked detail on mobile.
- Raw request/response payloads retain code surfaces without extra outer cards.

- [ ] **Step 6: Run tests/browser and commit**

```bash
mix test test/cympho_web/live/dashboard_live_test.exs test/cympho_web/live/cost_live_test.exs test/cympho_web/live/tool_call_traces_live_test.exs
Invoke `/verify` and drive the page-flattening scenarios matching `dashboard|costs|tool traces`
git add lib/cympho_web/live/dashboard_live/index.html.heex lib/cympho_web/live/cost_live/index.html.heex lib/cympho_web/live/tool_call_traces_live.ex test/cympho_web/live/dashboard_live_test.exs test/cympho_web/live/cost_live_test.exs test/cympho_web/live/tool_call_traces_live_test.exs docs/verification/page-flattening.md
git commit -m "feat: flatten operational analytics pages"
```

### Task 5: Simplify Kanban Command Area

**Files:**
- Modify: `lib/cympho_web/live/kanban_live/index.html.heex`
- Modify: `lib/cympho_web/live/kanban_live/components.ex`
- Modify: `test/cympho_web/live/kanban_live_test.exs`
- Modify: `docs/verification/page-flattening.md`

- [ ] **Step 1: Write failing assertions**

```elixir
test "kanban uses one toolbar and flat command summary", %{conn: conn} do
  {:ok, view, html} = live(conn, ~p"/kanban")
  assert has_element?(view, "#kanban-toolbar")
  assert has_element?(view, "#kanban-command-band")
  refute html =~ ~r/id="kanban-command-band"[\s\S]*rounded-xl[\s\S]*rounded-xl/
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mix test test/cympho_web/live/kanban_live_test.exs --trace`

- [ ] **Step 3: Flatten the command area**

- Merge project, list/board, swimlanes, density, assignee, priority, and search into one responsive toolbar.
- Convert Flow Health metrics to a flat instrument band.
- Convert Focus Queue to a horizontally scrollable row of actionable records without another outer rounded panel.
- Keep kanban columns and issue cards as meaningful containers.
- Preserve all SortableJS IDs/data attributes.

- [ ] **Step 4: Run drag/filter tests and browser acceptance**

```bash
mix test test/cympho_web/live/kanban_live_test.exs
Invoke `/verify` and drive the page-flattening scenarios matching `kanban`
```

Verify horizontal board scrolling remains possible while the page itself has no accidental horizontal overflow outside the board viewport.

- [ ] **Step 5: Commit**

```bash
git add lib/cympho_web/live/kanban_live/index.html.heex lib/cympho_web/live/kanban_live/components.ex test/cympho_web/live/kanban_live_test.exs docs/verification/page-flattening.md
git commit -m "feat: simplify kanban command surface"
```

### Task 6: Flatten Agent, Issue, and Project Creation Forms

**Files:**
- Modify: `lib/cympho_web/live/agent_live/new.html.heex`
- Modify: `lib/cympho_web/live/issue_live/new.html.heex`
- Modify: `lib/cympho_web/live/project_live/new.html.heex`
- Modify: `lib/cympho_web/live/project_live/form_component.html.heex`
- Modify: `test/cympho_web/live/agent_live_test.exs`
- Modify: `test/cympho_web/live/issue_live_test.exs`
- Modify: `test/cympho_web/live/project_live_test.exs`
- Modify: `docs/verification/page-flattening.md`

- [ ] **Step 1: Add failing form structure tests**

```elixir
assert has_element?(view, "#project-form .form-section")
refute html =~ ~r/id="project-form"[\s\S]*shadow-card[\s\S]*shadow-card/
assert has_element?(view, "#project-form-actions")
```

Add equivalent assertions for agent and issue forms.

- [ ] **Step 2: Run and verify RED**

```bash
mix test test/cympho_web/live/agent_live_test.exs test/cympho_web/live/issue_live_test.exs test/cympho_web/live/project_live_test.exs
```

- [ ] **Step 3: Migrate each form**

For each:

- One unframed form canvas.
- Replace nested card sections with `form_section/1`.
- Keep inputs and real semantic warning boundaries.
- Convert setup checklist rail to an unframed sticky ordered list.
- Move submit/cancel to stable footer `id="*-form-actions"`.
- Ensure advanced fields are in `ui-advanced-only` disclosures without removing submit paths from simple mode.

- [ ] **Step 4: Verify select/date placement in long forms**

Browser tests open controls near viewport bottom and right edge, asserting ≤8 px anchor gap and viewport containment.

- [ ] **Step 5: Run tests/browser and commit**

```bash
mix test test/cympho_web/live/agent_live_test.exs test/cympho_web/live/issue_live_test.exs test/cympho_web/live/project_live_test.exs
Invoke `/verify` and drive the page-flattening scenarios matching `form`
git add lib/cympho_web/live/agent_live/new.html.heex lib/cympho_web/live/issue_live/new.html.heex lib/cympho_web/live/project_live/new.html.heex lib/cympho_web/live/project_live/form_component.html.heex test/cympho_web/live/agent_live_test.exs test/cympho_web/live/issue_live_test.exs test/cympho_web/live/project_live_test.exs docs/verification/page-flattening.md
git commit -m "feat: flatten core creation forms"
```

### Task 7: Flatten Goal and Settings Forms

**Files:**
- Modify: `lib/cympho_web/live/goal_live/new.html.heex`
- Modify: `lib/cympho_web/live/goal_live/edit.html.heex`
- Modify: `lib/cympho_web/live/goal_live/form_helpers.ex`
- Modify: `lib/cympho_web/live/settings_live/integrations.html.heex`
- Modify: `lib/cympho_web/live/onboarding_live/index.html.heex`
- Modify: `test/cympho_web/live/goal_live_test.exs`
- Modify: `test/cympho_web/live/settings_live_test.exs`
- Modify: `test/cympho_web/live/onboarding_live_test.exs`
- Modify: `docs/verification/page-flattening.md`

- [ ] **Step 1: Add failing form hierarchy tests**

Assert form sections, stable action footer, and absence of nested `shadow-card` wrappers around strategy hierarchy/operating posture.

- [ ] **Step 2: Run and verify RED**

```bash
mix test test/cympho_web/live/goal_live_test.exs test/cympho_web/live/settings_live_test.exs test/cympho_web/live/onboarding_live_test.exs
```

- [ ] **Step 3: Flatten goal forms**

- Strategy hierarchy and operating posture become unboxed `form_section`s.
- Preserve Goal Type, Parent Goal, Project Context, Status, Priority, and Target Date bindings.
- Verify the Parent Goal popover at viewport bottom using the shared placement system.

- [ ] **Step 4: Flatten Integrations/Onboarding**

- Each external service is one meaningful integration record, not a card containing cards.
- API/MCP developer detail remains advanced-only in divided sections.
- Onboarding steps become a single progress path with one active form surface.

- [ ] **Step 5: Run tests/browser and commit**

```bash
mix test test/cympho_web/live/goal_live_test.exs test/cympho_web/live/settings_live_test.exs test/cympho_web/live/onboarding_live_test.exs
Invoke `/verify` and drive the page-flattening scenarios matching `goal form|integrations|onboarding`
git add lib/cympho_web/live/goal_live lib/cympho_web/live/settings_live/integrations.html.heex lib/cympho_web/live/onboarding_live/index.html.heex test/cympho_web/live/goal_live_test.exs test/cympho_web/live/settings_live_test.exs test/cympho_web/live/onboarding_live_test.exs docs/verification/page-flattening.md
git commit -m "feat: flatten strategy and integration forms"
```

### Task 8: Flatten Project/Goal Lists and Project Detail

**Files:**
- Modify: `lib/cympho_web/live/project_live/index.html.heex`
- Modify: `lib/cympho_web/live/project_live/show.html.heex`
- Modify: `lib/cympho_web/live/goal_live/index.html.heex`
- Modify: `test/cympho_web/live/project_live_test.exs`
- Modify: `test/cympho_web/live/goal_live_test.exs`
- Modify: `docs/verification/page-flattening.md`

- [ ] **Step 1: Add failing structure tests**

- Project list: one overview band + repeated project records.
- Goal list: one command header + repeated goal records.
- Project detail: editorial main column + context/actions rail.

- [ ] **Step 2: Run and verify RED**

```bash
mix test test/cympho_web/live/project_live_test.exs test/cympho_web/live/goal_live_test.exs
```

- [ ] **Step 3: Migrate list pages**

- Remove metric cards nested inside project/goal cards.
- Render progress/status as compact rows or one inline meter.
- Keep Open/Edit/Archive/Delete actions in overflow or icon controls with tooltips.
- Preserve accessible text for project/goal names and primary navigation.

- [ ] **Step 4: Migrate project detail**

- Description and goals/issues are unboxed main sections.
- Settings form uses calm form sections.
- Environment variables/secrets remain advanced-only.
- Context rail contains status, prefix, repository, color, and archive controls.

- [ ] **Step 5: Run tests/browser and commit**

```bash
mix test test/cympho_web/live/project_live_test.exs test/cympho_web/live/goal_live_test.exs
Invoke `/verify` and drive the page-flattening scenarios matching `project|goal list`
git add lib/cympho_web/live/project_live lib/cympho_web/live/goal_live/index.html.heex test/cympho_web/live/project_live_test.exs test/cympho_web/live/goal_live_test.exs docs/verification/page-flattening.md
git commit -m "feat: flatten project and goal workspaces"
```

### Task 9: Flatten Approval and Review Workflows

**Files:**
- Modify: `lib/cympho_web/live/approval_live/index.html.heex`
- Modify: `lib/cympho_web/live/review_queue_live/index.html.heex`
- Modify: `test/cympho_web/live/approval_live_test.exs`
- Modify: `test/cympho_web/live/review_queue_live_test.exs`
- Modify: `docs/verification/page-flattening.md`

- [ ] **Step 1: Add failing workflow structure tests**

Assert one queue summary band, one repeated decision list, and no evidence card nested inside decision card nested inside queue panel.

- [ ] **Step 2: Run and verify RED**

```bash
mix test test/cympho_web/live/approval_live_test.exs test/cympho_web/live/review_queue_live_test.exs
```

- [ ] **Step 3: Migrate approvals**

- Queue counts → instrument band.
- Approval records → divided list with visible status, requester, linked issue, and actions.
- Approve/Deny retain visible text and icons because they are consequential.
- Payload detail remains advanced disclosure.

- [ ] **Step 4: Migrate reviews**

- Lanes remain semantic sections without outer nested panels.
- Gate/evidence details become flat rows or disclosure.
- Approve/Request changes remain visible text actions.

- [ ] **Step 5: Run tests/browser and commit**

```bash
mix test test/cympho_web/live/approval_live_test.exs test/cympho_web/live/review_queue_live_test.exs
Invoke `/verify` and drive the page-flattening scenarios matching `approval|review`
git add lib/cympho_web/live/approval_live/index.html.heex lib/cympho_web/live/review_queue_live/index.html.heex test/cympho_web/live/approval_live_test.exs test/cympho_web/live/review_queue_live_test.exs docs/verification/page-flattening.md
git commit -m "feat: flatten governance queues"
```

### Task 10: Sweep Remaining Pages

**Files:**
- Modify as identified by audit: `lib/cympho_web/live/company_live/**`, `workspace_live/**`, `plugin_live/**`, `skill_live/**`, `routine_live/**`, `secrets_live/**`, `adapter_live/**`, import/export pages.
- Modify corresponding tests.
- Modify `docs/verification/page-flattening.md`.

- [ ] **Step 1: Generate a remaining density report**

Run:

```bash
for f in $(find lib/cympho_web/live -type f \( -name '*.heex' -o -name '*.ex' \)); do
  cards=$(rg -o 'rounded-(xl|2xl|lg)|<\.panel|<\.card|border border-(border|hairline)' "$f" 2>/dev/null | wc -l | tr -d ' ')
  [ "$cards" -ge 8 ] && printf '%3d %s\n' "$cards" "$f"
done | sort -rn
```

Create a checklist of files still above threshold after Tasks 2–9. Exclude repeated-record cards that are semantically justified.

- [ ] **Step 2: Write one failing structure assertion per page family**

Use the relevant existing LiveView test file. Assert the target archetype ID and absence of the specific nested pattern being removed.

- [ ] **Step 3: Migrate in small commits by family**

Families:

1. Companies/workspaces
2. Plugins/skills/adapters/secrets
3. Routines
4. Import/export and utility pages

For each family run focused tests and a browser viewport check before committing.

- [ ] **Step 4: Re-run density report**

Expected: remaining high counts correspond to long repeated-record templates or intentionally complex operational pages, not nested section shells.

- [ ] **Step 5: Commit each family**

Example:

```bash
git add lib/cympho_web/live/company_live lib/cympho_web/live/workspace_live test/cympho_web/live/company_live_test.exs test/cympho_web/live/workspace_live_test.exs
git commit -m "feat: flatten company and workspace pages"
```

### Task 11: Full Visual and Accessibility Acceptance

**Files:**
- Modify: `docs/verification/page-flattening.md`
- Create: `docs/verification/page-flattening.md`

- [ ] **Step 1: Add route matrix**

```javascript
const routes = [
  "/dashboard",
  "/operations",
  "/issues",
  "/kanban",
  "/agents",
  "/agents/new",
  "/projects",
  "/projects/new",
  "/goals",
  "/goals/new",
  "/approvals",
  "/reviews",
  "/costs",
  "/tool-call-traces",
  "/settings/integrations"
]
```

For seeded dynamic detail routes, resolve IDs through a fixture endpoint or setup helper.

- [ ] **Step 2: Verify both modes and viewports**

For every route at 1440×900 and 390×844:

- No accidental document-level horizontal overflow.
- Primary heading and action visible.
- No clipped popover.
- Simple mode retains primary workflow.
- Advanced mode shows expert controls.
- Icon-only actions have accessible names/tooltips.

- [ ] **Step 3: Run accessibility checks**

Use browser accessibility snapshots and keyboard traversal for:

- Forms
- Toolbars
- Confirmation dialog
- Popovers
- Issue detail
- Kanban controls

Verify focus visibility, logical tab order, dialog focus trap, and no unlabeled icon button.

- [ ] **Step 4: Write verification record**

```markdown
# Page Flattening Verification

## Interaction foundations
- [x] Anchored popovers
- [x] Styled confirmations
- [x] Icon tooltips

## Archetypes
- [x] Operational consoles
- [x] Editorial details
- [x] Calm forms

## Modes and responsiveness
- [x] Compact/simple primary flows
- [x] Advanced diagnostics
- [x] Desktop
- [x] Mobile
- [x] Reduced motion
```

- [ ] **Step 5: Run final gate**

```bash
mix format
mix compile --warnings-as-errors
mix tailwind cympho
mix esbuild cympho
mix test
Invoke `/verify` for all scenarios recorded in `docs/verification/interaction-foundations.md`, `docs/verification/issue-workflow-redesign.md`, and `docs/verification/page-flattening.md`.
git diff --check
```

Expected: all commands exit 0 and all suites report 0 failures.

- [ ] **Step 6: Commit**

```bash
git add docs/verification/page-flattening.md
git commit -m "test: verify adaptive flat UI redesign"
```
