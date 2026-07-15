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

  test "renders a stable inbox badge id when unread count is present" do
    html = render_rail(inbox_count: 7)

    assert html =~ ~s(data-testid="nav-badge-inbox")
    assert html =~ ~r/<span[^>]*data-testid="nav-badge-inbox"[^>]*>\s*7\s*<\/span>/s
  end

  test "renders a visible approvals badge when decisions are pending" do
    html = render_rail(approval_count: 3)

    assert html =~ ~s(href="/approvals?status=pending")
    assert html =~ ~s(data-testid="nav-badge-approvals")
    assert html =~ ~r/<span[^>]*data-testid="nav-badge-approvals"[^>]*>\s*3\s*<\/span>/s
  end

  test "renders the simple and advanced mode switcher" do
    html = render_rail([])

    assert html =~ ~s(data-ui-mode-toggle)
    assert html =~ ~s(title="Toggle simple and advanced view with U")
    assert html =~ ~s(aria-label="Toggle simple and advanced view with U")
    assert html =~ "Simple"
    assert html =~ "hero-squares-2x2-mini"
  end

  test "global runtime stop asks for confirmation" do
    html =
      render_rail(
        current_company: %{id: "company-1", status: "active"},
        runtime_controls_allowed: true
      )

    assert html =~ ~s(action="/runtime-control/stop")

    assert html =~
             ~s(data-confirm="Stop your agents and clear the queue?")
  end

  test "global runtime pause explains that queued wakes are preserved" do
    html =
      render_rail(
        current_company: %{id: "company-1", status: "active"},
        runtime_controls_allowed: true
      )

    assert html =~ ~s(action="/runtime-control/pause")

    assert html =~
             ~s(data-confirm="Pause your agents? Queued work is saved for later.")
  end

  test "global runtime controls expose low-power and full-power modes" do
    html =
      render_rail(
        current_company: %{id: "company-1", status: "active", governance_config: %{}},
        runtime_controls_allowed: true
      )

    assert html =~ ~s(action="/runtime-control/low-power")
    assert html =~ "Low"

    low_power_html =
      render_rail(
        current_company: %{
          id: "company-1",
          status: "active",
          governance_config: %{"runtime_mode" => "low_power"}
        },
        runtime_controls_allowed: true
      )

    assert low_power_html =~ "Low"
    assert low_power_html =~ ~s(action="/runtime-control/resume")
    assert low_power_html =~ "Full"
  end

  test "does not render the inbox badge when the unread count is zero" do
    html = render_rail(inbox_count: 0)

    refute html =~ ~s(data-testid="nav-badge-inbox")
  end

  test "does not render the approvals badge when no decisions are pending" do
    html = render_rail(approval_count: 0)

    refute html =~ ~s(data-testid="nav-badge-approvals")
  end
end
