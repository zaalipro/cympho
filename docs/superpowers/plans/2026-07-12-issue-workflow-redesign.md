# Issue Workflow Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign issue detail into an editorial workspace with a quiet context rail, icon-driven comment tools, and a dispatch-queue action that opens a visibly and actually filtered queue.

**Architecture:** Keep `IssueLive.Show` as the state owner and preserve existing events. Refactor presentation through existing focused components (`Header`, `Description`, `ExecutionBrief`, `Comments`, `Sidebar`) and a small set of shared flat-layout components. Queue filtering remains server-side in `Issues.list_issues_paginated/1`; the URL adds an explicit `queue=dispatch` presentation hint and queued status set.

**Tech Stack:** Phoenix LiveView, HEEx function components, Ecto query composition, Tailwind CSS, ExUnit LiveView tests, Playwright browser verification.

---

## File Structure

- Modify `lib/cympho_web/live/issue_live/show.html.heex` — editorial page layout and section order.
- Modify `lib/cympho_web/live/issue_live/components/header.ex` — identity header and icon actions.
- Modify `lib/cympho_web/live/issue_live/components/description.ex` — unframed description/repair band.
- Modify `lib/cympho_web/live/issue_live/components/execution_brief.ex` — flatten healthy diagnostics and warning boundaries.
- Modify `lib/cympho_web/live/issue_live/components/comments.ex` — icon template toolbar and dominant composer.
- Modify `lib/cympho_web/live/issue_live/components/sidebar.ex` — compact context rows and critical blocker band.
- Modify `lib/cympho_web/live/issue_live/index.ex` — dispatch queue params/assigns and clear behavior.
- Modify `lib/cympho_web/live/issue_live/index.html.heex` — queue heading, persistent chip, result count, empty state.
- Modify `lib/cympho_web/live/agent_live/show.ex` — dispatch URL includes queue/status semantics.
- Modify `lib/cympho/issues.ex` — queued-status filtering using one domain helper.
- Modify `lib/cympho_web/components.ex` — shared `flat_section/1`, `context_row/1`, `warning_band/1`, and `instrument_band/1` if not delivered by the page-flattening plan first.
- Modify `test/cympho_web/live/issue_live_test.exs` — detail and queue behavior.
- Modify `test/cympho_web/live/issue_live/index_filter_test.exs` — query filtering.
- Modify `test/cympho_web/live/agent_live_test.exs` — dispatch action URL.
- Create `docs/verification/issue-workflow-redesign.md` — responsive visual/interaction acceptance.

### Task 1: Define Dispatch Queue Domain Semantics

**Files:**
- Modify: `lib/cympho/issues.ex:373-450`
- Modify: `test/cympho_web/live/issue_live/index_filter_test.exs`

- [ ] **Step 1: Write failing queue filter test**

```elixir
test "dispatch queue filters to queued statuses for one assignee", %{company: company} do
  agent = agent_fixture(company_id: company.id)
  queued = issue_fixture(company_id: company.id, assignee_id: agent.id, status: :todo)
  review = issue_fixture(company_id: company.id, assignee_id: agent.id, status: :in_review)
  active = issue_fixture(company_id: company.id, assignee_id: agent.id, status: :in_progress)
  other = issue_fixture(company_id: company.id, status: :todo)

  result = Issues.list_issues_paginated(%{
    "company_id" => company.id,
    "assignee_id" => agent.id,
    "queue" => "dispatch"
  })

  ids = Enum.map(result.issues, & &1.id)
  assert queued.id in ids
  assert review.id in ids
  refute active.id in ids
  refute other.id in ids
end
```

Use the project’s actual dispatchable queued status definition; if `:in_review` is not queue-eligible, adjust the fixture/assertion to the existing domain rule rather than inventing a new one.

- [ ] **Step 2: Run test and verify RED**

Run: `mix test test/cympho_web/live/issue_live/index_filter_test.exs --trace`

Expected: FAIL because `queue=dispatch` is ignored.

- [ ] **Step 3: Add one public queue-status helper**

```elixir
@dispatch_queue_statuses [:backlog, :todo, :in_review]

def dispatch_queue_statuses, do: @dispatch_queue_statuses
```

Place it near existing dispatch eligibility helpers. Reuse an existing helper if one already expresses this exact set.

