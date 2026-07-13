# Interaction Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build reliable viewport-anchored popovers, a styled global confirmation dialog, and accessible icon-button/tooltips without changing existing business actions.

**Architecture:** Keep Phoenix component markup declarative and implement browser behavior in focused JavaScript modules imported by `assets/js/app.js`. Popover placement is a pure geometry function; select menus, date/time pickers, and tooltips share it. Confirmation intercepts capture-phase click/submit events, opens one root-layout dialog, then replays the original action once through a guard.

**Tech Stack:** Phoenix 1.8, Phoenix LiveView, Phoenix.Component/HEEx, vanilla ES modules, Tailwind CSS, ExUnit component tests, Playwright browser verification.

---

## File Structure

- Create `assets/js/ui/popover_position.js` — pure placement calculation; no DOM ownership.
- Create `assets/js/ui/tooltip.js` — delegated tooltip controller using the placement module.
- Create `assets/js/ui/confirm_dialog.js` — capture-phase confirmation interception and action replay.
- Modify `assets/js/app.js` — import/initialize modules; make select/date controls use shared placement.
- Modify `lib/cympho_web/components.ex` — icon button and tooltip-trigger markup contracts; select popover attributes.
- Modify `lib/cympho_web/controllers/layouts/root.html.heex` — global confirmation dialog and tooltip overlay roots.
- Modify `assets/css/app.css` — overlay, popover, tooltip, dialog, and icon-button styles.
- Create `test/cympho_web/components/icon_button_test.exs` — markup/accessibility contract.
- Create `test/cympho_web/components/confirm_dialog_test.exs` — root dialog contract.
- Modify `test/cympho_web/components/select_menu_test.exs` — anchored-popover attributes and ARIA contract.
- Create `test/js/popover_position_test.js` — pure geometry tests using Node's built-in test runner.
- Create `docs/verification/interaction-foundations.md` — live browser cases driven through the project’s `/verify` workflow.

### Task 1: Extract Pure Popover Placement

**Files:**
- Create: `assets/js/ui/popover_position.js`
- Create: `test/js/popover_position_test.js`
- Create: `docs/verification/interaction-foundations.md`

- [ ] **Step 1: Write pure placement tests**

```javascript
import assert from "node:assert/strict"
import test from "node:test"
import {calculatePopoverPosition} from "../../assets/js/ui/popover_position.js"

const cases = [
  {
    name: "opens below when it fits",
    input: {
      trigger: {left: 100, top: 100, right: 300, bottom: 140, width: 200, height: 40},
      popover: {width: 200, height: 180},
      viewport: {width: 1200, height: 800},
      margin: 8,
      gap: 6
    },
    expected: {placement: "bottom", left: 100, top: 146, maxHeight: 646}
  },
  {
    name: "opens above near the bottom",
    input: {
      trigger: {left: 100, top: 700, right: 300, bottom: 740, width: 200, height: 40},
      popover: {width: 200, height: 220},
      viewport: {width: 1200, height: 800},
      margin: 8,
      gap: 6
    },
    expected: {placement: "top", left: 100, top: 474, maxHeight: 686}
  },
  {
    name: "clamps to the right viewport edge",
    input: {
      trigger: {left: 1100, top: 100, right: 1180, bottom: 140, width: 80, height: 40},
      popover: {width: 260, height: 180},
      viewport: {width: 1200, height: 800},
      margin: 8,
      gap: 6
    },
    expected: {placement: "bottom", left: 932, top: 146, maxHeight: 646}
  }
]

for (const scenario of cases) {
  test(scenario.name, () => {
    assert.deepEqual(calculatePopoverPosition(scenario.input), scenario.expected)
  })
}
```

- [ ] **Step 2: Run the placement tests and verify RED**

Run: `node --test --experimental-default-type=module test/js/popover_position_test.js`

Expected: FAIL because `assets/js/ui/popover_position.js` does not exist.

- [ ] **Step 3: Implement the pure placement function**

