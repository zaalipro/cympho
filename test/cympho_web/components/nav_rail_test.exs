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

  test "agent section is capped and links to the complete team" do
    html = render_rail(agents: Enum.map(1..9, &agent/1))

    assert html =~ "Engineer 5"
    refute html =~ "Engineer 6"
    refute html =~ "Engineer 9"
    assert html =~ "All agents"
    assert html =~ ~s(href="/agents")
    assert html =~ ">9<"
  end

  test "no overflow omits the all-agents row" do
    html = render_rail(agents: Enum.map(1..3, &agent/1))

    refute html =~ "All agents"
  end

  test "agent shortcuts stay visible in simple mode" do
    html = render_rail(projects: [project(1)], agents: [agent(1)])
    document = Floki.parse_document!(html)

    [agent_section] = Floki.find(document, "[data-nav-section='agents']")
    [project_section] = Floki.find(document, "[data-nav-section='projects']")

    refute Floki.attribute(agent_section, "class") |> Enum.join(" ") =~ "ui-advanced-only"
    assert Floki.attribute(project_section, "class") |> Enum.join(" ") =~ "ui-advanced-only"
  end

  test "renders a stable inbox badge id when unread count is present" do
    html = render_rail(inbox_count: 7)

    assert html =~ ~s(data-testid="nav-badge-inbox")
    assert html =~ ~r/<span[^>]*data-testid="nav-badge-inbox"[^>]*>\s*7\s*<\/span>/s
  end

  test "keeps approvals in Advanced mode when decisions are pending" do
    html = render_rail(approval_count: 3)
    document = Floki.parse_document!(html)
    [approval_link] = Floki.find(document, "a[href='/approvals?status=pending']")

    assert html =~ ~s(href="/approvals?status=pending")
    assert html =~ ~s(data-testid="nav-badge-approvals")
    assert html =~ ~r/<span[^>]*data-testid="nav-badge-approvals"[^>]*>\s*3\s*<\/span>/s
    assert Floki.attribute(approval_link, "class") |> Enum.join(" ") =~ "ui-advanced-only"
  end

  test "keeps an empty approvals shortcut in Advanced mode" do
    html = render_rail(approval_count: 0)
    document = Floki.parse_document!(html)
    [approval_link] = Floki.find(document, "a[href='/approvals?status=pending']")

    assert Floki.attribute(approval_link, "class") |> Enum.join(" ") =~ "ui-advanced-only"
  end

  test "keeps mode switching out of the navigation rail" do
    html = render_rail([])

    refute html =~ ~s(data-ui-mode-toggle)
    assert html =~ "Home"
    assert html =~ "Tasks"
    assert html =~ "Team"
    assert html =~ "ui-advanced-only"
    assert html =~ "focus-visible:ring-2"
  end

  test "uses one simple Tasks item for both list and board routes" do
    for current_path <- ["/issues", "/kanban"] do
      html = render_rail(current_path: current_path)
      document = Floki.parse_document!(html)
      [tasks_link] = Floki.find(document, "a[href='/issues']")

      assert Floki.text(tasks_link) =~ "Tasks"
      refute Floki.attribute(tasks_link, "class") |> Enum.join(" ") =~ "ui-advanced-only"
      assert Floki.attribute(tasks_link, "data-nav-matches") == ["/kanban"]
      assert Floki.attribute(tasks_link, "data-active") == ["true"]
      assert Floki.attribute(tasks_link, "aria-current") == ["page"]
      assert Floki.find(document, "a[href='/kanban']") == []
      refute html =~ ">Issues<"
    end
  end

  test "does not duplicate runtime controls in navigation" do
    html =
      render_rail(
        current_company: %{id: "company-1", status: "active"},
        runtime_controls_allowed: true
      )

    refute html =~ "/runtime-control/"
  end

  test "keeps a hidden live inbox badge node when the unread count is zero" do
    html = render_rail(inbox_count: 0)

    refute html =~ ~s(data-testid="nav-badge-inbox")
    assert html =~ ~s(data-nav-badge="inbox")
    assert html =~ ~s(data-count="0")
    assert html =~ "hidden"
  end

  test "keeps a hidden live approvals badge node when no decisions are pending" do
    html = render_rail(approval_count: 0)

    refute html =~ ~s(data-testid="nav-badge-approvals")
    assert html =~ ~s(data-nav-badge="approvals")
    assert html =~ ~s(data-count="0")
  end
end
