defmodule CymphoWeb.MobileShellTest do
  use ExUnit.Case, async: true

  @root_layout "lib/cympho_web/controllers/layouts/root.html.heex"
  @app_css "assets/css/app.css"
  @kanban_board "lib/cympho_web/live/kanban_live/index.html.heex"
  @issue_new "lib/cympho_web/live/issue_live/new.html.heex"

  test "application shell uses dynamic viewport units instead of fixed screen height" do
    layout = File.read!(@root_layout)

    assert layout =~ "h-[100dvh]"
    assert layout =~ "min-h-[100svh]"
    assert layout =~ "max-h-[calc(100dvh-"
    refute layout =~ ~s(class="h-screen)
  end

  test "mobile content, navigation, dialogs, and toasts account for safe areas" do
    layout = File.read!(@root_layout)
    css = File.read!(@app_css)

    assert layout =~ "mobile-shell-content"
    assert layout =~ "safe-area-bottom"
    assert layout =~ "safe-area-dialog"
    assert layout =~ "safe-area-toast"
    assert layout =~ ~s(id="mobile-nav")
    assert layout =~ "h-14"

    for inset <- ["top", "right", "bottom", "left"] do
      assert css =~ "safe-area-inset-#{inset}"
    end

    assert css =~ "--mobile-header-height: 4rem"
    assert css =~ "--mobile-nav-height: 3.5rem"
    assert css =~ "--mobile-nav-offset: calc("
    assert css =~ "--mobile-shell-bottom: calc(4rem + env(safe-area-inset-bottom, 0px))"
    assert css =~ "padding-bottom: var(--mobile-shell-bottom)"
    assert css =~ "scroll-padding-bottom: var(--mobile-shell-bottom)"
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
    css = File.read!(@app_css)

    assert issue_new =~ "sticky-above-mobile-nav"
    assert issue_new =~ "sticky"
    refute issue_new =~ "sticky bottom-0"

    assert css =~ ".sticky-above-mobile-nav"
    assert css =~ "bottom: var(--mobile-nav-offset)"
  end
end