```javascript
export function calculatePopoverPosition({trigger, popover, viewport, margin = 8, gap = 6}) {
  const below = viewport.height - trigger.bottom - margin - gap
  const above = trigger.top - margin - gap
  const placement = popover.height <= below || below >= above ? "bottom" : "top"
  const maxHeight = Math.max(120, placement === "bottom" ? below : above)
  const renderedHeight = Math.min(popover.height, maxHeight)
  const unclampedTop = placement === "bottom"
    ? trigger.bottom + gap
    : trigger.top - gap - renderedHeight
  const maxLeft = viewport.width - margin - popover.width

  return {
    placement,
    left: Math.round(Math.max(margin, Math.min(trigger.left, maxLeft))),
    top: Math.round(Math.max(margin, Math.min(unclampedTop, viewport.height - margin - renderedHeight))),
    maxHeight: Math.round(maxHeight)
  }
}
```

- [ ] **Step 4: Import the placement function into the browser bundle**

Modify the esbuild configuration or import the function through `assets/js/app.js`:

```javascript
import {calculatePopoverPosition} from "./ui/popover_position"
window.CymphoUI = {...(window.CymphoUI || {}), calculatePopoverPosition}
```

The `window.CymphoUI` export is a browser-verification seam; production controls call the imported function directly.

- [ ] **Step 5: Run placement tests and asset build**

Run:

```bash
node --test --experimental-default-type=module test/js/popover_position_test.js
mix esbuild cympho
```

Expected: PASS for all three geometry cases.

- [ ] **Step 6: Commit**

```bash
git add assets/js/ui/popover_position.js assets/js/app.js test/js/popover_position_test.js docs/verification/interaction-foundations.md
git commit -m "feat: add viewport-aware popover placement"
```

### Task 2: Migrate Select and Date/Time Popovers

**Files:**
- Modify: `assets/js/app.js:1128-1240`
- Modify: `assets/js/app.js` date/time picker positioning functions
- Modify: `lib/cympho_web/components.ex:711-792`
- Modify: `test/cympho_web/components/select_menu_test.exs`
- Modify: `docs/verification/interaction-foundations.md`

- [ ] **Step 1: Add failing component assertions**

```elixir
test "renders an anchored listbox owned by its trigger" do
  html = render_select(name: "status", value: "todo", options: [{"To Do", "todo"}])

  assert html =~ ~s(data-select-trigger)
  assert html =~ ~s(aria-controls="select-status-popover")
  assert html =~ ~s(id="select-status-popover")
  assert html =~ ~s(data-popover-placement)
end
```

- [ ] **Step 2: Run component test and verify RED**

Run: `mix test test/cympho_web/components/select_menu_test.exs`

Expected: FAIL on missing popover ID/`aria-controls`/placement attribute.

- [ ] **Step 3: Add stable select IDs and ARIA ownership**

In `select_menu/1`, derive IDs:

```elixir
base_id = assigns.id || "select-#{Phoenix.HTML.Form.normalize_value("text", assigns.name)}"
assigns =
  assigns
  |> assign(:trigger_id, "#{base_id}-trigger")
  |> assign(:popover_id, "#{base_id}-popover")
```

Render:

```heex
<button
  id={@trigger_id}
  data-select-trigger
  aria-controls={@popover_id}
  aria-expanded="false"
  aria-haspopup="listbox"
>
...
</button>
<div
  id={@popover_id}
  data-select-popover
  data-popover-placement
  role="listbox"
  aria-labelledby={@trigger_id}
>
```

- [ ] **Step 4: Replace heuristic positioning with measured placement**

In `openSelectMenu`:

```javascript
pop.classList.remove("hidden")
pop.style.visibility = "hidden"
pop.style.pointerEvents = "none"
pop.style.position = "fixed"
pop.style.maxHeight = "none"

const triggerRect = trigger.getBoundingClientRect()
const popRect = pop.getBoundingClientRect()
const position = calculatePopoverPosition({
  trigger: triggerRect,
  popover: popRect,
  viewport: {width: window.innerWidth, height: window.innerHeight}
})

Object.assign(pop.style, {
  left: `${position.left}px`,
  top: `${position.top}px`,
  bottom: "auto",
  width: `${Math.round(triggerRect.width)}px`,
  minWidth: `${Math.round(triggerRect.width)}px`,
  visibility: "visible",
  pointerEvents: "auto"
})
list.style.maxHeight = `${position.maxHeight}px`
pop.dataset.placement = position.placement
```