- [ ] **Step 4: Apply queue filter in pagination query**

```elixir
queue = Map.get(params, "queue")

query
|> maybe_filter_by_assignee(assignee_id)
|> maybe_filter_dispatch_queue(queue)
```

```elixir
defp maybe_filter_dispatch_queue(query, "dispatch") do
  where(query, [i], i.status in ^dispatch_queue_statuses())
end

defp maybe_filter_dispatch_queue(query, _), do: query
```

- [ ] **Step 5: Run filter tests**

Run: `mix test test/cympho_web/live/issue_live/index_filter_test.exs`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/cympho/issues.ex test/cympho_web/live/issue_live/index_filter_test.exs
git commit -m "feat: add agent dispatch queue filtering"
```

### Task 2: Make Agent Dispatch Action Explicit

**Files:**
- Modify: `lib/cympho_web/live/agent_live/show.ex:1767-1774,1932`
- Modify: `test/cympho_web/live/agent_live_test.exs`

- [ ] **Step 1: Write failing URL assertion**

```elixir
test "dispatch queue action links to the agent's filtered queue", %{conn: conn, company: company} do
  agent = agent_fixture(company_id: company.id)
  _issue = issue_fixture(company_id: company.id, assignee_id: agent.id, status: :todo)

  {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}")

  assert html =~ ~s(href="/issues?assignee_id=#{agent.id}&amp;queue=dispatch")
  assert html =~ "Dispatch queue"
end
```

Use URI-order-insensitive parsing if `URI.encode_query/1` does not guarantee the asserted order.

- [ ] **Step 2: Run test and verify RED**

Run: `mix test test/cympho_web/live/agent_live_test.exs --trace`

Expected: FAIL because the URL lacks `queue=dispatch`.

- [ ] **Step 3: Update action path**

```elixir
path: issue_query_path(%{assignee_id: agent.id, queue: "dispatch"})
```

- [ ] **Step 4: Run agent tests**

Run: `mix test test/cympho_web/live/agent_live_test.exs`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cympho_web/live/agent_live/show.ex test/cympho_web/live/agent_live_test.exs
git commit -m "fix: link agents to their dispatch queue"
```

### Task 3: Expose Queue State on Issues Index

**Files:**
- Modify: `lib/cympho_web/live/issue_live/index.ex:37-74,180-260`
- Modify: `lib/cympho_web/live/issue_live/index.html.heex:1-280`
- Modify: `test/cympho_web/live/issue_live/index_filter_test.exs`

- [ ] **Step 1: Write failing LiveView presentation tests**

```elixir
test "shows active dispatch queue context", %{conn: conn, company: company} do
  agent = agent_fixture(company_id: company.id, name: "Ada Runtime")
  _issue = issue_fixture(company_id: company.id, assignee_id: agent.id, status: :todo)

  {:ok, view, html} = live(conn, ~p"/issues?assignee_id=#{agent.id}&queue=dispatch")

  assert html =~ "Ada Runtime dispatch queue"
  assert has_element?(view, "[data-testid='dispatch-queue-filter']", "Ada Runtime")
  assert has_element?(view, "[data-testid='dispatch-queue-count']")
  assert has_element?(view, "[data-testid='clear-dispatch-queue']")
end

test "shows agent-specific empty dispatch state", %{conn: conn, company: company} do
  agent = agent_fixture(company_id: company.id, name: "Ada Runtime")

  {:ok, _view, html} = live(conn, ~p"/issues?assignee_id=#{agent.id}&queue=dispatch")

  assert html =~ "Ada Runtime has no queued dispatch work"
end
```

- [ ] **Step 2: Run tests and verify RED**

Run: `mix test test/cympho_web/live/issue_live/index_filter_test.exs --trace`

Expected: FAIL because queue context is not assigned/rendered.

- [ ] **Step 3: Add queue assigns**

In `handle_params/3`:

```elixir
queue = normalize_queue(params["queue"])
queue_agent = queue_agent(socket, queue, params["assignee_id"])

socket
|> assign(:current_queue, queue)
|> assign(:queue_agent, queue_agent)
```

