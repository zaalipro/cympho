defmodule CymphoWeb.Components.NavRailTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  defp agent(i), do: %{id: "a#{i}", name: "Engineer #{i}", role: :engineer, status: :idle}
  defp project(i), do: %{id: "p#{i}", name: "Project #{i}", color: "#fff", open_count: i}

  defp render_rail(opts) do
    render_component(
      &CymphoWeb.Components.NavRail.nav_rail/1,
      Keyword.merge([current_path: "/dashboard", projects: [], agents: []], opts)
    )
  end

  test "Projects/Agents are collapsible sections with a toggle + chevron" do
    html = render_rail(projects: [project(1)], agents: [agent(1)])
    assert html =~ ~s(data-nav-section="projects")
    assert html =~ ~s(data-nav-section="agents")
    assert html =~ ~s(data-nav-toggle="projects")
    assert html =~ ~s(data-nav-toggle="agents")
    assert html =~ "data-nav-chevron"
    assert html =~ "data-nav-body"
  end

  test "9 agents (cap 8) renders 1 overflow row + a Show-1-more button, not a link" do
    html = render_rail(agents: Enum.map(1..9, &agent/1))
    # all 9 rows present
    assert html =~ "Engineer 9"
    # exactly one overflow row (hidden until revealed)
    assert length(String.split(html, "data-nav-overflow")) - 1 == 1
    # inline reveal button (not a navigate link to /agents)
    assert html =~ ~s(data-nav-show-more="agents")
    assert html =~ "Show 1 more…"
    assert html =~ "Show less"
    refute html =~ ~s(navigate="/agents")
  end

  test "no overflow → no Show-more button" do
    html = render_rail(agents: Enum.map(1..3, &agent/1))
    refute html =~ "data-nav-show-more"
    refute html =~ "data-nav-overflow"
  end
end