Use the same `positionPopoverElement(trigger, pop, list)` helper for date/time pickers.

- [ ] **Step 5: Add browser regression tests from the supplied screenshots**

```javascript
test("goal parent selector stays attached above near viewport bottom", async ({page}) => {
  await page.goto("/goals")
  await page.setViewportSize({width: 1658, height: 768})
  const trigger = page.locator("[data-select-trigger]").filter({hasText: "No parent goal"})
  await trigger.scrollIntoViewIfNeeded()
  await trigger.click()
  const menu = page.locator("[data-select-popover]:visible")
  const [triggerBox, menuBox] = await Promise.all([trigger.boundingBox(), menu.boundingBox()])
  expect(Math.min(Math.abs(menuBox.y + menuBox.height - triggerBox.y), Math.abs(menuBox.y - (triggerBox.y + triggerBox.height)))).toBeLessThanOrEqual(8)
})

test("project status selector stays aligned at the right edge", async ({page}) => {
  await page.goto("/projects/<fixture-id>")
  await page.setViewportSize({width: 1990, height: 1277})
  const trigger = page.locator("[data-select-trigger]").filter({hasText: /Active|Archived|Select/})
  await trigger.click()
  const menu = page.locator("[data-select-popover]:visible")
  const [triggerBox, menuBox] = await Promise.all([trigger.boundingBox(), menu.boundingBox()])
  expect(Math.abs(menuBox.x - triggerBox.x)).toBeLessThanOrEqual(2)
  expect(menuBox.x + menuBox.width).toBeLessThanOrEqual(1982)
})
```

Use seeded fixture lookup rather than hardcoding IDs in the final test helper.

- [ ] **Step 6: Run component and browser tests**

Run:

```bash
mix test test/cympho_web/components/select_menu_test.exs test/cympho_web/components/date_picker_test.exs
Invoke `/verify` and drive the interaction-foundation scenarios matching `selector`.
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add assets/js/app.js lib/cympho_web/components.ex test/cympho_web/components/select_menu_test.exs docs/verification/interaction-foundations.md
git commit -m "fix: keep popovers anchored to their controls"
```

### Task 3: Add Accessible Tooltip and Icon Button Primitives

**Files:**
- Create: `assets/js/ui/tooltip.js`
- Modify: `assets/js/app.js`
- Modify: `assets/css/app.css`
- Modify: `lib/cympho_web/components.ex`
- Create: `test/cympho_web/components/icon_button_test.exs`
- Modify: `docs/verification/interaction-foundations.md`

- [ ] **Step 1: Write failing icon-button component tests**

```elixir
defmodule CymphoWeb.Components.IconButtonTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  test "renders an accessible icon-only button with tooltip metadata" do
    html = render_component(&CymphoWeb.Components.icon_button/1, %{
      icon: "hero-trash-mini",
      label: "Delete issue",
      tone: "danger"
    })

    assert html =~ ~s(aria-label="Delete issue")
    assert html =~ ~s(data-tooltip="Delete issue")
    assert html =~ ~s(hero-trash-mini)
    refute html =~ ~r/>Delete issue</
  end
end
```

- [ ] **Step 2: Run test and verify RED**

Run: `mix test test/cympho_web/components/icon_button_test.exs`

Expected: FAIL because `icon_button/1` does not exist.

- [ ] **Step 3: Implement `icon_button/1`**

```elixir
attr :icon, :string, required: true
attr :label, :string, required: true
attr :tone, :string, default: "neutral"
attr :size, :string, default: "md"
attr :type, :string, default: "button"
attr :class, :any, default: nil
attr :rest, :global

def icon_button(assigns) do
  ~H"""
  <button
    type={@type}
    aria-label={@label}
    data-tooltip={@label}
    class={["icon-button btn-press", icon_button_tone(@tone), icon_button_size(@size), @class]}
    {@rest}
  >
    <span class={[@icon, "h-4 w-4"]}></span>
  </button>
  """
end
```

Add private tone/size mappings using existing tokens only.

- [ ] **Step 4: Add delegated tooltip controller**

Implement `assets/js/ui/tooltip.js`:

