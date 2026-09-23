defmodule CymphoWeb.KanbanLiveTest do
  use CymphoWeb.LiveCase, async: true
  import Ecto.Query
  import Phoenix.LiveViewTest
  alias Cympho.Agents
  alias Cympho.AgentHeartbeat
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
      task_view_switch = Floki.find(toolbar, "[data-testid='task-view-switch']")
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
      assert task_view_switch != []
      assert toolbar_class =~ "grid-cols-2"
      assert toolbar_class =~ "sm:flex"
      assert view_controls_class =~ "order-2"
      assert view_controls_class =~ "sm:flex"
      assert toolbar_text =~ "List"
      assert toolbar_text =~ "Board"
      assert toolbar_text =~ "Project:"
      assert toolbar_text =~ "Swimlanes"
      assert toolbar_text =~ "Compact"
      assert toolbar_text =~ "Detailed"
      assert toolbar_text =~ "New Issue"
      refute view_controls_text =~ "List"
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

    test "renders the accessible task view switch with board selected" do
      {:ok, _view, html} = live(conn(), "/kanban")
      document = Floki.parse_document!(html)
      [switch] = Floki.find(document, "[data-testid='task-view-switch']")
      [list_link] = Floki.find(switch, "a[href='/issues']")
      [board_link] = Floki.find(switch, "a[href='/kanban']")

      assert Floki.attribute(switch, "aria-label") == ["Task view"]
      assert Floki.attribute(list_link, "aria-label") == ["List view"]
      assert Floki.attribute(list_link, "aria-current") == []
      assert Floki.attribute(list_link, "aria-pressed") == ["false"]
      assert Floki.attribute(board_link, "aria-label") == ["Board view"]
      assert Floki.attribute(board_link, "aria-current") == ["page"]
      assert Floki.attribute(board_link, "aria-pressed") == ["true"]
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

    test "card menus and DnD allow-list match StateMachine transitions" do
      {:ok, agent} =
        create_agent(%{
          name: "SM Menu Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, in_progress} =
        create_issue(%{
          title: "In flight card",
          description: "menus track SM",
          status: :in_progress,
          priority: :medium,
          assignee_id: agent.id
        })

      {:ok, done} =
        create_issue(%{
          title: "Done card",
          description: "reopen menus",
          status: :done,
          priority: :low
        })

      {:ok, _view, html} = live(conn(), "/kanban")
      doc = Floki.parse_document!(html)

      in_progress_card =
        doc
        |> Floki.find("[data-issue-id='#{in_progress.id}']")
        |> List.first()

      assert in_progress_card
      allowed = Floki.attribute(in_progress_card, "data-allowed-statuses") |> List.first()
      assert is_binary(allowed)

      expected =
        Cympho.Issues.StateMachine.valid_transitions(:in_progress)
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      actual = allowed |> String.split(",", trim: true) |> MapSet.new()
      assert actual == expected
      # Board demotion must be offered (historical lag omitted :todo).
      assert "todo" in MapSet.to_list(actual)
      assert "backlog" in MapSet.to_list(actual)

      menu_text =
        in_progress_card
        |> Floki.find("button[data-kanban-action]")
        |> Enum.map(&Floki.text/1)
        |> Enum.join(" ")

      assert menu_text =~ "To Do"
      assert menu_text =~ "Backlog"

      done_card =
        doc
        |> Floki.find("[data-issue-id='#{done.id}']")
        |> List.first()

      done_allowed = Floki.attribute(done_card, "data-allowed-statuses") |> List.first()

      done_expected =
        Cympho.Issues.StateMachine.valid_transitions(:done)
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      assert done_allowed |> String.split(",", trim: true) |> MapSet.new() == done_expected
    end

    test "demoting in_progress to todo via board clears checkout and keeps assignee" do
      {:ok, agent} =
        create_agent(%{
          name: "Board Demote Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Demote via board",
          description: "clear checkout on demotion",
          status: :todo,
          priority: :medium,
          assignee_id: agent.id
        })

      assert {:ok, run} =
               Cympho.HeartbeatEngine.create_run(%{
                 company_id: issue.company_id,
                 agent_id: agent.id,
                 issue_id: issue.id,
                 adapter: "claude_code"
               })

      assert {:ok, checked_out} = Issues.bind_checkout_run(issue.id, agent.id, run.id)
      assert checked_out.status == :in_progress
      assert checked_out.checkout_run_id == run.id

      {:ok, view, _html} = live(conn(), "/kanban")

      view
      |> element("#kanban-board")
      |> render_hook("transition_issue", %{"id" => issue.id, "to_status" => "todo"})

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :todo
      assert reloaded.assignee_id == agent.id
      assert is_nil(reloaded.checkout_run_id)
      assert is_nil(reloaded.checked_out_at)
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

    test "cancelling a blocker via board unblocks dependent and enqueues durable wake" do
      {:ok, agent} =
        create_agent(%{
          name: "Blocker Wake Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, blocker} =
        create_issue(%{
          title: "Board blocker",
          description: "will cancel",
          status: :in_progress,
          priority: :medium
        })

      {:ok, dependent} =
        create_issue(%{
          title: "Board dependent",
          description: "waiting on blocker",
          status: :blocked,
          priority: :high,
          assignee_id: agent.id
        })

      assert {:ok, _} = Issues.add_blocker(dependent, blocker)

      {:ok, view, _html} = live(conn(), "/kanban")

      view
      |> element("#kanban-board")
      |> render_hook("transition_issue", %{"id" => blocker.id, "to_status" => "cancelled"})

      # Flush PubSub (status + pending_wakes_changed) into the LiveView.
      html = render(view)

      reloaded_blocker = Issues.get_issue!(blocker.id)
      reloaded_dependent = Issues.get_issue!(dependent.id)
      assert reloaded_blocker.status == :cancelled
      assert reloaded_dependent.status == :todo

      wakes =
        from(w in Cympho.Wakes.AgentWake,
          where:
            w.issue_id == ^dependent.id and w.reason == "issue_blockers_resolved" and
              w.status == "pending"
        )
        |> Repo.all()

      assert length(wakes) == 1
      assert hd(wakes).agent_id == agent.id

      # Board should surface the pending wake badge on the unblocked card.
      assert html =~ "Board dependent"
      assert html =~ "⏱" or html =~ "Waiting"
    end

    test "completing a blocker via board reopens dependent for dispatch" do
      {:ok, agent} =
        create_agent(%{
          name: "Done Blocker Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, blocker} =
        create_issue(%{
          title: "Done-path blocker",
          description: "will complete",
          status: :in_review,
          priority: :medium
        })

      {:ok, dependent} =
        create_issue(%{
          title: "Done-path dependent",
          description: "waiting",
          status: :blocked,
          priority: :high,
          assignee_id: agent.id
        })

      assert {:ok, _} = Issues.add_blocker(dependent, blocker)

      # Bypass review gates for the blocker itself — board uses review gates,
      # so seed a completed runtime evidence path is heavier; use transition_issue
      # for the terminal step while the board is mounted to still exercise wakes
      # + LiveView pending_wakes_changed.
      {:ok, view, _html} = live(conn(), "/kanban")
      assert {:ok, _} = Issues.transition_issue(Issues.get_issue!(blocker.id), :done)

      html = render(view)
      reloaded_dependent = Issues.get_issue!(dependent.id)
      assert reloaded_dependent.status == :todo
      refute Issues.is_blocked?(reloaded_dependent)

      wakes =
        from(w in Cympho.Wakes.AgentWake,
          where:
            w.issue_id == ^dependent.id and w.reason == "issue_blockers_resolved" and
              w.status == "pending"
        )
        |> Repo.all()

      assert length(wakes) == 1
      assert html =~ "Done-path dependent"
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

    test "swimlane cards emit data-status and data-allowed-statuses matching StateMachine" do
      {:ok, agent} =
        create_agent(%{
          name: "Swimlane DnD Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, in_progress} =
        create_issue(%{
          title: "Swimlane in flight",
          description: "allow-list for DnD",
          status: :in_progress,
          priority: :medium,
          assignee_id: agent.id
        })

      {:ok, done} =
        create_issue(%{
          title: "Swimlane done",
          description: "terminal allow-list",
          status: :done,
          priority: :low,
          assignee_id: agent.id
        })

      {:ok, view, _html} = live(conn(), "/kanban")
      view |> element("#kanban-board") |> render_hook("toggle_swimlanes", %{})
      html = render(view)
      doc = Floki.parse_document!(html)

      in_progress_card =
        doc
        |> Floki.find("[data-kanban-card][data-issue-id='#{in_progress.id}']")
        |> List.first()

      assert in_progress_card

      assert Floki.attribute(in_progress_card, "data-status") |> List.first() == "in_progress"

      allowed = Floki.attribute(in_progress_card, "data-allowed-statuses") |> List.first()
      assert is_binary(allowed)
      refute allowed == ""

      expected =
        Cympho.Issues.StateMachine.valid_transitions(:in_progress)
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      actual = allowed |> String.split(",", trim: true) |> MapSet.new()
      assert actual == expected
      assert "todo" in MapSet.to_list(actual)
      assert "backlog" in MapSet.to_list(actual)

      done_card =
        doc
        |> Floki.find("[data-kanban-card][data-issue-id='#{done.id}']")
        |> List.first()

      assert done_card
      assert Floki.attribute(done_card, "data-status") |> List.first() == "done"

      done_allowed = Floki.attribute(done_card, "data-allowed-statuses") |> List.first()

      done_expected =
        Cympho.Issues.StateMachine.valid_transitions(:done)
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      assert done_allowed |> String.split(",", trim: true) |> MapSet.new() == done_expected
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

  describe "submit_comment" do
    test "creates a company-scoped comment authored by the current user", %{
      issue_todo: issue
    } do
      {:ok, user} = Cympho.Users.get_user(Plug.Conn.get_session(conn(), :user_id))
      {:ok, view, _html} = live(conn(), "/kanban")

      render_submit(view, "submit_comment", %{
        "issue-id" => issue.id,
        "comment" => "Hello from board"
      })

      comments = Comments.list_comments(issue.id)
      assert [%{body: "Hello from board", author_type: "user", author_id: author_id}] = comments
      assert author_id == user.id
    end

    test "rejects comments on issues outside the current company" do
      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Foreign Kanban Co #{System.unique_integer([:positive])}",
          slug: "foreign-kanban-#{System.unique_integer([:positive])}"
        })

      {:ok, foreign} =
        Issues.create_issue(%{
          title: "Foreign issue",
          description: "other tenant",
          company_id: other_company.id,
          status: :todo
        })

      {:ok, view, _html} = live(conn(), "/kanban")

      html =
        render_submit(view, "submit_comment", %{
          "issue-id" => foreign.id,
          "comment" => "Should not persist"
        })

      assert html =~ "Issue not found or unauthorized"
      assert Comments.list_comments(foreign.id) == []
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
    test "a tuple-only move into the selected project loads its assignee heartbeat", %{
      project: project
    } do
      {:ok, other} = create_project(%{name: "Heartbeat source", prefix: "HB"})

      {:ok, agent} =
        create_agent(%{
          name: "Moved running owner",
          role: :engineer,
          status: :idle,
          adapter: :process
        })

      {:ok, issue} =
        create_issue(%{
          title: "Moving running card",
          description: "Tuple-only project move",
          status: :todo,
          project_id: other.id,
          assignee_id: agent.id
        })

      assert {:ok, heartbeat_pid} = AgentHeartbeat.start_for_agent(agent.id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, heartbeat_pid, self())
      on_exit(fn -> AgentHeartbeat.stop_for_agent(agent.id) end)
      assert :ok = AgentHeartbeat.set_working(agent.id, issue.id)

      {:ok, view, initial_html} = live(conn(), "/kanban?project_id=#{project.id}")
      refute initial_html =~ "Moving running card"

      moved = issue |> Ecto.Changeset.change(project_id: project.id) |> Repo.update!()
      send(view.pid, {:issue_updated, moved})

      [card] =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("[data-kanban-card][data-issue-id='#{issue.id}']")

      assert Floki.raw_html(card) =~ "Moved running owner · engineer · running"
    end

    test "initial board load queries issues once per LiveView mount phase", %{
      current_company: company
    } do
      handler_id = "kanban-query-count-#{System.unique_integer([:positive])}"
      company_id = Ecto.UUID.dump!(company.id)
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:cympho, :repo, :query],
        fn _event, _measurements, metadata, {pid, scoped_id} ->
          if String.contains?(
               metadata.query || "",
               ~s|WHERE (i0."company_id" = $1) LIMIT $2|
             ) and
               scoped_id in (metadata.params || []) do
            send(pid, {:board_issue_list_query, metadata.query})
          end
        end,
        {test_pid, company_id}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, _view, html} = live(conn(), "/kanban")
      assert html =~ "Backlog Issue"
      assert html =~ "Todo Issue"

      queries = drain_board_issue_queries([])
      assert length(queries) == 2
    end

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

    test "tuple-only updates respect the selected project and preserve card order", %{
      project: project,
      issue_backlog: backlog,
      issue_todo: todo
    } do
      {:ok, other} = create_project(%{name: "Tuple Project", prefix: "TU"})
      {:ok, view, _html} = live(conn(), "/kanban?project_id=#{project.id}")

      send(view.pid, {:issue_updated, %{backlog | project_id: other.id}})
      html = render(view)
      refute html =~ "Backlog Issue"
      assert html =~ "Todo Issue"

      send(view.pid, {
        :issue_created,
        %{backlog | id: Ecto.UUID.generate(), project_id: project.id, title: "New in project"}
      })

      html = render(view)
      assert html =~ "New in project"
      assert html =~ "Todo Issue"
      refute html =~ "Backlog Issue"

      send(view.pid, {:issue_deleted, todo.id})
      refute render(view) =~ "Todo Issue"
    end

    test "endpoint-only issue event reloads changed card data", %{issue_backlog: issue} do
      {:ok, view, _html} = live(conn(), "/kanban")

      issue
      |> Ecto.Changeset.change(title: "Endpoint-only title")
      |> Repo.update!()

      send(view.pid, %Phoenix.Socket.Broadcast{
        topic: "company:#{issue.company_id}:issues",
        event: "issue_update",
        payload: %{resource_id: issue.id, event_type: :issue_updated}
      })

      assert render(view) =~ "Endpoint-only title"
    end

    test "endpoint issue event without a payload still refreshes the board", %{
      issue_backlog: issue
    } do
      {:ok, view, _html} = live(conn(), "/kanban")

      issue
      |> Ecto.Changeset.change(title: "Payload-free title")
      |> Repo.update!()

      send(view.pid, %Phoenix.Socket.Broadcast{
        topic: "company:#{issue.company_id}:issues",
        event: "issue_update",
        payload: nil
      })

      assert render(view) =~ "Payload-free title"
    end

    test "independent same-field Endpoint update after tuple-only update is not discarded", %{
      issue_backlog: issue
    } do
      {:ok, view, _html} = live(conn(), "/kanban")

      tuple_issue = issue |> Ecto.Changeset.change(title: "Tuple-only title") |> Repo.update!()
      send(view.pid, {:issue_updated, tuple_issue})
      assert render(view) =~ "Tuple-only title"

      tuple_issue
      |> Ecto.Changeset.change(github_pr_url: "https://example.com/independent-pr")
      |> Repo.update!()

      send(view.pid, %Phoenix.Socket.Broadcast{
        topic: "company:#{issue.company_id}:issues",
        event: "issue_update",
        payload: %{
          resource_id: issue.id,
          event_type: :issue_updated,
          title: tuple_issue.title,
          status: tuple_issue.status,
          priority: tuple_issue.priority,
          identifier: tuple_issue.identifier,
          assignee_id: tuple_issue.assignee_id,
          project_id: tuple_issue.project_id
        }
      })

      assert render(view) =~ ~s(href="https://example.com/independent-pr")
    end

    test "endpoint-only project moves remove and restore the selected card", %{
      project: project,
      issue_backlog: issue
    } do
      {:ok, other} = create_project(%{name: "Endpoint project", prefix: "EP"})
      {:ok, view, html} = live(conn(), "/kanban?project_id=#{project.id}")
      assert html =~ "Backlog Issue"

      moved_out = issue |> Ecto.Changeset.change(project_id: other.id) |> Repo.update!()

      send(view.pid, %Phoenix.Socket.Broadcast{
        topic: "company:#{issue.company_id}:issues",
        event: "issue_update",
        payload: %{resource_id: issue.id}
      })

      refute render(view) =~ "Backlog Issue"

      moved_out |> Ecto.Changeset.change(project_id: project.id) |> Repo.update!()

      send(view.pid, %Phoenix.Socket.Broadcast{
        topic: "company:#{issue.company_id}:issues",
        event: "issue_update",
        payload: %{resource_id: issue.id}
      })

      assert render(view) =~ "Backlog Issue"
    end

    test "endpoint-only update removes a deleted card", %{issue_backlog: issue} do
      {:ok, view, html} = live(conn(), "/kanban")
      assert html =~ "Backlog Issue"
      Repo.delete!(issue)

      send(view.pid, %Phoenix.Socket.Broadcast{
        topic: "company:#{issue.company_id}:issues",
        event: "issue_update",
        payload: %{resource_id: issue.id}
      })

      refute render(view) =~ "Backlog Issue"
    end
  end

  describe "Board refresh cost" do
    test "tuple refresh shows a changed assignee even when the old issue had preloads", %{
      issue_todo: issue
    } do
      {:ok, first} =
        create_agent(%{
          name: "First board owner",
          role: :engineer,
          status: :idle,
          adapter: :process
        })

      {:ok, second} =
        create_agent(%{
          name: "Second board owner",
          role: :engineer,
          status: :idle,
          adapter: :process
        })

      assert {:ok, _} = Issues.update_issue(issue, %{assignee_id: first.id})
      {:ok, view, html} = live(conn(), "/kanban")
      assert html =~ "First board owner"

      loaded_issue =
        Issues.list_issues(%{company_id: issue.company_id})
        |> Enum.find(&(&1.id == issue.id))

      assert loaded_issue.assignee.id == first.id
      assert {:ok, _} = Issues.update_issue(loaded_issue, %{assignee_id: second.id})

      html = render(view)

      [card] =
        html
        |> Floki.parse_document!()
        |> Floki.find("[data-kanban-card][data-issue-id='#{issue.id}']")

      card_html = Floki.raw_html(card)
      assert card_html =~ "Second board owner"
      refute card_html =~ "First board owner"
    end

    test "a tuple and matching endpoint event do not fetch the board twice", %{
      current_company: company,
      issue_backlog: issue
    } do
      {:ok, view, _html} = live(conn(), "/kanban")
      handler_id = "kanban-event-query-#{System.unique_integer([:positive])}"
      company_id = Ecto.UUID.dump!(company.id)
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:cympho, :repo, :query],
        fn _event, _measurements, metadata, {pid, scoped_id} ->
          if String.contains?(
               metadata.query || "",
               ~s|WHERE (i0."company_id" = $1) LIMIT $2|
             ) and
               scoped_id in (metadata.params || []) do
            send(pid, {:board_issue_list_query, metadata.query})
          end
        end,
        {test_pid, company_id}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, updated} = Issues.update_issue(issue, %{title: "Updated once"})
      assert render(view) =~ updated.title
      assert drain_board_issue_queries([]) == []
    end

    test "a paired Endpoint event does not rebuild unchanged card digests", %{
      issue_backlog: issue
    } do
      {:ok, view, _html} = live(conn(), "/kanban")
      updated = issue |> Ecto.Changeset.change(title: "Tuple result") |> Repo.update!()
      send(view.pid, {:issue_updated, updated})
      assert render(view) =~ "Tuple result"

      :erlang.trace_pattern({Cympho.IssueDigest, :build, 5}, true, [:local])
      :erlang.trace(view.pid, true, [:call])

      on_exit(fn ->
        if Process.alive?(view.pid), do: :erlang.trace(view.pid, false, [:call])
        :erlang.trace_pattern({Cympho.IssueDigest, :build, 5}, false, [:local])
      end)

      send(view.pid, %Phoenix.Socket.Broadcast{
        topic: "company:#{issue.company_id}:issues",
        event: "issue_update",
        payload: %{resource_id: issue.id}
      })

      assert render(view) =~ "Tuple result"
      assert drain_digest_calls(0) == 0
    end

    test "non-issue render reuses card and shared-banner digests" do
      {:ok, view, _html} = live(conn(), "/kanban?density=detailed")
      :erlang.trace_pattern({Cympho.IssueDigest, :build, 5}, true, [:local])
      :erlang.trace(view.pid, true, [:call])

      on_exit(fn ->
        if Process.alive?(view.pid), do: :erlang.trace(view.pid, false, [:call])
        :erlang.trace_pattern({Cympho.IssueDigest, :build, 5}, false, [:local])
      end)

      html = view |> element("#kanban-board") |> render_hook("toggle_swimlanes", %{})
      assert html =~ "Backlog Issue"
      assert html =~ "Todo Issue"
      assert drain_digest_calls(0) == 0
    end
  end

  defp drain_board_issue_queries(queries) do
    receive do
      {:board_issue_list_query, query} -> drain_board_issue_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp drain_digest_calls(count) do
    receive do
      {:trace, _pid, :call, {Cympho.IssueDigest, :build, _args}} ->
        drain_digest_calls(count + 1)
    after
      0 -> count
    end
  end
end
