defmodule CymphoWeb.Components.DensitySwitchTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  test "renders accessible compact/detailed controls with keyboard metadata" do
    html =
      render_component(&CymphoWeb.Components.density_switch/1,
        density: "compact",
        compact_patch: "/issues",
        detailed_patch: "/issues?density=detailed"
      )

    assert html =~ ~s(data-density-switch)
    assert html =~ ~s(data-density="compact")
    assert html =~ ~s(title="Change row detail with V")
    assert html =~ ~s(aria-label="Row detail")
    assert html =~ ~s(role="group")
    assert html =~ ~s(data-density-option="compact")
    assert html =~ ~s(data-density-option="detailed")
    assert html =~ ~s(role="button")
    assert html =~ ~s(aria-pressed="true")
    assert html =~ "title=\"Compact rows (V)\""
    assert html =~ "title=\"Detailed rows (V)\""
    assert html =~ "focus-visible:ring-2"
  end

  test "marks detailed as active when detailed density is selected" do
    html =
      render_component(&CymphoWeb.Components.density_switch/1,
        density: "detailed",
        compact_patch: "/operations",
        detailed_patch: "/operations?density=detailed"
      )

    assert html =~ ~s(data-density="detailed")
    assert html =~ ~s(data-density-option="detailed")
    assert html =~ ~s(aria-pressed="true")
    assert html =~ ~s(data-density-option="compact")
    assert html =~ ~s(aria-pressed="false")
  end

  test "row density does not reveal expert-only controls in Simple mode" do
    css = File.read!(Path.join([File.cwd!(), "assets/css/app.css"]))

    assert css =~ ~s|html[data-ui-mode="simple"] [data-ui-complex-page] .ui-advanced-only|
    refute css =~ ~s|:not([data-density="detailed"])|
    refute css =~ ~s|[data-density="detailed"] .ui-simple-only|
  end

  test "mode script restores focus to a visible mode control after hiding the active element" do
    script = File.read!(Path.join([File.cwd!(), "assets/js/app.js"]))

    assert script =~ "function visibleModeControl(mode)"
    assert script =~ "function focusedElementIsVisible(element)"
    assert script =~ "const rect = control.getBoundingClientRect()"
    assert script =~ "rect.left < window.innerWidth"
    assert script =~ "visibleModeControl(normalized)?.focus({preventScroll: true})"
  end

  test "mode state prefers the live DOM when storage is unavailable" do
    script = File.read!(Path.join([File.cwd!(), "assets/js/app.js"]))

    {dom_offset, _length} =
      :binary.match(script, "const domMode = document.documentElement.dataset.uiMode")

    {storage_offset, _length} = :binary.match(script, "localStorage.getItem(UI_MODE_KEY)")

    assert dom_offset < storage_offset

    assert script =~
             "if (domMode === \"advanced\" || domMode === \"simple\") return domMode"
  end

  test "Simple keeps expert navigation out of global overlays and keyboard shortcuts" do
    script = File.read!(Path.join([File.cwd!(), "assets/js/app.js"]))

    layout =
      File.read!(Path.join([File.cwd!(), "lib/cympho_web/controllers/layouts/root.html.heex"]))

    assert script =~ "const ADVANCED_ONLY_GOTO_KEYS = new Set(['i', 'g'])"
    assert script =~ "currentUIMode() === 'advanced' || !ADVANCED_ONLY_GOTO_KEYS.has(key)"
    assert layout =~ ~r/id="command-palette"\s+data-ui-complex-page/
    assert layout =~ ~r/id="shortcuts-modal"\s+data-ui-complex-page/
    assert layout =~ ~r/href="\/issues"\s+class="command-item ui-advanced-only/
    assert layout =~ ~r/href="\/goals"\s+class="command-item ui-advanced-only/
    assert layout =~ ~r/class="ui-advanced-only[^\"]*"[^>]*>\s*<span[^>]*>Go to Issues/
    assert layout =~ ~r/class="ui-advanced-only[^\"]*"[^>]*>\s*<span[^>]*>Go to Goals/

    assert layout =~
             ~r/data-testid="quick-create-swarm-controls"\s+class="ui-advanced-only/

    assert layout =~
             ~r/data-testid="quick-create-fields"\s+data-ui-simple-single-column/

    assert layout =~
             ~r/data-testid="quick-create-fields"[\s\S]*?class="grid grid-cols-1 gap-3/
  end

  test "command palette accelerator works from form fields and resets prior filtering" do
    script = File.read!(Path.join([File.cwd!(), "assets/js/app.js"]))

    {shortcut_offset, _length} =
      :binary.match(script, "if ((e.metaKey || e.ctrlKey) && e.key === 'k' && !e.shiftKey)")

    {company_shortcut_offset, _length} =
      :binary.match(script, "if ((e.metaKey || e.ctrlKey) && e.key === 'K')")

    {input_guard_offset, _length} = :binary.match(script, "if (isInput) return;")

    assert shortcut_offset < input_guard_offset
    assert company_shortcut_offset < input_guard_offset
    assert script =~ "function resetCommandPalette(input)"
    assert script =~ "input.dispatchEvent(new Event('input'))"
    assert script =~ "function openCommandPalette()"

    assert script =~
             ~s|e.target.closest('[data-action="open-command-palette"]')|
  end

  test "Simple collapses mode-aware forms when Advanced side rails are hidden" do
    css = File.read!(Path.join([File.cwd!(), "assets/css/app.css"]))

    assert css =~
             ~s|html[data-ui-mode="simple"] [data-ui-complex-page] [data-ui-simple-single-column]|

    assert css =~ "grid-template-columns: minmax(0, 1fr) !important"

    assert css =~
             ~s|html[data-ui-mode="simple"] [data-ui-complex-page] [data-ui-simple-full-span]|

    assert css =~ "grid-column: 1 / -1 !important"
  end
end