```javascript
export function installTooltips({calculatePopoverPosition}) {
  const overlay = document.getElementById("cympho-tooltip")
  let trigger = null
  let timer = null

  const close = () => {
    clearTimeout(timer)
    if (trigger) trigger.removeAttribute("aria-describedby")
    trigger = null
    overlay.hidden = true
  }

  const open = (next) => {
    close()
    trigger = next
    timer = setTimeout(() => {
      overlay.textContent = next.dataset.tooltip
      overlay.hidden = false
      overlay.style.visibility = "hidden"
      const position = calculatePopoverPosition({
        trigger: next.getBoundingClientRect(),
        popover: overlay.getBoundingClientRect(),
        viewport: {width: innerWidth, height: innerHeight},
        margin: 8,
        gap: 8
      })
      overlay.style.left = `${position.left}px`
      overlay.style.top = `${position.top}px`
      overlay.style.visibility = "visible"
      next.setAttribute("aria-describedby", overlay.id)
    }, 350)
  }

  document.addEventListener("pointerover", (event) => {
    const next = event.target.closest("[data-tooltip]")
    if (next) open(next)
  })
  document.addEventListener("pointerout", (event) => {
    if (event.target.closest("[data-tooltip]")) close()
  })
  document.addEventListener("focusin", (event) => {
    const next = event.target.closest("[data-tooltip]")
    if (next) open(next)
  })
  document.addEventListener("focusout", close)
  document.addEventListener("keydown", (event) => event.key === "Escape" && close())
}
```

- [ ] **Step 5: Add the root tooltip overlay**

In `root.html.heex`:

```heex
<div
  id="cympho-tooltip"
  role="tooltip"
  hidden
  class="cympho-tooltip fixed pointer-events-none"
></div>
```

- [ ] **Step 6: Add tooltip/icon-button CSS**

```css
.icon-button {
  display: inline-flex;
  min-width: 2.25rem;
  min-height: 2.25rem;
  align-items: center;
  justify-content: center;
  border-radius: var(--radius-button);
  color: var(--color-text-tertiary);
}
.icon-button:hover { color: var(--color-text-primary); background: var(--color-surface-hover); }
.cympho-tooltip {
  z-index: 80;
  max-width: 16rem;
  padding: 0.375rem 0.5rem;
  border: 1px solid var(--color-hairline);
  border-radius: 0.5rem;
  background: var(--color-surface-4);
  color: var(--color-ink);
  box-shadow: var(--shadow-elevated);
  font-size: 0.75rem;
}
```

- [ ] **Step 7: Add browser tooltip tests**

```javascript
test("icon tooltip appears on focus and closes on Escape", async ({page}) => {
  await page.goto("/issues")
  const button = page.locator("[data-tooltip]").first()
  await button.focus()
  await expect(page.locator("#cympho-tooltip")).toBeVisible()
  await page.keyboard.press("Escape")
  await expect(page.locator("#cympho-tooltip")).toBeHidden()
})
```

- [ ] **Step 8: Run tests and build**

```bash
mix test test/cympho_web/components/icon_button_test.exs
mix esbuild cympho
mix tailwind cympho
Invoke `/verify` and drive the interaction-foundation scenarios matching `tooltip`.
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add assets/js/ui/tooltip.js assets/js/app.js assets/css/app.css lib/cympho_web/components.ex lib/cympho_web/controllers/layouts/root.html.heex test/cympho_web/components/icon_button_test.exs docs/verification/interaction-foundations.md
git commit -m "feat: add accessible icon tooltips"
```

### Task 4: Replace Native Confirmation Dialogs

**Files:**
- Create: `assets/js/ui/confirm_dialog.js`
- Modify: `assets/js/app.js`
- Modify: `assets/css/app.css`
- Modify: `lib/cympho_web/controllers/layouts/root.html.heex`
- Create: `test/cympho_web/components/confirm_dialog_test.exs`
- Modify: `docs/verification/interaction-foundations.md`

- [ ] **Step 1: Write failing root-dialog contract test**

