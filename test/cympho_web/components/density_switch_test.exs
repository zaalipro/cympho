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
    assert html =~ ~s(title="Toggle compact and detailed view with V")
    assert html =~ ~s(aria-label="View density")
    assert html =~ ~s(data-density-option="compact")
    assert html =~ ~s(data-density-option="detailed")
    assert html =~ ~s(aria-pressed="true")
    assert html =~ "title=\"Compact view (V)\""
    assert html =~ "title=\"Detailed view (V)\""
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
end
