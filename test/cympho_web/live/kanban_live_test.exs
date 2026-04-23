defmodule CymphoWeb.KanbanLiveTest do
  use CymphoWeb.LiveCase, async: true
  import Phoenix.LiveViewTest
  alias Cympho.Issues
  alias Cympho.Projects
  alias Cympho.Agents
  alias Cympho.Comments

  setup do
    {:ok, project} = Projects.create_project(%{name: "Test Project", prefix: "TP"})
    {:ok, issue_backlog} = Issues.create_issue(%{title: "Backlog Issue", description: "backlog", status: :backlog, priority: :high, project_id: project.id})
    {:ok, issue_todo} = Issues.create_issue(%{title: "Todo Issue", description: "todo", status: :todo, priority: :medium, project_id: project.id})
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
      view |> element("#kanban-board") |> render_hook("transition_issue", %{"id" => issue.id, "to_status" => "todo"})
      assert render(view) =~ "Backlog Issue"
    end

    test "invalid transition shows error", %{issue_todo: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("transition_issue", %{"id" => issue.id, "to_status" => "backlog"})
      assert render(view) =~ "Invalid status transition"
    end

    test "blocked issue cannot move to done" do
      {:ok, blocking} = Issues.create_issue(%{title: "Blocker", description: "blocks", status: :in_progress})
      {:ok, blocked} = Issues.create_issue(%{title: "Blocked", description: "blocked", status: :in_review})
      Issues.add_blocker(blocked, blocking)
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("transition_issue", %{"id" => blocked.id, "to_status" => "done"})
      assert render(view) =~ "Cannot complete - issue is blocked"
    end

    test "shake event on invalid transition", %{issue_todo: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")
      result = render_hook(view, "transition_issue", %{"id" => issue.id, "to_status" => "backlog"})
      assert result =~ "shake_card"
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

  describe "Project filter" do
    test "shows All Projects", do: (assert (fn -> {:ok, _v, h} = live(conn(), "/kanban"); h end).() =~ "All Projects")
    test "filters by project", %{project: project} do
      {:ok, other} = Projects.create_project(%{name: "Other", prefix: "OT"})
      Issues.create_issue(%{title: "Other Issue", description: "other", status: :backlog, project_id: other.id})
      {:ok, _view, html} = live(conn(), "/kanban?project_id=#{project.id}")
      assert html =~ "Backlog Issue"
      refute html =~ "Other Issue"
    end
  end

  describe "Filter bar" do
    test "renders filter controls" do
      {:ok, _view, html} = live(conn(), "/kanban")
      assert html =~ "Assignee"
      assert html =~ "Priority"
      assert html =~ "Search title, assignee, priority"
    end

    test "clear filters button hidden when no filters active" do
      {:ok, _view, html} = live(conn(), "/kanban")
      refute html =~ "Clear filters"
    end
  end

  describe "Filter by assignee" do
    test "filters issues by assignee" do
      {:ok, agent} = Agents.create_agent(%{name: "Test Agent", role: :engineer})
      Issues.create_issue(%{title: "Assigned Issue", description: "has assignee", status: :todo, priority: :medium, assignee_id: agent.id})
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("filter_assignee", %{"assignee_id" => agent.id})
      html = render(view)
      assert html =~ "Assigned Issue"
      refute html =~ "Todo Issue"
    end

    test "clearing assignee filter shows all issues", %{issue_todo: issue} do
      {:ok, agent} = Agents.create_agent(%{name: "Test Agent", role: :engineer})
      Issues.update_issue(issue, %{assignee_id: agent.id})
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("filter_assignee", %{"assignee_id" => agent.id})
      view |> element("#kanban-board") |> render_hook("filter_assignee", %{"assignee_id" => ""})
      html = render(view)
      assert html =~ "Todo Issue"
    end
  end

  describe "Filter by priority" do
    test "filters to high priority only", %{issue_backlog: high} do
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("filter_priority", %{"priority" => "high"})
      html = render(view)
      assert html =~ "Backlog Issue"
      refute html =~ "Todo Issue"
    end

    test "clearing priority filter shows all issues" do
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("filter_priority", %{"priority" => "high"})
      view |> element("#kanban-board") |> render_hook("filter_priority", %{"priority" => ""})
      html = render(view)
      assert html =~ "Backlog Issue"
      assert html =~ "Todo Issue"
    end
  end

  describe "Filter by search" do
    test "search matches issue title", %{issue_backlog: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("filter_search", %{"query" => "backlog"})
      html = render(view)
      assert html =~ "Backlog Issue"
      refute html =~ "Todo Issue"
    end

    test "search is case-insensitive" do
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("filter_search", %{"query" => "TODO"})
      html = render(view)
      assert html =~ "Todo Issue"
      refute html =~ "Backlog Issue"
    end

    test "search matches assignee name" do
      {:ok, agent} = Agents.create_agent(%{name: "Searchable Agent", role: :engineer})
      Issues.create_issue(%{title: "Agent Issue", description: "searchable", status: :todo, priority: :low, assignee_id: agent.id})
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("filter_search", %{"query" => "searchable agent"})
      html = render(view)
      assert html =~ "Agent Issue"
      refute html =~ "Todo Issue"
    end

    test "clearing search shows all issues" do
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("filter_search", %{"query" => "nonexistent"})
      view |> element("#kanban-board") |> render_hook("clear_filters", %{})
      html = render(view)
      assert html =~ "Backlog Issue"
      assert html =~ "Todo Issue"
    end
  end

  describe "Clear filters" do
    test "clears all active filters" do
      {:ok, agent} = Agents.create_agent(%{name: "Clear Test Agent", role: :engineer})
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("filter_assignee", %{"assignee_id" => agent.id})
      view |> element("#kanban-board") |> render_hook("filter_priority", %{"priority" => "high"})
      view |> element("#kanban-board") |> render_hook("filter_search", %{"query" => "test"})
      view |> element("#kanban-board") |> render_hook("clear_filters", %{})
      html = render(view)
      assert html =~ "Backlog Issue"
      assert html =~ "Todo Issue"
      refute html =~ "Clear filters"
    end

    test "shows active filter count badge" do
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("filter_priority", %{"priority" => "high"})
      html = render(view)
      assert html =~ "Clear filters"
      assert html =~ "1"
    end
  end

  describe "No match empty state" do
    test "shows no-match message when filters exclude all issues" do
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("filter_search", %{"query" => "zzznonexistentzzz"})
      html = render(view)
      assert html =~ "No issues match the current filters"
      assert html =~ "Clear filters"
    end
  end

  describe "Quick actions" do
    test "quick action menu opens on card", %{issue_todo: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("open_card_action", %{"issue_id" => issue.id})
      html = render(view)
      assert html =~ "Edit title"
      assert html =~ "Add comment"
    end

    test "clicking same card action again closes menu", %{issue_todo: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("open_card_action", %{"issue_id" => issue.id})
      assert render(view) =~ "Edit title"
      view |> element("#kanban-board") |> render_hook("open_card_action", %{"issue_id" => issue.id})
      refute render(view) =~ "Edit title"
    end
  end

  describe "Quick title edit" do
    test "inline edit saves new title", %{issue_todo: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("open_card_action", %{"issue_id" => issue.id})
      view |> element("#kanban-board") |> render_hook("start_edit_title", %{"issue_id" => issue.id})
      view |> element("#kanban-board") |> render_hook("save_title", %{"issue_id" => issue.id, "title" => "New Title"})
      assert render(view) =~ "New Title"
    end
  end

  describe "Quick assign" do
    test "assigns issue to agent", %{issue_todo: issue} do
      {:ok, agent} = Agents.create_agent(%{name: "Assign Agent", role: :engineer})
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("open_card_action", %{"issue_id" => issue.id})
      view |> element("#kanban-board") |> render_hook("quick_assign", %{"issue_id" => issue.id, "agent_id" => agent.id})
      assert render(view) =~ "Assign Agent"
    end

    test "unassigns issue", %{issue_todo: issue} do
      {:ok, agent} = Agents.create_agent(%{name: "Unassign Agent", role: :engineer})
      Issues.update_issue(issue, %{assignee_id: agent.id})
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("open_card_action", %{"issue_id" => issue.id})
      view |> element("#kanban-board") |> render_hook("quick_unassign", %{"issue_id" => issue.id})
      html = render(view)
      refute html =~ "Unassign Agent"
    end
  end

  describe "Quick priority" do
    test "changes issue priority", %{issue_backlog: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("open_card_action", %{"issue_id" => issue.id})
      view |> element("#kanban-board") |> render_hook("quick_priority", %{"issue_id" => issue.id, "priority" => "low"})
      assert render(view) =~ "low"
    end
  end

  describe "Quick comment" do
    test "opens comment modal", %{issue_todo: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("open_card_action", %{"issue_id" => issue.id})
      view |> element("#kanban-board") |> render_hook("open_add_comment", %{"issue_id" => issue.id})
      html = render(view)
      assert html =~ "Add comment"
      assert html =~ "Write a comment"
    end

    test "submitting comment creates comment", %{issue_todo: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("open_card_action", %{"issue_id" => issue.id})
      view |> element("#kanban-board") |> render_hook("open_add_comment", %{"issue_id" => issue.id})
      view |> element("#kanban-board") |> render_hook("submit_comment", %{"issue_id" => issue.id, "comment" => "test comment"})
      [comment] = Comments.list_comments(issue.id)
      assert comment.body == "test comment"
    end
  end
end
