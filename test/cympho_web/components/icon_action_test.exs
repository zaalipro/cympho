defmodule CymphoWeb.Components.IconActionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  test "renders an accessible icon-only button" do
    html =
      render_component(&CymphoWeb.Components.icon_action/1,
        icon: "hero-bolt-mini",
        label: "Run heartbeat",
        disabled: true
      )

    assert html =~ ~s(aria-label="Run heartbeat")
    assert html =~ ~s(title="Run heartbeat")
    assert html =~ ~s(disabled)
    assert html =~ "hero-bolt-mini"
    assert html =~ ~r/<span class="sr-only">\s*Run heartbeat\s*<\/span>/
  end

  test "renders an accessible navigation action" do
    html =
      render_component(&CymphoWeb.Components.icon_action/1,
        icon: "hero-x-mark-mini",
        label: "Close",
        navigate: "/issues"
      )

    assert html =~ ~s(href="/issues")
    assert html =~ ~s(aria-label="Close")
    assert html =~ ~s(title="Close")
  end
end