```elixir
defp normalize_queue("dispatch"), do: "dispatch"
defp normalize_queue(_), do: nil

defp queue_agent(socket, "dispatch", assignee_id) when is_binary(assignee_id) do
  Enum.find(socket.assigns.all_agents, &(&1.id == assignee_id))
end

defp queue_agent(_, _, _), do: nil
```

Preserve `queue` in `build_url/2` unless explicitly cleared.

- [ ] **Step 4: Render dispatch queue header and chip**

```heex
<%= if @current_queue == "dispatch" && @queue_agent do %>
  <div class="mb-5 flex flex-wrap items-center justify-between gap-3">
    <div>
      <p class="ember-eyebrow">Dispatch queue</p>
      <h1 class="font-serif text-headline text-ink">{@queue_agent.name} dispatch queue</h1>
      <p class="mt-1 text-body-sm text-ink-subtle">Queued work currently eligible for this agent.</p>
    </div>
    <div class="flex items-center gap-2" data-testid="dispatch-queue-filter">
      <span class="...">{@queue_agent.name}</span>
      <span data-testid="dispatch-queue-count" class="font-mono tabular-nums">{@total}</span>
      <.icon_button
        icon="hero-x-mark-mini"
        label="Clear dispatch queue filter"
        patch={~p"/issues"}
        data-testid="clear-dispatch-queue"
      />
    </div>
  </div>
<% else %>
  <%!-- existing All Issues header --%>
<% end %>
```

If `icon_button/1` only renders buttons, add `navigate`/`patch` variants or use an accessible icon link primitive.

- [ ] **Step 5: Add queue-specific empty state**

```heex
<.empty_state
  :if={@issues == [] && @current_queue == "dispatch" && @queue_agent}
  title={"#{@queue_agent.name} has no queued dispatch work"}
  message="Queued work will appear here when this agent is assigned backlog, ready, or review work."
>
  <:actions>
    <.app_link navigate={~p"/issues/new?assignee_id=#{@queue_agent.id}"}>Create assigned issue</.app_link>
  </:actions>
</.empty_state>
```

- [ ] **Step 6: Run focused tests**

Run: `mix test test/cympho_web/live/issue_live/index_filter_test.exs test/cympho_web/live/issue_live_test.exs`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/cympho_web/live/issue_live/index.ex lib/cympho_web/live/issue_live/index.html.heex test/cympho_web/live/issue_live/index_filter_test.exs
git commit -m "feat: show explicit dispatch queue context"
```

### Task 4: Add Flat Layout Primitives

**Files:**
- Modify: `lib/cympho_web/components.ex`
- Create: `test/cympho_web/components/flat_layout_test.exs`
- Modify: `assets/css/app.css`

- [ ] **Step 1: Write failing component tests**

```elixir
defmodule CymphoWeb.Components.FlatLayoutTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  test "flat section renders without panel classes" do
    html = render_component(&CymphoWeb.Components.flat_section/1, %{title: "Evidence", inner_block: [%{inner_block: fn _, _ -> "Body" end}]})
    assert html =~ "Evidence"
    refute html =~ "shadow-card"
    refute html =~ "bg-panel"
  end

  test "context row exposes label and value" do
    html = render_component(&CymphoWeb.Components.context_row/1, %{label: "Priority", inner_block: [%{inner_block: fn _, _ -> "High" end}]})
    assert html =~ "Priority"
    assert html =~ "High"
  end
end
```

Adapt slot construction to the project’s existing component test helpers.

- [ ] **Step 2: Run tests and verify RED**

Run: `mix test test/cympho_web/components/flat_layout_test.exs`

Expected: FAIL because components do not exist.

- [ ] **Step 3: Implement primitives**

```elixir
attr :title, :string, default: nil
attr :description, :string, default: nil
attr :class, :any, default: nil
slot :actions
slot :inner_block, required: true

def flat_section(assigns) do
  ~H"""
  <section class={["flat-section", @class]}>
    <header :if={@title || @description || @actions != []} class="mb-4 flex items-start justify-between gap-4">
      <div>
        <h2 :if={@title} class="text-card-title text-ink">{@title}</h2>
        <p :if={@description} class="mt-1 text-body-sm text-ink-subtle">{@description}</p>
      </div>
      <div :if={@actions != []}>{render_slot(@actions)}</div>
    </header>
    {render_slot(@inner_block)}
  </section>
  """
end

