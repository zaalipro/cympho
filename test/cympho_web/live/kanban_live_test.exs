defmodule CymphoWeb.KanbanLiveTest do
  use CymphoWeb.LiveCase, async: true
  import Phoenix.LiveViewTest
  alias Cympho.Agents
  alias Cympho.Comments
  alias Cympho.Goals
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Projects
  alias Cympho.Repo
  alias Cympho.WorkProducts

  defp create_agent(attrs), do: Agents.create_agent(scoped_attrs(attrs))
  defp create_goal(attrs), do: Goals.create_goal(scoped_attrs(attrs))
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
      {:ok, _view, html} = live(conn(), "/kanban?density=detailed")
      assert html =~ "Backlog"
      assert html =~ "To Do"
      assert html =~ "In Progress"
      assert html =~ "In Review"
      assert html =~ "Done"
      assert html =~ "Blocked"
      assert html =~ "Cancelled"
    end

    test "renders issues" do
      {:ok, _view, html} = live(conn(), "/kanban?density=detailed")
      assert html =~ "Backlog Issue"
      assert html =~ "Todo Issue"
      assert html =~ "Compact"
      assert html =~ "Detailed"
      assert html =~ "Not started"
      assert html =~ "No agent work has started yet."
      assert html =~ "Start with the CEO"
    end

    test "groups board header controls in one aligned toolbar" do
      {:ok, _view, html} = live(conn(), "/kanban?density=detailed")

      toolbar =
        html
        |> Floki.parse_document!()
        |> Floki.find("[data-testid='kanban-header-actions']")

      toolbar_text = Floki.text(toolbar)
      view_controls = Floki.find(toolbar, "[data-testid='kanban-view-controls']")
      view_controls_text = Floki.text(view_controls)
      toolbar_class = toolbar |> Floki.attribute("class") |> List.first()
      view_controls_class = view_controls |> Floki.attribute("class") |> List.first()

      new_issue_class =
        toolbar
        |> Floki.find("a[href='/issues/new']")
        |> Floki.attribute("class")
        |> List.first()

      assert toolbar != []
      assert view_controls != []
      assert toolbar_class =~ "grid-cols-2"
      assert toolbar_class =~ "sm:flex"
      assert view_controls_class =~ "order-2"
      assert view_controls_class =~ "sm:flex"
      assert toolbar_text =~ "List"
      assert toolbar_text =~ "Project:"
      assert toolbar_text =~ "Swimlanes"
      assert toolbar_text =~ "Compact"
      assert toolbar_text =~ "Detailed"
      assert toolbar_text =~ "New Issue"
      assert view_controls_text =~ "List"
      assert view_controls_text =~ "Project:"
      assert view_controls_text =~ "Swimlanes"
      assert view_controls_text =~ "Compact"
      assert view_controls_text =~ "Detailed"
      refute view_controls_text =~ "New Issue"
      assert Floki.find(toolbar, "a[href='/issues/new']") != []
      assert new_issue_class =~ "order-1"
      assert new_issue_class =~ "w-full"
      assert new_issue_class =~ "sm:w-auto"
    end

    test "renders launch checklist action for assigned todo digest cards" do
      {:ok, agent} =
        create_agent(%{
          name: "Launch CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, _issue} =
        create_issue(%{
          title: "Assigned launch card",
          description: "Needs a first runtime pass.",
          status: :todo,
          priority: :high,
          assignee_id: agent.id,
          assigned_role: "ceo"
        })

      {:ok, _view, html} = live(conn(), "/kanban?density=detailed")

      assert html =~ "Assigned launch card"
      assert html =~ "Launch needed"
      assert html =~ "Assigned, but runtime has not started yet."
      assert html =~ "Open launch checklist"
      assert html =~ ~s(href="/operations#runtime-launch-checklist")
    end

    test "renders launch readiness on dispatchable board cards" do
      {:ok, _agent} =
        create_agent(%{
          name: "Board Launch Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom", "repo_capable" => true}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Board implementation launch chip",
          description: """
          Acceptance criteria: board card shows runtime state.
          Evidence required: card link and target agent.
          Verification required: render the board.
          Definition of done: card is complete.
          """,
          status: :todo,
          priority: :high,
          assigned_role: "engineer"
        })

      {:ok, _view, html} = live(conn(), "/kanban")

      assert html =~ "Board implementation launch chip"
      assert html =~ ~s(href="/issues/#{issue.id}#issue-agent-panel")

      launch_link =
        html
        |> Floki.parse_document!()
        |> Floki.find("a[href='/issues/#{issue.id}#issue-agent-panel']")
        |> List.first()

      {_tag, attrs, _children} = launch_link
      attrs = Map.new(attrs)

      assert attrs["aria-label"] =~ "Board Launch Engineer"
      assert attrs["aria-label"] =~ ~r/(Ready|Review mode|Needs setup|Blocked|No agent)/
    end

    test "renders a compact board health summary and issue action menus" do
      {:ok, project} = create_project(%{name: "Command Board", prefix: "CB"})

      {:ok, ceo} =
        create_agent(%{
          name: "Command CEO",
          role: :ceo,
          status: :idle,
          project_id: project.id
        })

      {:ok, reviewer} =
        create_agent(%{
          name: "Command CTO",
          role: :cto,
          status: :idle,
          project_id: project.id
        })

      {:ok, blocked} =
        create_issue(%{
          title: "Board blocked release",
          description: "Needs intervention.",
          status: :blocked,
          priority: :critical,
          project_id: project.id
        })

      {:ok, ceo_launch} =
        create_issue(%{
          title: "Board CEO launch",
          description: "Needs the CEO first turn.",
          status: :todo,
          priority: :high,
          assignee_id: ceo.id,
          assigned_role: "ceo",
          project_id: project.id
        })

      {:ok, review} =
        create_issue(%{
          title: "Board review approval",
          description: "Needs acceptance.",
          status: :in_review,
          priority: :medium,
          assignee_id: reviewer.id,
          project_id: project.id
        })

      {:ok, _view, html} = live(conn(), "/kanban?project_id=#{project.id}")

      assert html =~ "Board health"
      assert html =~ "1 blocked"
      assert html =~ "1 review"
      refute html =~ "Board command"
      refute html =~ "Focus queue"
      assert html =~ "Board blocked release"
      assert html =~ ~s(href="/issues/#{blocked.id}")
      assert html =~ "Board CEO launch"
      assert html =~ ~s(href="/issues/#{ceo_launch.id}")
      assert html =~ "Board review approval"
      assert html =~ ~s(href="/issues/#{review.id}")
      assert html =~ ~s(aria-label="Move issue")
      assert html =~ "hero-ellipsis-horizontal-mini"
    end

    test "supports compact digest density" do
      {:ok, _view, html} = live(conn(), "/kanban?density=compact")

      assert html =~ "Backlog Issue"
      assert html =~ "Not started"
      assert html =~ "No agent work has started yet."
      refute html =~ "Start with the CEO"
    end

    test "shows mission context on board cards", %{project: project} do
      {:ok, mission} =
        create_goal(%{
          title: "Board mission context",
          goal_type: :mission,
          project_id: project.id
        })

      {:ok, _issue} =
        create_issue(%{
          title: "Aligned board card",
          description: "Board should show why this work exists.",
          status: :todo,
          priority: :high,
          project_id: project.id,
          goal_id: mission.id
        })

      {:ok, _view, html} = live(conn(), "/kanban")

      assert html =~ "Aligned board card"
      assert html =~ "Mission: Board mission context"
      assert html =~ "Project only"
    end

    test "renders drag-and-drop attributes" do
      {:ok, _view, html} = live(conn(), "/kanban")
      assert html =~ "data-kanban-column"
      assert html =~ "data-issue-id"
    end

    test "resting cards show priority only when elevated", %{
      issue_backlog: high_issue,
      issue_todo: medium_issue
    } do
      {:ok, _view, html} = live(conn(), "/kanban")
      doc = Floki.parse_document!(html)

      # Elevated priority renders as a mini icon with a tooltip, not a word chip.
      high_card = doc |> Floki.find("[data-issue-id='#{high_issue.id}']")
      medium_card = doc |> Floki.find("[data-issue-id='#{medium_issue.id}']")

      assert high_card |> Floki.find("[title='High priority']") |> length() == 1
      assert medium_card |> Floki.find("[title='Medium priority']") |> Enum.empty?()
      refute medium_card |> Floki.text() =~ "Medium"
    end

    test "assigned cards show an initials avatar with role context" do
      {:ok, agent} =
        create_agent(%{
          name: "Ivy Chen",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Avatar card",
          description: "Shows who is on it.",
          status: :in_progress,
          priority: :medium,
          assignee_id: agent.id
        })

      {:ok, _view, html} = live(conn(), "/kanban")

      card =
        html
        |> Floki.parse_document!()
        |> Floki.find("[data-issue-id='#{issue.id}']")

      avatar_titles =
        card
        |> Floki.find("span[title]")
        |> Floki.attribute("title")
        |> Enum.join(" ")

      assert Floki.text(card) =~ "IC"
      assert avatar_titles =~ "Ivy Chen · engineer"
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

    test "todo review gate blocker points to runtime launch before evidence actions", %{
      issue_todo: issue
    } do
      {:ok, view, _html} = live(conn(), "/kanban")

      view
      |> element("#kanban-board")
      |> render_hook("transition_issue", %{"id" => issue.id, "to_status" => "in_review"})

      html = render(view)
      assert html =~ "Move blocked"
      assert html =~ "Todo Issue"
      assert html =~ "Review gates blocking status change"
      assert html =~ "Runtime verification"
      assert html =~ "Open launch checklist"
      assert html =~ "Open issue preflight"
      assert html =~ ~s(href="/operations#runtime-launch-checklist")
      assert html =~ ~s(href="/issues/#{issue.id}#issue-agent-panel")
      refute html =~ "Start verification"
      refute html =~ "Add completion note"
      refute html =~ "Attach work product"
      assert Issues.get_issue!(issue.id).status == :todo
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

    test "empty columns avoid repeated drop instructions" do
      {:ok, _view, html} = live(conn(), "/kanban")
      refute html =~ "Drag a card here"
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
