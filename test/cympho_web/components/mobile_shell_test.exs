defmodule CymphoWeb.MobileShellTest do
  use ExUnit.Case, async: true

  @root_layout "lib/cympho_web/controllers/layouts/root.html.heex"
  @app_css "assets/css/app.css"

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

    for inset <- ["top", "right", "bottom", "left"] do
      assert css =~ "safe-area-inset-#{inset}"
    end

    assert css =~ "padding-bottom: calc(4rem + env(safe-area-inset-bottom, 0px))"
    assert css =~ "scroll-padding-bottom: calc(4rem + env(safe-area-inset-bottom, 0px))"
  end
end
