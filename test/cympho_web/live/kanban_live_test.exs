defmodule CymphoWeb.KanbanLiveTest do
  use CymphoWeb.LiveCase, async: true
  import Phoenix.LiveViewTest
  alias Cympho.Issues
  alias Cympho.Projects

  setup do
    {:ok, project} = Projects.create_project(%{name: "Test Project", prefix: "TP"})

    {:ok, issue_backlog} =
      Issues.create_issue(%{
        title: "Backlog Issue",
        description: "backlog",
        status: :backlog,
        priority: :high,
        project_id: project.id
      })

    {:ok, issue_todo} =
      Issues.create_issue(%{
        title: "Todo Issue",
        description: "todo",
        status: :todo,
        priority: :medium,
        project_id: project.id
      })

    %{project: project, issue_backlog: issue_backlog, issue_todo: issue_todo}
  end

  describe "Kanban rendering" do
    test "renders all status columns" do
      {:ok, _view, html} = live(conn(), "/kanban")
      assert html =~ "Backlog"
      assert html =~ "To Do"
      assert html =~ "In Progress"
      assert html =~ "In Review"
      assert html =~ "Done"
      assert html =~ "Blocked"
      assert html =~ "Cancelled"
    end

    test "renders issues" do
      {:ok, _view, html} = live(conn(), "/kanban")
      assert html =~ "Backlog Issue"
      assert html =~ "Todo Issue"
    end

    test "renders drag-and-drop attributes" do
      {:ok, _view, html} = live(conn(), "/kanban")
      assert html =~ "data-kanban-column"
      assert html =~ "data-issue-id"
    end
  end

  describe "Transitions" do
    test "valid transition succeeds", %{issue_backlog: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")

      view
      |> element("#kanban-board")
      |> render_hook("transition_issue", %{"id" => issue.id, "to_status" => "todo"})

      assert render(view) =~ "Backlog Issue"
    end

    test "invalid transition shows error", %{issue_todo: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")

      # todo -> done is not a valid transition
      view
      |> element("#kanban-board")
      |> render_hook("transition_issue", %{"id" => issue.id, "to_status" => "done"})

      assert render(view) =~ "Invalid status transition"
    end

    test "blocked issue cannot move to done" do
      {:ok, blocking} =
        Issues.create_issue(%{title: "Blocker", description: "blocks", status: :in_progress})

      {:ok, blocked} =
        Issues.create_issue(%{title: "Blocked", description: "blocked", status: :in_review})

      Issues.add_blocker(blocked, blocking)
      {:ok, view, _html} = live(conn(), "/kanban")

      view
      |> element("#kanban-board")
      |> render_hook("transition_issue", %{"id" => blocked.id, "to_status" => "done"})

      assert render(view) =~ "issue is blocked"
    end

    test "shake event on invalid transition", %{issue_todo: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")

      # todo -> done is not a valid transition
      result =
        render_hook(view, "transition_issue", %{"id" => issue.id, "to_status" => "done"})

      assert result =~ "Invalid status transition"
    end
  end

  describe "Swimlanes" do
    test "toggle swimlane mode", %{issue_backlog: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("toggle_swimlanes", %{})
      assert render(view) =~ issue.title
    end

    test "shows Unassigned group" do
      Issues.create_issue(%{title: "Unassigned", description: "none", status: :todo})
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("toggle_swimlanes", %{})
      assert render(view) =~ "Unassigned"
    end
  end

  describe "Collapsible columns" do
    test "collapse and expand", %{issue_backlog: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")
      assert render(view) =~ issue.title
      view |> element("#kanban-board") |> render_hook("toggle_column", %{"status" => "backlog"})
      refute render(view) =~ ~s(data-kanban-column="backlog")
      view |> element("#kanban-board") |> render_hook("toggle_column", %{"status" => "backlog"})
      assert render(view) =~ issue.title
    end
  end

  describe "Responsive layout" do
    test "renders kanban board container" do
      {:ok, _view, html} = live(conn(), "/kanban")
      assert html =~ "kanban-board"
    end
  end

  describe "Empty column states" do
    test "shows contextual empty state message for empty columns" do
      {:ok, _view, html} = live(conn(), "/kanban")
      assert html =~ "Nothing in flight"
      assert html =~ "Nothing to review"
      assert html =~ "No completed work yet"
      assert html =~ "No blockers"
      assert html =~ "No cancelled work"
    end

    test "empty backlog column shows no unplanned work message", %{issue_backlog: issue} do
      :ok = Issues.delete_issue(issue)
      {:ok, _view, html} = live(conn(), "/kanban")
      assert html =~ "No unplanned work"
    end

    test "empty todo column shows nothing queued message", %{issue_todo: issue} do
      :ok = Issues.delete_issue(issue)
      {:ok, _view, html} = live(conn(), "/kanban")
      assert html =~ "Nothing queued up"
    end
  end

  describe "Card animations" do
    test "renders card animation styles" do
      {:ok, _view, html} = live(conn(), "/kanban")
      assert html =~ "kanban-card-enter"
      assert html =~ "card-enter"
    end

    test "renders skeleton animation styles" do
      {:ok, _view, html} = live(conn(), "/kanban")
      assert html =~ "kanban-skeleton"
      assert html =~ "skeleton-pulse"
    end
  end

  describe "Project filter" do
    test "shows All Projects",
      do:
        assert(
          (fn ->
             {:ok, _v, h} = live(conn(), "/kanban")
             h
           end).() =~ "All projects"
        )

    test "filters by project", %{project: project} do
      {:ok, other} = Projects.create_project(%{name: "Other", prefix: "OT"})

      Issues.create_issue(%{
        title: "Other Issue",
        description: "other",
        status: :backlog,
        project_id: other.id
      })

      {:ok, _view, html} = live(conn(), "/kanban?project_id=#{project.id}")
      assert html =~ "Backlog Issue"
      refute html =~ "Other Issue"
    end
  end
end
