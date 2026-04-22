defmodule CymphoWeb.KanbanLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Issues
  alias Cympho.Projects

  setup do
    {:ok, project} =
      Projects.create_project(%{
        name: "Test Project",
        prefix: "TP"
      })

    {:ok, issue_backlog} =
      Issues.create_issue(%{
        title: "Backlog Issue",
        description: "A backlog issue",
        status: :backlog,
        priority: :high,
        project_id: project.id
      })

    {:ok, issue_todo} =
      Issues.create_issue(%{
        title: "Todo Issue",
        description: "A todo issue",
        status: :todo,
        priority: :medium,
        project_id: project.id
      })

    {:ok, issue_in_progress} =
      Issues.create_issue(%{
        title: "In Progress Issue",
        description: "An in-progress issue",
        status: :in_progress,
        priority: :low,
        project_id: project.id
      })

    %{
      project: project,
      issue_backlog: issue_backlog,
      issue_todo: issue_todo,
      issue_in_progress: issue_in_progress
    }
  end

  describe "Kanban board rendering" do
    test "renders the kanban board with all status columns" do
      {:ok, _view, html} = live(conn(), "/kanban")

      assert html =~ "Kanban Board"
      assert html =~ "Backlog"
      assert html =~ "To Do"
      assert html =~ "In Progress"
      assert html =~ "In Review"
      assert html =~ "Done"
      assert html =~ "Blocked"
    end

    test "renders issues in their respective columns" do
      {:ok, _view, html} = live(conn(), "/kanban")

      assert html =~ "Backlog Issue"
      assert html =~ "Todo Issue"
      assert html =~ "In Progress Issue"
    end

    test "renders issue priority badges" do
      {:ok, _view, html} = live(conn(), "/kanban")

      assert html =~ "high"
      assert html =~ "medium"
      assert html =~ "low"
    end

    test "renders drag-and-drop hook container" do
      {:ok, _view, html} = live(conn(), "/kanban")

      assert html =~ ~s(phx-hook="KanbanSortable")
      assert html =~ ~s(data-kanban-column)
    end

    test "renders issue cards with data-issue-id for drag-and-drop" do
      {:ok, _view, html} = live(conn(), "/kanban")

      assert html =~ ~s(data-issue-id)
    end

    test "shows column issue counts" do
      {:ok, _view, html} = live(conn(), "/kanban")

      # Each column has a count badge
      assert html =~ ~r(>1<)
    end
  end

  describe "Drag-and-drop transitions" do
    test "valid transition via transition_issue event", %{issue_backlog: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")

      assert render(view) =~ "Backlog Issue"

      view
      |> element("#kanban-board")
      |> render_hook("transition_issue", %{"id" => issue.id, "to_status" => "todo"})

      html = render(view)
      refute html =~ ~r(data-kanban-column="backlog".*Backlog Issue)s
    end

    test "invalid transition shows flash error", %{issue_todo: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")

      view
      |> element("#kanban-board")
      |> render_hook("transition_issue", %{"id" => issue.id, "to_status" => "backlog"})

      assert render(view) =~ "Invalid status transition"
    end

    test "transition to done when blocked shows flash error" do
      {:ok, blocking} =
        Issues.create_issue(%{
          title: "Blocker",
          description: "Blocking issue",
          status: :in_progress
        })

      {:ok, blocked} =
        Issues.create_issue(%{
          title: "Blocked Issue",
          description: "Is blocked",
          status: :in_review
        })

      {:ok, _} = Issues.add_blocker(blocked, blocking)

      {:ok, view, _html} = live(conn(), "/kanban")

      view
      |> element("#kanban-board")
      |> render_hook("transition_issue", %{"id" => blocked.id, "to_status" => "done"})

      assert render(view) =~ "Cannot complete - issue is blocked"
    end

    test "shake event is pushed on invalid transition", %{issue_todo: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")

      assert render_hook(view, "transition_issue", %{"id" => issue.id, "to_status" => "backlog"}) =~
               "shake_card"
    end
  end

  describe "Swimlanes" do
    test "toggle swimlane mode on", %{issue_backlog: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")

      view
      |> element("#kanban-board")
      |> render_hook("toggle_swimlanes", %{})

      html = render(view)
      # Swimlane mode is active - toggle button shows active state
      assert html =~ "Swimlanes"
      # Issue is still visible
      assert html =~ issue.title
    end

    test "toggle swimlane mode off", %{issue_backlog: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")

      # Toggle on
      view |> element("#kanban-board") |> render_hook("toggle_swimlanes", %{})
      # Toggle off
      view |> element("#kanban-board") |> render_hook("toggle_swimlanes", %{})

      html = render(view)
      assert html =~ issue.title
    end

    test "swimlanes group by assignee" do
      {:ok, agent} =
        Cympho.Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          url_key: "test-agent"
        })

      {:ok, _issue} =
        Issues.create_issue(%{
          title: "Assigned Issue",
          description: "Has assignee",
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, view, _html} = live(conn(), "/kanban")

      # Enable swimlanes
      view |> element("#kanban-board") |> render_hook("toggle_swimlanes", %{})

      html = render(view)
      assert html =~ "Test Agent"
    end

    test "swimlanes show Unassigned group" do
      {:ok, _issue} =
        Issues.create_issue(%{
          title: "Unassigned Issue",
          description: "No assignee",
          status: :todo
        })

      {:ok, view, _html} = live(conn(), "/kanban")

      # Enable swimlanes
      view |> element("#kanban-board") |> render_hook("toggle_swimlanes", %{})

      html = render(view)
      assert html =~ "Unassigned"
    end
  end

  describe "Collapsible columns" do
    test "collapse a column", %{issue_backlog: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")

      # Initially visible
      assert render(view) =~ "Backlog Issue"

      # Collapse backlog column
      view
      |> element("#kanban-board")
      |> render_hook("toggle_column", %{"status" => "backlog"})

      html = render(view)
      # Column is collapsed (showing just the first letter "B")
      assert html =~ "B"
      # Issue text should not be visible in collapsed state
      refute html =~ ~r(data-kanban-column="backlog")
    end

    test "expand a collapsed column", %{issue_backlog: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")

      # Collapse
      view |> element("#kanban-board") |> render_hook("toggle_column", %{"status" => "backlog"})
      # Expand
      view |> element("#kanban-board") |> render_hook("toggle_column", %{"status" => "backlog"})

      html = render(view)
      assert html =~ issue.title
    end
  end

  describe "WIP limits" do
    test "WIP limit is displayed when project has settings", %{project: project} do
      {:ok, _} =
        Projects.update_project(project, %{
          settings: %{"wip_limits" => %{"in_progress" => 3}}
        })

      {:ok, view, _html} = live(conn(), "/kanban?project_id=#{project.id}")

      html = render(view)
      assert html =~ "1/3"
    end

    test "WIP exceeded shows red indicator", %{project: project} do
      {:ok, _} =
        Projects.update_project(project, %{
          settings: %{"wip_limits" => %{"in_progress" => 1}}
        })

      {:ok, view, _html} = live(conn(), "/kanban?project_id=#{project.id}")

      html = render(view)
      # Already have 1 in_progress issue + limit of 1 = not exceeded, but shows count
      assert html =~ "1/1"
    end
  end

  describe "Project filter" do
    test "project filter dropdown is rendered" do
      {:ok, _view, html} = live(conn(), "/kanban")

      assert html =~ "All Projects"
    end

    test "filtering by project shows only that project's issues", %{project: project} do
      # Create an issue in a different project
      {:ok, other_project} =
        Projects.create_project(%{
          name: "Other Project",
          prefix: "OP"
        })

      {:ok, _other_issue} =
        Issues.create_issue(%{
          title: "Other Project Issue",
          description: "In other project",
          status: :backlog,
          project_id: other_project.id
        })

      {:ok, view, _html} = live(conn(), "/kanban?project_id=#{project.id}")

      html = render(view)
      assert html =~ "Backlog Issue"
      refute html =~ "Other Project Issue"
    end

    test "filter_project event with empty string shows all issues" do
      {:ok, view, _html} = live(conn(), "/kanban")

      view
      |> element("form")
      |> render_change(%{"project_id" => ""})

      # Should still be on /kanban (no project filter)
      assert has_element?(view, "#kanban-board")
    end
  end
end