attr :label, :string, required: true
attr :icon, :string, default: nil
slot :inner_block, required: true

def context_row(assigns) do
  ~H"""
  <div class="context-row">
    <span class={[@icon, @icon && "h-4 w-4 text-ink-tertiary"]}></span>
    <span class="text-eyebrow uppercase text-ink-tertiary">{@label}</span>
    <div class="ml-auto min-w-0 text-right text-body-sm text-ink">{render_slot(@inner_block)}</div>
  </div>
  """
end
```

Add `warning_band/1` and `instrument_band/1` with the same no-nested-card principle.

- [ ] **Step 4: Add restrained CSS**

```css
.flat-section { padding-block: 1.5rem; }
.flat-section + .flat-section { border-top: 1px solid var(--color-hairline); }
.context-row { display: flex; min-height: 2.75rem; align-items: center; gap: 0.75rem; border-bottom: 1px solid var(--color-hairline); }
.context-row:last-child { border-bottom: 0; }
.warning-band { border-left: 2px solid var(--color-warning); background: rgb(var(--color-warning-rgb) / 0.06); }
```

- [ ] **Step 5: Run tests/build**

```bash
mix test test/cympho_web/components/flat_layout_test.exs
mix tailwind cympho
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/cympho_web/components.ex assets/css/app.css test/cympho_web/components/flat_layout_test.exs
git commit -m "feat: add flat workspace layout primitives"
```

### Task 5: Redesign Issue Header and Description

**Files:**
- Modify: `lib/cympho_web/live/issue_live/components/header.ex`
- Modify: `lib/cympho_web/live/issue_live/components/description.ex`
- Modify: `lib/cympho_web/live/issue_live/show.html.heex`
- Modify: `test/cympho_web/live/issue_live_test.exs`

- [ ] **Step 1: Write failing structural tests**

```elixir
test "issue detail uses editorial workspace structure", %{conn: conn, issue: issue} do
  {:ok, view, html} = live(conn, ~p"/issues/#{issue.id}")

  assert has_element?(view, "#issue-editorial-header")
  assert has_element?(view, "#issue-main-workspace")
  assert has_element?(view, "#issue-context-rail")
  refute html =~ ~s(id="issue-description" class="rounded-xl border)
end
```

- [ ] **Step 2: Run test and verify RED**

Run: `mix test test/cympho_web/live/issue_live_test.exs --trace`

Expected: FAIL on missing IDs/old framed description.

- [ ] **Step 3: Restructure top-level layout**

```heex
<div id="issue-show" data-ui-complex-page class="min-h-screen bg-canvas">
  <CymphoWeb.IssueLive.Show.Header.header ... />
  <div class="mx-auto grid w-full max-w-[1600px] lg:grid-cols-[minmax(0,1fr)_320px]">
    <main id="issue-main-workspace" class="min-w-0 px-4 py-6 lg:px-8">
      ...
    </main>
    <CymphoWeb.IssueLive.Show.Sidebar.sidebar ... />
  </div>
</div>
```

The runtime top bar remains outside or above this content grid.

- [ ] **Step 4: Flatten header**

Use:

```heex
<header id="issue-editorial-header" class="border-b border-hairline px-4 py-5 lg:px-8">
  <nav class="mb-5 flex items-center gap-2 text-caption text-ink-tertiary">...</nav>
  <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
    <div class="min-w-0">
      <h1 class="font-serif text-[clamp(2rem,3vw,3rem)] leading-tight text-ink">{@issue.title}</h1>
      <div class="mt-3 flex items-center gap-2">status/priority indicators</div>
    </div>
    <div class="flex items-center gap-2">icon actions / primary action</div>
  </div>
</header>
```

- [ ] **Step 5: Flatten description and repair state**

Healthy description:

```heex
<.flat_section title="Description" class="pt-0">
  <div class="prose-cympho max-w-none">...</div>
</.flat_section>
```

Missing delivery signals:

```heex
<.warning_band
  id="delivery-brief-repair"
  title="Delivery brief needs completion"
  icon="hero-exclamation-triangle-mini"
>
  <p>...</p>
  <div class="mt-3 flex items-center gap-2">Copy scaffold / Use scaffold</div>
  <pre class="mt-4 overflow-x-auto rounded-lg bg-surface-1 p-4 font-mono text-caption">...</pre>
</.warning_band>
```

- [ ] **Step 6: Run issue tests**

Run: `mix test test/cympho_web/live/issue_live_test.exs`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/cympho_web/live/issue_live/show.html.heex lib/cympho_web/live/issue_live/components/header.ex lib/cympho_web/live/issue_live/components/description.ex test/cympho_web/live/issue_live_test.exs
git commit -m "feat: redesign issue detail workspace"
```

### Task 6: Flatten Execution Brief and Context Rail

**Files:**
- Modify: `lib/cympho_web/live/issue_live/components/execution_brief.ex`
- Modify: `lib/cympho_web/live/issue_live/components/sidebar.ex`
- Modify: `test/cympho_web/live/issue_live_test.exs`

- [ ] **Step 1: Write failing rail/brief tests**

```elixir
test "issue context rail uses compact rows and one critical blocker band", %{conn: conn, issue: issue} do
  {:ok, view, html} = live(conn, ~p"/issues/#{issue.id}")

  assert has_element?(view, "#issue-context-rail .context-row")
  assert has_element?(view, "#issue-context-rail [data-critical-blocker]")
  refute html =~ ~r/id="issue-context-rail"[\s\S]*shadow-card[\s\S]*shadow-card/
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mix test test/cympho_web/live/issue_live_test.exs --trace`

Expected: FAIL on old stacked panel structure.

- [ ] **Step 3: Convert execution brief to flat sections**

Map each current major block to:

- Readiness summary → instrument band
- Runs/evidence → flat section with rows
- Child health → repeated record cards only when each child is independently actionable
- Raw diagnostics → advanced-only disclosure

Do not change existing event names, assigns, or IDs used by tests.

- [ ] **Step 4: Convert sidebar controls to context rows**

```heex
<aside id="issue-context-rail" class="border-l border-hairline px-5 py-6 lg:sticky lg:top-0 lg:h-[calc(100dvh-var(--runtime-bar-height,0px))] lg:overflow-y-auto">
  <.context_row label="Status" icon="hero-signal-mini">status select</.context_row>
  <.context_row label="Priority" icon="hero-flag-mini">priority select</.context_row>
  <.context_row label="Assignee" icon="hero-user-mini">assignee select</.context_row>
  <.context_row label="Due" icon="hero-calendar-mini">date control</.context_row>
  ...
</aside>
```

Critical blocker:

```heex
<.warning_band data-critical-blocker title="Provider credentials required" icon="hero-key-mini" tone="warning">
  ...
</.warning_band>
```

Non-critical setup item:

```heex
<div class="flex gap-3 py-4 border-b border-hairline">
  <span class="hero-information-circle-mini ..."></span>
  <div>heading, short text, inline action</div>
</div>
```

- [ ] **Step 5: Run issue tests**

Run: `mix test test/cympho_web/live/issue_live_test.exs`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/cympho_web/live/issue_live/components/execution_brief.ex lib/cympho_web/live/issue_live/components/sidebar.ex test/cympho_web/live/issue_live_test.exs
git commit -m "feat: flatten issue diagnostics and context rail"
```

### Task 7: Redesign Comment Composer with Icon Tools

**Files:**
- Modify: `lib/cympho_web/live/issue_live/components/comments.ex`
- Modify: `test/cympho_web/live/issue_live_test.exs`
- Modify: `docs/verification/issue-workflow-redesign.md`

- [ ] **Step 1: Write failing composer tests**

```elixir
test "comment templates render as accessible icon tools", %{conn: conn, issue: issue} do
  {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")

  assert has_element?(view, "#issue-comment-tools [data-tooltip='Owner update']")
  assert has_element?(view, "#issue-comment-tools [aria-label='Delivery update']")
  assert has_element?(view, "#issue-comment-composer textarea")
  assert has_element?(view, "#issue-comment-composer button[type='submit']")
end
```

- [ ] **Step 2: Run and verify RED**

Run: `mix test test/cympho_web/live/issue_live_test.exs --trace`

Expected: FAIL because the existing template controls are text pills.

- [ ] **Step 3: Map templates to icons**

In `comments.ex`:

```elixir
defp template_icon("owner_update"), do: "hero-user-circle-mini"
defp template_icon("delivery"), do: "hero-rocket-launch-mini"
defp template_icon("review"), do: "hero-check-badge-mini"
defp template_icon("blocked"), do: "hero-no-symbol-mini"
defp template_icon("handoff"), do: "hero-arrow-right-circle-mini"
```

Use exact keys from `comment_templates/0`; do not rename events.

- [ ] **Step 4: Render icon toolbar and dominant composer**

```heex
<section id="issue-comments" class="flat-section border-t border-hairline pt-6">
  <div id="issue-comment-tools" class="mb-3 flex flex-wrap items-center gap-1.5">
    <.icon_button
      :for={template <- @comment_templates}
      icon={template_icon(template.key)}
      label={template.label}
      phx-click="use_comment_template"
      phx-value-template={template.key}
    />
  </div>
  <.form for={@comment_form} id="issue-comment-composer" phx-submit="add_comment" class="flex items-end gap-3">
    <textarea ... class="min-h-24 flex-1 ..."></textarea>
    <button type="submit" class="cta-glow ...">
      <span class="hero-paper-airplane-mini h-4 w-4"></span>
      <span class="hidden sm:inline">Send</span>
    </button>
  </.form>
</section>
```

- [ ] **Step 5: Add browser tooltip/template test**

```javascript
test("comment template icon shows tooltip and fills composer", async ({page}) => {
  await page.goto("/issues/<fixture-id>")
  const tool = page.getByRole("button", {name: "Owner update"})
  await tool.hover()
  await expect(page.locator("#cympho-tooltip")).toContainText("Owner update")
  await tool.click()
  await expect(page.locator("#issue-comment-composer textarea")).not.toHaveValue("")
})
```

- [ ] **Step 6: Run tests**

```bash
mix test test/cympho_web/live/issue_live_test.exs
Invoke `/verify` and drive the issue-workflow scenario matching `comment template`.
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/cympho_web/live/issue_live/components/comments.ex test/cympho_web/live/issue_live_test.exs docs/verification/issue-workflow-redesign.md
git commit -m "feat: add icon-driven issue comment tools"
```

### Task 8: Issue Workflow Responsive Acceptance

**Files:**
- Modify: `docs/verification/issue-workflow-redesign.md`
- Create: `docs/verification/issue-workflow-redesign.md`

- [ ] **Step 1: Add desktop and mobile assertions**

```javascript
for (const viewport of [
  {name: "desktop", width: 1440, height: 900},
  {name: "mobile", width: 390, height: 844}
]) {
  test(`${viewport.name} issue workspace does not overlap`, async ({page}) => {
    await page.setViewportSize(viewport)
    await page.goto("/issues/<fixture-id>")
    await expect(page.locator("#issue-main-workspace")).toBeVisible()
    await expect(page.locator("#issue-context-rail")).toBeVisible()
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth)
    expect(overflow).toBe(false)
  })
}
```

Add screenshot assertions or saved reference images for the repaired issue and a healthy issue.

- [ ] **Step 2: Verify simple and advanced modes**

Use localStorage `cympho-ui-mode` and reload. Assert primary comment/status workflows are visible in both; diagnostics only in advanced.

- [ ] **Step 3: Verify dispatch queue end-to-end**

Navigate from agent detail via the visible Dispatch Queue action. Assert URL params, agent heading, matching rows only, count, and clear behavior.

- [ ] **Step 4: Run acceptance and full tests**

```bash
Invoke `/verify` and drive every scenario in `docs/verification/issue-workflow-redesign.md`.
mix format
mix compile --warnings-as-errors
mix tailwind cympho
mix esbuild cympho
mix test
git diff --check
```

Expected: all commands exit 0; full suite has 0 failures.

- [ ] **Step 5: Document and commit**

```markdown
# Issue Workflow Redesign Verification

- [x] Editorial header and unboxed description
- [x] Repair warning is one boundary
- [x] Quiet sticky context rail
- [x] Icon comment tools with tooltips
- [x] Dispatch queue filters server-side
- [x] Empty queue is agent-specific
- [x] Simple and advanced modes preserve primary workflow
- [x] Desktop/mobile no horizontal overflow
```

```bash
git add docs/verification/issue-workflow-redesign.md docs/verification/issue-workflow-redesign.md
git commit -m "test: verify issue workflow redesign"
```