```elixir
defmodule CymphoWeb.Components.ConfirmDialogTest do
  use CymphoWeb.ConnCase, async: true

  test "root layout contains the global accessible confirmation dialog", %{conn: conn} do
    conn = get(conn, ~p"/login")
    html = html_response(conn, 200)

    assert html =~ ~s(id="cympho-confirm-dialog")
    assert html =~ ~s(role="alertdialog")
    assert html =~ ~s(aria-modal="true")
    assert html =~ ~s(data-confirm-cancel)
    assert html =~ ~s(data-confirm-accept)
  end
end
```

- [ ] **Step 2: Run test and verify RED**

Run: `mix test test/cympho_web/components/confirm_dialog_test.exs`

Expected: FAIL because the dialog is absent.

- [ ] **Step 3: Add dialog markup to authenticated and unauthenticated layouts**

```heex
<div id="cympho-confirm-dialog" class="hidden fixed inset-0 z-[70]" data-confirm-dialog>
  <div class="absolute inset-0 bg-overlay backdrop-blur-sm" data-confirm-cancel></div>
  <section
    role="alertdialog"
    aria-modal="true"
    aria-labelledby="cympho-confirm-title"
    aria-describedby="cympho-confirm-message"
    class="dialog-enter absolute left-1/2 top-1/2 w-[min(32rem,calc(100vw-2rem))] -translate-x-1/2 -translate-y-1/2 rounded-2xl border border-hairline bg-panel p-6 shadow-dialog"
  >
    <div data-confirm-icon class="mb-4"></div>
    <h2 id="cympho-confirm-title" class="text-card-title text-ink">Confirm action</h2>
    <p id="cympho-confirm-message" data-confirm-message class="mt-2 text-body-sm text-ink-subtle"></p>
    <div class="mt-6 flex justify-end gap-2">
      <button type="button" data-confirm-cancel class="btn-press ...">Cancel</button>
      <button type="button" data-confirm-accept class="btn-press ...">Confirm</button>
    </div>
  </section>
</div>
```

Extract to a shared layout component if root and login layout would duplicate it; plain login pages without destructive actions may omit it.

- [ ] **Step 4: Implement capture-phase confirmation controller**

```javascript
export function installConfirmDialog() {
  const dialog = document.querySelector("[data-confirm-dialog]")
  const message = dialog.querySelector("[data-confirm-message]")
  const accept = dialog.querySelector("[data-confirm-accept]")
  const cancels = dialog.querySelectorAll("[data-confirm-cancel]")
  let pending = null
  let invoker = null
  let replaying = false

  const actionable = (event) => event.target.closest("[data-confirm]") || event.target.closest("form[data-confirm]")

  const close = () => {
    dialog.classList.add("hidden")
    document.documentElement.classList.remove("overflow-hidden")
    pending = null
    invoker?.focus()
  }

  const open = (event, target) => {
    event.preventDefault()
    event.stopImmediatePropagation()
    pending = {type: event.type, target}
    invoker = target
    message.textContent = target.dataset.confirm
    accept.textContent = target.dataset.confirmLabel || "Confirm"
    dialog.dataset.tone = target.dataset.confirmTone || (target.matches("[data-danger]") ? "danger" : "neutral")
    dialog.classList.remove("hidden")
    document.documentElement.classList.add("overflow-hidden")
    dialog.dataset.tone === "danger" ? dialog.querySelector("[data-confirm-cancel]").focus() : accept.focus()
  }

  document.addEventListener("click", (event) => {
    if (replaying) return
    const target = actionable(event)
    if (target) open(event, target)
  }, true)

  document.addEventListener("submit", (event) => {
    if (replaying) return
    const target = event.target.closest("form[data-confirm]")
    if (target) open(event, target)
  }, true)

  accept.addEventListener("click", () => {
    const action = pending
    close()
    replaying = true
    if (action.type === "submit") action.target.requestSubmit()
    else action.target.click()
    replaying = false
  })

  cancels.forEach((button) => button.addEventListener("click", close))
}
```

Add Tab trapping and Escape handling before completion.

- [ ] **Step 5: Disable Phoenix HTML’s native confirm listener**

Before importing/initializing `phoenix_html`, install a custom confirm bridge or remove `data-confirm` only during replay so `phoenix_html.js` does not call `window.confirm`. Verify import order in the bundled code. The accepted implementation must satisfy this browser assertion:

