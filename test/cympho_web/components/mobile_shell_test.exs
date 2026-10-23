defmodule CymphoWeb.MobileShellTest do
  use ExUnit.Case, async: true

  @root_layout "lib/cympho_web/controllers/layouts/root.html.heex"
  @app_css "assets/css/app.css"
  @r3_css "assets/css/r3.css"
  @kanban_board "lib/cympho_web/live/kanban_live/index.html.heex"
  @issue_new "lib/cympho_web/live/issue_live/new.html.heex"
  @agent_new "lib/cympho_web/live/agent_live/new.html.heex"

  test "application shell uses dynamic viewport units instead of fixed screen height" do
    layout = File.read!(@root_layout)

    assert layout =~ "h-[100dvh]"
    assert layout =~ "min-h-[100svh]"
    assert layout =~ "max-h-[calc(100dvh-"
    refute layout =~ ~s(class="h-screen)
  end

  # r3: one Main nav serves the rail and the phone tab bar (n2), so the safe
  # area moved from the old #mobile-nav markup into the tab bar's CSS offset.
  test "mobile content, navigation, dialogs, and toasts account for safe areas" do
    layout = File.read!(@root_layout)
    css = File.read!(@app_css)
    r3 = File.read!(@r3_css)

    assert layout =~ "mobile-shell-content"
    assert layout =~ "safe-area-dialog"
    assert layout =~ "safe-area-toast"
    refute layout =~ ~s(id="mobile-nav")
    assert r3 =~ "bottom:calc(8px + env(safe-area-inset-bottom, 0px))"

    for inset <- ["top", "right", "bottom", "left"] do
      assert css =~ "safe-area-inset-#{inset}"
    end

    assert css =~ "--mobile-header-height: 60px"
    assert css =~ "--mobile-nav-height: 66px"
    assert css =~ "--mobile-nav-offset: calc("
    assert css =~ "--mobile-shell-bottom: calc(4rem + env(safe-area-inset-bottom, 0px))"
    assert css =~ "padding-bottom: var(--mobile-shell-bottom)"
    assert css =~ "scroll-padding-bottom: var(--mobile-shell-bottom)"
  end

  # r3: the phone tab bar is the Main nav itself; Tasks owns list and board.
  test "mobile navigation uses one Tasks destination for list and board" do
    layout = File.read!(@root_layout)

    assert length(String.split(layout, "<.nav_rail")) == 2

    [tasks] = Enum.filter(CymphoWeb.Components.NavRail.destinations(), &(&1.label == "Tasks"))
    assert tasks.to == "/issues"
    assert "/kanban" in tasks.roots
    refute Enum.any?(CymphoWeb.Components.NavRail.destinations(), &(&1.to == "/kanban"))
  end

  test "board height uses dvh and accounts for mobile header + nav shell bottom" do
    board = File.read!(@kanban_board)
    css = File.read!(@app_css)

    assert board =~ "mobile-board-height"
    refute board =~ "100vh"
    refute board =~ "h-screen"

    assert css =~ ".mobile-board-height"
    assert css =~ "100dvh - var(--mobile-header-height) - var(--mobile-shell-bottom)"
    assert css =~ "height: 100dvh"
  end

  test "sticky CTAs clear fixed mobile bottom nav via nav+safe-area offset" do
    issue_new = File.read!(@issue_new)
    agent_new = File.read!(@agent_new)
    css = File.read!(@app_css)

    assert issue_new =~ "sticky-above-mobile-nav"
    assert issue_new =~ "sticky"
    refute issue_new =~ "sticky bottom-0"

    assert agent_new =~ "sticky-above-mobile-nav"
    assert agent_new =~ ~s(data-testid="new-agent-form-actions")
    assert agent_new =~ "sticky"
    refute agent_new =~ "sticky bottom-0"

    assert css =~ ".sticky-above-mobile-nav"
    assert css =~ "bottom: var(--mobile-nav-offset)"
  end
end
