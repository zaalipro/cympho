defmodule CymphoWeb.KanbanLiveTest do
  use CymphoWeb.LiveCase, async: true
  import Phoenix.LiveViewTest
  alias Cympho.Agents
  alias Cympho.Comments
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Projects
  alias Cympho.Repo
  alias Cympho.WorkProducts

  defp create_agent(attrs), do: Agents.create_agent(scoped_attrs(attrs))
  defp create_issue(attrs), do: Issues.create_issue(scoped_attrs(attrs))
  defp create_project(attrs), do: Projects.create_project(scoped_attrs(attrs))

  setup do
    {:ok, project} = create_project(%{name: "Test Project", prefix: "TP"})

    {:ok, issue_backlog} =
      create_issue(%{
        title: "Backlog Issue",
        description: "backlog",
        status: :backlog,
        priority: :high,
        project_id: project.id
      })

    {:ok, issue_todo} =
      create_issue(%{
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
      assert html =~ "Compact"
      assert html =~ "Detailed"
      assert html =~ "Not started"
      assert html =~ "No agent work has started yet."
      assert html =~ "Start with the CEO"
    end

    test "supports compact digest density" do
      {:ok, _view, html} = live(conn(), "/kanban?density=compact")

      assert html =~ "Backlog Issue"
      assert html =~ "Not started"
      assert html =~ "No agent work has started yet."
      refute html =~ "Start with the CEO"
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
        create_issue(%{title: "Blocker", description: "blocks", status: :in_progress})

      {:ok, blocked} =
        create_issue(%{title: "Blocked", description: "blocked", status: :in_review})

      Issues.add_blocker(blocked, blocking)
      {:ok, view, _html} = live(conn(), "/kanban")

      view
      |> element("#kanban-board")
      |> render_hook("transition_issue", %{"id" => blocked.id, "to_status" => "done"})

      assert render(view) =~ "issue is blocked"
    end

    test "review gates block moving to review without delivery evidence" do
      {:ok, issue} =
        create_issue(%{
          title: "Board review needs evidence",
          description: "Owner request is clear.",
          status: :in_progress,
          priority: :medium
        })

      {:ok, view, _html} = live(conn(), "/kanban")

      view
      |> element("#kanban-board")
      |> render_hook("transition_issue", %{"id" => issue.id, "to_status" => "in_review"})

      html = render(view)
      assert html =~ "Move blocked"
      assert html =~ "Board review needs evidence"
      assert html =~ "Review gates blocking status change"
      assert html =~ "Runtime verification"
      assert html =~ "Agent completion note"
      assert html =~ "Start verification"
      assert html =~ "Add completion note"
      assert html =~ "Attach work product"
      assert html =~ ~s(href="/issues/#{issue.id}?gate=verification#issue-agent-panel")
      assert html =~ ~s(href="/issues/#{issue.id}?gate=delivery_note#issue-comments")
      assert html =~ ~s(href="/issues/#{issue.id}?gate=work_product#issue-work-product-form")
      assert Issues.get_issue!(issue.id).status == :in_progress
    end

    test "approval gates block moving to done without a CTO or CEO review decision" do
      {:ok, agent} =
        create_agent(%{
          name: "Board Delivery Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Board closure needs review",
          description: "Owner request is clear.",
          status: :in_progress,
          priority: :medium
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body: "[delivery] What happened: delivered board-visible work.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        company_id: issue.company_id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Board closure evidence",
          description: "Non-code closure evidence."
        })

      {:ok, view, _html} = live(conn(), "/kanban")

      view
      |> element("#kanban-board")
      |> render_hook("transition_issue", %{"id" => issue.id, "to_status" => "done"})

      html = render(view)
      assert html =~ "Move blocked"
      assert html =~ "Board closure needs review"
      assert html =~ "Approval gates blocking closure"
      assert html =~ "CTO/CEO review decision"
      assert html =~ "Add review comment"
      assert html =~ ~s(href="/issues/#{issue.id}?gate=review_comment#issue-comments")
      assert Issues.get_issue!(issue.id).status == :in_progress
    end

    test "blocked transition panel can be dismissed" do
      {:ok, issue} =
        create_issue(%{
          title: "Dismissible blocker",
          description: "Owner request is clear.",
          status: :in_progress,
          priority: :medium
        })

      {:ok, view, _html} = live(conn(), "/kanban")

      view
      |> element("#kanban-board")
      |> render_hook("transition_issue", %{"id" => issue.id, "to_status" => "in_review"})

      assert render(view) =~ "Move blocked"

      view
      |> element("#kanban-transition-blocker button", "Dismiss")
      |> render_click()

      refute render(view) =~ "Move blocked"
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
      create_issue(%{title: "Unassigned", description: "none", status: :todo})
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
      {:ok, other} = create_project(%{name: "Other", prefix: "OT"})

      create_issue(%{
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