```javascript
await page.addInitScript(() => {
  window.confirm = () => { throw new Error("native confirm invoked") }
})
```

- [ ] **Step 6: Add browser tests for link, LiveView click, form, cancel, Escape, and focus return**

```javascript
test("runtime low power uses styled confirmation and replays action", async ({page}) => {
  await page.addInitScript(() => {
    window.confirm = () => { throw new Error("native confirm invoked") }
  })
  await page.goto("/dashboard")
  const trigger = page.getByRole("button", {name: /low power/i})
  await trigger.click()
  await expect(page.locator("#cympho-confirm-dialog")).toBeVisible()
  await expect(page.locator("[data-confirm-message]")).toContainText("Only high and critical")
  await page.locator("[data-confirm-cancel]").last().click()
  await expect(page.locator("#cympho-confirm-dialog")).toBeHidden()
  await expect(trigger).toBeFocused()
})

test("Escape cancels destructive confirmation", async ({page}) => {
  await page.goto("/issues")
  await page.locator("[data-confirm]").first().click()
  await page.keyboard.press("Escape")
  await expect(page.locator("#cympho-confirm-dialog")).toBeHidden()
})
```

Add a focused test that confirms a LiveView `phx-click` event reaches the server exactly once.

- [ ] **Step 7: Run focused tests**

```bash
mix test test/cympho_web/components/confirm_dialog_test.exs
mix esbuild cympho
Invoke `/verify` and drive the interaction-foundation scenarios matching `confirmation|Escape`.
```

Expected: PASS and no `window.confirm` invocation.

- [ ] **Step 8: Audit all confirmation call sites**

Run: `rg -n "data-confirm" lib/cympho_web`

For destructive actions add:

```heex
data-confirm-tone="danger"
data-confirm-label="Delete issue"
```

Do not change the existing `data-confirm` message or action binding.

- [ ] **Step 9: Run broad verification**

```bash
mix format
mix compile --warnings-as-errors
mix test test/cympho_web
mix tailwind cympho
mix esbuild cympho
```

Expected: all commands exit 0.

- [ ] **Step 10: Commit**

```bash
git add assets/js/ui/confirm_dialog.js assets/js/app.js assets/css/app.css lib/cympho_web/controllers/layouts/root.html.heex test/cympho_web/components/confirm_dialog_test.exs docs/verification/interaction-foundations.md lib/cympho_web
git commit -m "feat: replace native confirmations with styled dialog"
```

### Task 5: Interaction Foundations Browser Acceptance

**Files:**
- Modify: `docs/verification/interaction-foundations.md`
- Create: `docs/verification/interaction-foundations.md`

- [ ] **Step 1: Add final acceptance cases**

Cover:

```javascript
const viewports = [
  {name: "desktop", width: 1440, height: 900},
  {name: "small-laptop", width: 1280, height: 720},
  {name: "mobile", width: 390, height: 844}
]
```

For each viewport verify select alignment, tooltip containment, confirmation containment, keyboard Escape, and no overlap beyond 8 px viewport margins.

- [ ] **Step 2: Run acceptance tests**

Run: invoke `/verify` and drive every scenario in `docs/verification/interaction-foundations.md`.

Expected: PASS.

- [ ] **Step 3: Record manual reduced-motion verification**

Create:

```markdown
# Interaction Foundations Verification

- [x] Goal parent select anchored near viewport bottom
- [x] Project status select clamped at right edge
- [x] Date picker uses shared placement
- [x] Tooltip opens on hover and focus
- [x] Escape closes tooltip/select/dialog
- [x] Styled confirmation replays LiveView click once
- [x] Native `window.confirm` not invoked
- [x] Reduced motion disables entrance animation
```

- [ ] **Step 4: Run final gate**

```bash
mix format
mix compile --warnings-as-errors
mix tailwind cympho
mix esbuild cympho
mix test
git diff --check
```

Expected: all commands exit 0 and full suite reports 0 failures.

- [ ] **Step 5: Commit**

```bash
git add docs/verification/interaction-foundations.md docs/verification/interaction-foundations.md
git commit -m "test: verify interaction foundations end to end"
```
