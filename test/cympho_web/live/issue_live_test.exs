defmodule CymphoWeb.IssueLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Issues
  alias Cympho.Comments
  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Inbox
  alias Cympho.Projects
  alias Cympho.Repo
  alias Cympho.Users
  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake
  alias Cympho.WorkProducts

  defp create_agent(attrs), do: Agents.create_agent(scoped_attrs(attrs))
  defp create_issue(attrs), do: Issues.create_issue(scoped_attrs(attrs))
  defp create_project(attrs), do: Projects.create_project(scoped_attrs(attrs))

  setup do
    {:ok, issue} =
      create_issue(%{
        title: "Test Issue",
        description: "Test description for the issue",
        status: :backlog,
        priority: :high
      })

    %{issue: issue}
  end

  describe "Index - Issue List" do
    test "renders all issues", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "All Issues"
      assert html =~ issue.title
    end

    test "shows issue status badges", %{issue: _issue} do
      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "backlog"
      assert html =~ "high"
    end

    test "shows comment count", %{issue: _issue} do
      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "0 comments"
    end

    test "shows compact owner-flow digest on CEO-owned rows" do
      {:ok, ceo} =
        create_agent(%{
          name: "List CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, _issue} =
        create_issue(%{
          title: "List owner request",
          description: "CEO should produce the first owner signal.",
          status: :todo,
          priority: :high,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "List owner request"
      assert html =~ "List CEO"
      assert html =~ "Launch needed"
      assert html =~ "Assigned, but runtime has not started yet."
    end

    test "shows owner triage lanes and filters the CEO lane", %{current_company: company} do
      {:ok, _ceo_issue} =
        create_issue(%{
          title: "CEO triage lane request",
          description: "Owner work should stay easy to find.",
          status: :todo,
          priority: :high,
          assigned_role: "ceo",
          company_id: company.id
        })

      {:ok, _engineer_issue} =
        create_issue(%{
          title: "Engineer triage lane request",
          description: "Implementation work should not appear in the CEO lane.",
          status: :todo,
          priority: :medium,
          assigned_role: "engineer",
          company_id: company.id
        })

      {:ok, view, html} = live(conn(), "/issues")

      assert html =~ "Owner triage"
      assert html =~ "Jump straight to the queue that needs the next decision."
      assert html =~ "CEO lane"
      assert html =~ "Ready"
      assert html =~ "Blocked"
      assert html =~ "Unassigned"

      view
      |> element("a[href='/issues?triage=ceo']", "CEO lane")
      |> render_click()

      assert_patch(view, "/issues?triage=ceo")

      html = render(view)
      assert html =~ "CEO triage lane request"
      refute html =~ "Engineer triage lane request"
      assert html =~ "Show all issues"
    end
  end

  describe "New - Owner request routing" do
    test "renders a live-updating document title on first load" do
      html =
        conn()
        |> get("/issues/new")
        |> html_response(200)

      assert html =~ ~s(<title data-suffix=" · Cympho">New Issue · Cympho</title>)
    end

    test "creates authenticated company issues as CEO-owned todo work" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Owner Route Co",
          slug: "owner-route-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        create_project(%{
          name: "Operating Project",
          prefix: "OR",
          company_id: company.id
        })

      {:ok, launch_project} =
        create_project(%{
          name: "Launch Project",
          prefix: "LP",
          company_id: company.id
        })

      {:ok, user} =
        Users.create_user(%{
          email: "owner-route-#{System.unique_integer([:positive])}@example.com",
          name: "Owner"
        })

      {:ok, _membership} =
        Companies.create_membership(%{
          user_id: user.id,
          company_id: company.id,
          role: "owner",
          is_board_member: true
        })

      {:ok, ceo} =
        create_agent(%{
          name: "CEO",
          role: :ceo,
          status: :idle,
          company_id: company.id,
          project_id: project.id
        })

      conn =
        conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)

      {:ok, view, html} = live(conn, "/issues/new")

      assert html =~ "Owner intake"
      assert html =~ "First stop:"
      assert html =~ "CEO"
      assert html =~ "CEO first turn must return"
      assert html =~ "[owner_update]"
      assert html =~ "[handoff]"
      assert html =~ "2-5 scoped issues"
      assert html =~ "Owner request -&gt; CEO lane"
      assert html =~ "Creates a To Do issue; no provider call."
      assert html =~ "Opens the issue with CEO flow status."
      assert html =~ "Signals the CEO should produce:"
      assert html =~ "Goal:\nContext:"
      refute html =~ "Goal:\\nContext:"
      assert html =~ "Project"
      assert html =~ "Operating Project"
      assert html =~ "Launch Project"

      result =
        view
        |> form("form", %{
          "issue" => %{
            "title" => "Owner asks for onboarding",
            "description" => "CEO should decompose this.",
            "project_id" => launch_project.id
          }
        })
        |> render_submit()

      [created] = Issues.list_issues(%{company_id: company.id})
      assert created.title == "Owner asks for onboarding"
      assert created.status == :todo
      assert created.assignee_id == ceo.id
      assert created.assigned_role == "ceo"
      assert created.project_id == launch_project.id
      assert created.created_by_user_id == user.id

      expected_path = "/issues/#{created.id}"
      assert {:error, {:live_redirect, %{to: ^expected_path}}} = result
    end

    test "keeps owner-created issues in CEO lane when no CEO agent exists" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Owner Route No CEO Co",
          slug: "owner-route-no-ceo-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        create_project(%{
          name: "No CEO Project",
          prefix: "NC",
          company_id: company.id
        })

      {:ok, user} =
        Users.create_user(%{
          email: "owner-route-no-ceo-#{System.unique_integer([:positive])}@example.com",
          name: "Owner"
        })

      {:ok, _membership} =
        Companies.create_membership(%{
          user_id: user.id,
          company_id: company.id,
          role: "owner",
          is_board_member: true
        })

      conn =
        conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)

      {:ok, view, html} = live(conn, "/issues/new")

      assert html =~ "Owner intake"
      assert html =~ "CEO lane"
      assert html =~ "CEO agent missing"
      assert html =~ "Add CEO agent"
      assert html =~ ~s(href="/agents/new")
      assert html =~ "Creates a CEO-role To Do issue; no provider call."
      assert html =~ "Opens the issue with the CEO setup blocker visible."
      assert html =~ "will stay in the CEO lane"

      result =
        view
        |> form("form", %{
          "issue" => %{
            "title" => "Owner asks without CEO",
            "description" => "CEO should still own this request.",
            "project_id" => project.id
          }
        })
        |> render_submit()

      [created] = Issues.list_issues(%{company_id: company.id})
      assert created.title == "Owner asks without CEO"
      assert created.status == :todo
      assert is_nil(created.assignee_id)
      assert created.assigned_role == "ceo"
      assert created.project_id == project.id
      assert created.created_by_user_id == user.id

      expected_path = "/issues/#{created.id}"
      assert {:error, {:live_redirect, %{to: ^expected_path}}} = result
    end
  end

  describe "Show - Issue Detail" do
    test "renders issue detail", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ issue.title
      assert html =~ issue.description
      assert html =~ "backlog"
      assert html =~ "high"
    end

    test "shows focused runtime command for dispatchable issues in review mode" do
      {:ok, issue} =
        create_issue(%{
          title: "Run only this CEO issue",
          status: :todo,
          priority: :high
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Focus this issue"
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"
      assert html =~ "CYMPHO_ORCHESTRATOR_ENABLED=1"
      assert html =~ ~s(id="issue-focused-runtime-command-#{issue.id}")
      assert html =~ ~s(phx-hook="CopyToClipboard")
      assert html =~ "Copy command"
    end

    test "prioritizes a dispatchable issue from the sidebar" do
      {:ok, issue} =
        create_issue(%{
          title: "Operator focus issue",
          status: :todo,
          priority: :high
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Dispatch focus"
      assert html =~ "Prioritize for next dispatch"

      html =
        view
        |> element("#issue-agent-panel button", "Prioritize for next dispatch")
        |> render_click()

      assert html =~
               "Issue prioritized for next dispatch. Copy the focused command from the digest or sidebar and start runtime."

      assert html =~ "Operator focus active"
      assert html =~ "Focus queued"
      assert html =~ "Dispatch focus is pinned, but autonomous dispatch is disabled."
      assert html =~ "Start the focused runtime command from the digest or sidebar"

      updated = Issues.get_issue!(issue.id)
      assert Issues.dispatch_pinned?(updated)
    end

    test "queues open delegated sub-issues from the parent review gate" do
      {:ok, product_owner} =
        create_agent(%{
          name: "Delegated Product Owner",
          role: :product_manager,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, cto_owner} =
        create_agent(%{
          name: "Delegated CTO Owner",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, parent} =
        create_issue(%{
          title: "Delegated parent issue",
          status: :blocked,
          priority: :high,
          assigned_role: "ceo"
        })

      {:ok, product_child} =
        create_issue(%{
          title: "Define delegated success metrics",
          status: :todo,
          priority: :high,
          parent_id: parent.id,
          assigned_role: "product_manager"
        })

      {:ok, cto_child} =
        create_issue(%{
          title: "Verify delegated runtime path",
          status: :todo,
          priority: :high,
          parent_id: parent.id,
          assignee_id: cto_owner.id,
          assigned_role: "cto"
        })

      {:ok, blocked_child} =
        create_issue(%{
          title: "Wait for blocked dependency",
          status: :todo,
          priority: :critical,
          parent_id: parent.id,
          assigned_role: "cto"
        })

      {:ok, closed_child} =
        create_issue(%{
          title: "Already closed child",
          status: :done,
          priority: :medium,
          parent_id: parent.id,
          assigned_role: "engineer"
        })

      {:ok, dependency} =
        create_issue(%{
          title: "Dependency still active",
          status: :todo,
          priority: :medium
        })

      assert {:ok, _blocked_child} = Issues.add_blocker(blocked_child, dependency)
      assert {:ok, _cto_child} = Issues.prioritize_for_dispatch(cto_child)

      {:ok, view, html} = live(conn(), "/issues/#{parent.id}")

      assert html =~ "Queue runnable sub-issues"
      assert html =~ "Open sub-issues"
      assert html =~ "Open delegated queue"
      assert html =~ ~s(href="/operations?parent_issue_id=#{parent.id}#delegated-work-queue")

      html =
        view
        |> element("#issue-digest-actions button", "Queue runnable sub-issues")
        |> render_click()

      assert html =~
               "Queued 1 runnable sub-issue for focused dispatch. Start runtime from Operations to continue delegated work."

      assert html =~ ~s(id="child-dispatch-focus-#{product_child.id}")
      assert html =~ ~s(id="child-dispatch-focus-#{cto_child.id}")
      refute html =~ ~s(id="child-dispatch-focus-#{blocked_child.id}")
      refute html =~ ~s(id="child-dispatch-focus-#{closed_child.id}")
      assert html =~ ~s(id="child-copy-focused-command-#{product_child.id}")
      assert html =~ ~s(id="child-copy-focused-command-#{cto_child.id}")
      refute html =~ ~s(id="child-copy-focused-command-#{blocked_child.id}")
      refute html =~ ~s(id="child-copy-focused-command-#{closed_child.id}")
      assert html =~ ~s(id="child-clear-dispatch-focus-#{product_child.id}")
      assert html =~ ~s(id="child-clear-dispatch-focus-#{cto_child.id}")
      refute html =~ ~s(id="child-clear-dispatch-focus-#{blocked_child.id}")
      refute html =~ ~s(id="child-clear-dispatch-focus-#{closed_child.id}")
      assert html =~ ~s(id="child-focused-command-text-#{product_child.id}")
      assert html =~ ~s(id="child-focused-command-text-#{cto_child.id}")
      refute html =~ ~s(id="child-focused-command-text-#{blocked_child.id}")
      refute html =~ ~s(id="child-focused-command-text-#{closed_child.id}")
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{product_child.id}"
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{cto_child.id}"
      refute html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{blocked_child.id}"
      refute html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{closed_child.id}"
      assert html =~ "Delegated Product Owner"
      assert html =~ "Delegated CTO Owner"

      product_child = Issues.get_issue!(product_child.id)
      cto_child = Issues.get_issue!(cto_child.id)
      blocked_child = Issues.get_issue!(blocked_child.id)

      assert product_child.assignee_id == product_owner.id
      assert product_child.status == :todo
      assert cto_child.assignee_id == cto_owner.id
      assert cto_child.status == :todo
      assert blocked_child.assignee_id == nil
      assert blocked_child.status == :todo
      assert Issues.dispatch_pinned?(product_child)
      assert Issues.dispatch_pinned?(cto_child)
      refute Issues.dispatch_pinned?(blocked_child)
      refute closed_child.id |> Issues.get_issue!() |> Issues.dispatch_pinned?()

      html =
        view
        |> element("#child-clear-dispatch-focus-#{product_child.id}", "Clear focus")
        |> render_click()

      assert html =~ "Dispatch focus cleared for child issue."
      refute html =~ ~s(id="child-dispatch-focus-#{product_child.id}")
      refute html =~ ~s(id="child-copy-focused-command-#{product_child.id}")
      refute html =~ ~s(id="child-clear-dispatch-focus-#{product_child.id}")
      assert html =~ ~s(id="child-dispatch-focus-#{cto_child.id}")
      assert html =~ "Queue runnable sub-issues"

      refute product_child.id |> Issues.get_issue!() |> Issues.dispatch_pinned?()
      assert cto_child.id |> Issues.get_issue!() |> Issues.dispatch_pinned?()

      html =
        view
        |> element("#issue-digest-actions button", "Queue runnable sub-issues")
        |> render_click()

      assert html =~ "Queued 1 runnable sub-issue for focused dispatch."
      assert html =~ "No runnable sub-issues"
      assert html =~ "Open child work is already focused or blocked by active dependencies."

      assert has_element?(
               view,
               "#issue-digest-actions button[disabled]",
               "No runnable sub-issues"
             )
    end

    test "shows assigned agent runtime readiness on issue detail" do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO",
          role: :ceo,
          status: :idle,
          adapter: :claude_code,
          health_status: :degraded,
          config: %{"command" => "cz"},
          runtime_config: %{
            "profile_id" => "claude-cz",
            "env" => %{"ANTHROPIC_MODEL" => "cheap-ceo-model"}
          },
          max_concurrent_jobs: 2,
          adapter_failure_count: 3
        })

      {:ok, issue} =
        create_issue(%{
          title: "CEO runtime readiness",
          status: :todo,
          priority: :high,
          assignee_id: ceo.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Agent readiness"
      assert html =~ "CEO"
      assert html =~ "Review mode"
      assert html =~ "Claude Code · 2 local CLI slots"
      assert html =~ "Claude-compatible via cz"
      assert html =~ "cz"
      assert html =~ "cheap-ceo-model"
      assert html =~ "ANTHROPIC_API_KEY"
      assert html =~ "Prior adapter health: Degraded"
      assert html =~ "Recent adapter failures: 3"
      assert html =~ "Open agent config"
    end

    test "shows a local CEO launch preview before provider dispatch" do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO Preview",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Preview CEO handoff",
          status: :todo,
          priority: :high,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "CEO flow"
      assert html =~ "Owner request loop"
      assert html =~ "Owner request captured"
      assert html =~ "Routed to CEO Preview in the CEO lane."
      assert html =~ "Launch CEO turn"
      assert html =~ "Launch needed"
      assert html =~ "Waiting for owner signal"
      assert html =~ "Decision pending"
      assert html =~ "CEO launch preview"
      assert html =~ "Local dry-run"
      assert html =~ "CEO Preview · Process"
      assert html =~ "Review mode"
      assert html =~ "Review mode is active; copy the focused command"
      assert html =~ "Next setup action"
      assert html =~ "Execution mode"
      assert html =~ "Open service gates"
      assert html =~ ~s(href="/operations#runtime-services")
      assert html =~ "[owner_update]"
      assert html =~ "[handoff]"
      assert html =~ "2-5 scoped sub-issues"
      assert html =~ "No provider call"
      assert html =~ ~s(phx-hook="CopyToClipboard")
      assert html =~ "Copy CEO brief"
      assert html =~ "CEO launch brief"
      assert html =~ "Focused command:"
      assert html =~ "No description supplied."
      assert html =~ "Draft owner update"
      assert html =~ "Draft handoff"

      html =
        view
        |> element("#issue-ceo-launch-preview button[phx-value-template='owner_update']")
        |> render_click()

      assert html =~ "[owner_update] What happened:"
      assert html =~ "Business status:"
      assert html =~ "Owner decision needed:"

      html =
        view
        |> element("#issue-ceo-launch-preview button[phx-value-template='handoff']")
        |> render_click()

      assert html =~ "[handoff] What happened:"
      assert html =~ "Next owner:"
    end

    test "shows CEO setup blocker on issue detail when no CEO agent exists" do
      {:ok, issue} =
        create_issue(%{
          title: "Owner request without CEO agent",
          status: :todo,
          priority: :high,
          assigned_role: "ceo"
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "CEO flow"
      assert html =~ "Routed to the CEO lane"
      assert html =~ "CEO launch preview"
      assert html =~ "No agent"
      assert html =~ "No idle eligible CEO is available"
      assert html =~ "Next setup action"
      assert html =~ "Dispatch eligibility"
      assert html =~ "eligible CEO"
      assert html =~ "Add CEO agent"
      assert html =~ ~s(href="/agents/new")
      assert html =~ "Waiting for first CEO turn"
    end

    test "shows CEO outcome card from the latest owner update" do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO Outcome",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "CEO outcome issue",
          status: :in_progress,
          priority: :high,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[owner_update] What happened: strategy is framed. Business status: not shipped. Current state: ready to delegate. Next decision: hand off implementation. Owner decision needed: none.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "CEO flow"
      assert html =~ "CEO turn completed"
      assert html =~ "Owner update captured"
      assert html =~ "Owner decision ready"
      assert html =~ "CEO outcome"
      assert html =~ "Owner update"
      assert html =~ "CEO left an owner-facing status update"
      assert html =~ "strategy is framed"
      assert html =~ "Use this update as the current business status"
      assert html =~ "Open Operations monitor"
      assert html =~ ~s(href="/operations#ceo-outcome-monitor")
    end

    test "accepts and closes CEO owner-verification handbacks from the digest" do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO Owner Verifier",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Close owner verification",
          description: "Owner should verify the CEO first turn.",
          status: :blocked,
          priority: :high,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      Repo.insert!(%Run{
        agent_id: ceo.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "openai_chat",
        continuation_summary: "CEO owner update produced."
      })

      {:ok, _owner_update} =
        Comments.create_comment(%{
          body:
            "[owner_update] What happened: CEO produced the first turn. Business status: not shipped. Current state: waiting on owner verification. Next decision: owner accepts and closes. Owner decision needed: verify.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      {:ok, _blocked} =
        Comments.create_comment(%{
          body:
            "[blocked] Cause: Waiting for owner to verify the smoke test output. Current state: blocked on owner verification. Next decision: owner closes after verification.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Accept and close"
      assert html =~ "owner verification"

      html =
        view
        |> element("#issue-digest-actions button", "Accept and close")
        |> render_click()

      assert html =~ "Owner verification accepted and issue closed."
      assert Issues.get_issue!(issue.id).status == :done
      assert html =~ "Closed"
      assert html =~ "owner accepted the CEO verification update"
    end

    test "shows CEO outcome card when the latest CEO run needs attention" do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO Needs Attention",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "CEO failed runtime issue",
          status: :blocked,
          priority: :critical,
          assigned_role: "ceo"
        })

      Repo.insert!(%Run{
        agent_id: ceo.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "failed",
        adapter: "process",
        error_reason: "OPENAI_API_KEY not set"
      })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "CEO flow"
      assert html =~ "Runtime needs attention"
      assert html =~ "Owner signal blocked"
      assert html =~ "Decision blocked"
      assert html =~ "CEO outcome"
      assert html =~ "Needs attention"
      assert html =~ "CEO runtime needs attention"
      assert html =~ "Failed · OPENAI_API_KEY not set"
      assert html =~ "Fix the runtime/provider issue, then relaunch from the focused command."
      assert html =~ "Focused relaunch command"
      assert html =~ "Fix the feedback above, then restart runtime focused on this issue."
      assert html =~ "Setup still needs"
      assert html =~ "Execution mode"
      assert html =~ "Open service gates"
      assert html =~ ~s(href="/operations#runtime-services")
      assert html =~ "Reopen and prioritize relaunch"
      assert html =~ ~s(id="issue-ceo-outcome-focused-command-#{issue.id}")
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"
      assert html =~ "Open Operations monitor"

      html =
        view
        |> element(
          "#issue-ceo-outcome-focused-command-#{issue.id} button",
          "Reopen and prioritize relaunch"
        )
        |> render_click()

      assert html =~
               "Issue queued for focused relaunch. Copy the focused command from this issue page and start runtime."

      assert html =~ "Relaunch focus queued"
      assert html =~ "Setup still needs"
      assert html =~ "Execution mode"

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :todo
      assert Issues.dispatch_pinned?(updated)
    end

    test "points todo issues without runs at runtime launch before evidence actions" do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "CEO needs first runtime pass",
          description: "Owner asks CEO to define the execution plan.",
          status: :todo,
          priority: :high,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Start runtime first"
      assert html =~ "Launch needed"
      assert html =~ "Assigned, but runtime has not started yet."
      assert html =~ "Open the Operations launch checklist"
      assert html =~ "first output must be `[owner_update]` or `[handoff]`"
      assert html =~ ~s(id="issue-digest-actions")
      assert html =~ ~s(phx-hook="CopyToClipboard")
      assert html =~ "Queue focused dispatch"
      assert html =~ ~s(phx-click="prioritize_dispatch")
      assert html =~ "Copy focused command"
      assert html =~ ~s(data-copy-label="Copy focused command")
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"
      assert html =~ "Open launch checklist"
      assert html =~ ~s(href="/operations#runtime-launch-checklist")
      assert html =~ "CEO first turn"
      assert html =~ "CEO has not produced the first owner-facing signal yet."
      assert html =~ "Start the CEO turn before assigning delivery."
      assert html =~ "no runtime evidence yet"
      assert html =~ "Runtime launch needed"

      assert html =~
               "Start runtime from the digest, sidebar, or Operations before adding delivery notes or artifacts."

      refute html =~
               "Start focused dispatch from Operations before adding delivery notes or artifacts."

      refute html =~ "Auto-nudges"
      refute html =~ "Add completion note"
      refute html =~ "Nudge delivery owner"

      html =
        view
        |> element("#issue-digest-actions button[phx-click='prioritize_dispatch']")
        |> render_click()

      assert html =~
               "Issue prioritized for next dispatch. Copy the focused command from the digest or sidebar and start runtime."

      assert html =~ "Operator focus active"
      assert html =~ "Focus queued"
      assert html =~ "Focused dispatch is queued. Copy the focused command or start runtime"
      assert html =~ "Focused dispatch is already queued for this issue."
      assert html =~ "Focused dispatch is already queued; copy the command or start runtime."
      assert has_element?(view, "#issue-digest-actions button[disabled]", "Focus queued")
      assert html =~ "Clear focus"

      updated = Issues.get_issue!(issue.id)
      assert Issues.dispatch_pinned?(updated)

      html =
        view
        |> element("button[phx-click='clear_dispatch_focus']", "Clear focus")
        |> render_click()

      assert html =~ "Dispatch focus cleared."
      assert html =~ "Queue focused dispatch"
      refute html =~ "Operator focus active"

      updated = Issues.get_issue!(issue.id)
      refute Issues.dispatch_pinned?(updated)
    end

    test "shows CEO launch setup action for missing provider credentials" do
      {:ok, ceo} =
        create_agent(%{
          name: "Remote CEO",
          role: :ceo,
          status: :idle,
          adapter: :agrenting,
          config: %{}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Preview remote CEO credential setup",
          status: :todo,
          priority: :high,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "CEO launch preview"
      assert html =~ "Next setup action"
      assert html =~ "Agrenting API key"
      assert html =~ "AGRENTING_API_KEY"
      assert html =~ "Add secret"
      assert html =~ "/settings/secrets?key=AGRENTING_API_KEY"
      refute html =~ "test-api-key"
    end

    test "shows assigned agent preflight blockers on issue detail" do
      {:ok, agent} =
        create_agent(%{
          name: "Missing Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "__missing_cympho_test_command__", "model" => "custom"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Runtime preflight blocker",
          status: :todo,
          priority: :high,
          assignee_id: agent.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Agent preflight"
      assert html =~ "Blocked"
      assert html =~ "Command"
      assert html =~ "__missing_cympho_test_command__ was not found"
      assert html =~ "Execution mode"
      assert html =~ "Edit command"
      assert html =~ "/agents/#{agent.id}#agent-process-command"
    end

    test "shows dispatch eligibility blocker for busy assigned agent on issue detail" do
      {:ok, agent} =
        create_agent(%{
          name: "Busy Runtime Agent",
          role: :engineer,
          status: :running,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Busy agent preflight blocker",
          status: :todo,
          priority: :high,
          assignee_id: agent.id,
          assigned_role: "engineer"
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Agent preflight"
      assert html =~ "No agent"
      assert html =~ "Dispatch eligibility"
      assert html =~ "Busy Runtime Agent is running"
      assert html =~ "return idle"
    end

    test "renders comments section", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Add Comment"
      assert html =~ "Owner update"
      assert html =~ "Delivery"
      assert html =~ "Blocked"
    end

    test "shows existing comments", %{issue: issue} do
      {:ok, _comment} =
        Comments.create_comment(%{
          body: "Test comment body",
          author_type: "user",
          author_id: "test-author",
          issue_id: issue.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Test comment body"
      assert html =~ "test-author"
      assert html =~ "Owner input"
    end

    test "renders execution brief and per-agent contribution cards", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} = Issues.update_issue(issue, %{assignee_id: agent.id})

      {:ok, _comment} =
        Comments.create_comment(%{
          body: "Implemented the smoke path and verified the LiveView renders.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "claude_code",
        continuation_summary: "Tests passed for the smoke path."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "code_change",
          title: "Smoke implementation",
          description: "Changed the issue detail page and added coverage."
        })

      {:ok, _child_issue} =
        create_issue(%{
          title: "Follow-up smoke subtask",
          description: "Subtask created by the runtime agent.",
          status: :todo,
          priority: :medium,
          parent_id: issue.id,
          assigned_role: "engineer",
          created_by_agent_id: agent.id
        })

      {:ok, ready_child} =
        create_issue(%{
          title: "Review-ready implementation slice",
          description: "Engineer finished the slice and wants CTO review.",
          status: :in_review,
          priority: :high,
          parent_id: issue.id,
          assignee_id: agent.id,
          assigned_role: "engineer",
          created_by_agent_id: agent.id
        })

      {:ok, _child_comment} =
        Comments.create_comment(%{
          body: "[delivery] Implemented the delegated slice and attached evidence.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: ready_child.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: ready_child.id,
        company_id: ready_child.company_id,
        status: "completed",
        adapter: "claude_code",
        continuation_summary: "Child slice checks passed."
      })

      {:ok, _child_work_product} =
        WorkProducts.create_work_product(%{
          issue_id: ready_child.id,
          created_by_agent_id: agent.id,
          kind: "code_change",
          title: "Child implementation diff",
          description: "Evidence for the child issue."
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Executive digest"
      assert html =~ "Coordinating work"
      assert html =~ "Next action"
      assert html =~ "Latest signal"
      assert html =~ "What happened so far"
      assert html =~ "Compact operational memory"
      assert html =~ "Actions taken"
      assert html =~ "Files / artifacts"
      assert html =~ "What happened"
      assert html =~ "Current state"
      assert html =~ "Next decision"
      assert html =~ "Comment mix"
      assert html =~ "Role run summaries"
      assert html =~ "Engineer delivery"
      assert html =~ "CTO review"
      assert html =~ "CEO owner update"
      assert html =~ "Runtime evidence"
      assert html =~ "Delivery"
      assert html =~ "Agent-by-agent ledger"
      assert html =~ "What each role has contributed"
      assert html =~ "Review readiness"
      assert html =~ "CTO/CEO review decision"
      assert html =~ "blocking CTO/CEO approval"
      assert html =~ "Contract audit"
      assert html =~ "Satisfied by Runtime Agent"
      assert html =~ "Evidence coverage"
      assert html =~ "Execution brief"
      assert html =~ "Handoff lane"
      assert html =~ "Current signal"
      assert html =~ "Runtime complete"
      assert html =~ "Runtime run ledger"
      assert html =~ "Owner update"
      assert html =~ "Work narrative"
      assert html =~ "Owner request"
      assert html =~ "Engineering work"
      assert html =~ "Delegation map"
      assert html =~ "CTO review queue"
      assert html =~ "CEO owner update readiness"
      assert html =~ "Ready for CTO"
      assert html =~ "Missing evidence"
      assert html =~ "Review-ready implementation slice"
      assert html =~ "Agent contributions"
      assert html =~ "Runtime Agent"
      assert html =~ "Implemented the smoke path"
      assert html =~ "Smoke implementation"
      assert html =~ "Delegated"
      assert html =~ "Follow-up smoke subtask"
      assert html =~ "Code work exists but no PR link is set."
    end

    test "shows runtime run ledger with latest run status and detail", %{issue: issue} do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO Runtime",
          role: :ceo,
          status: :idle,
          adapter: :claude_code
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      completed =
        Repo.insert!(%Run{
          agent_id: ceo.id,
          issue_id: issue.id,
          company_id: issue.company_id,
          status: "completed",
          adapter: "claude_code",
          continuation_summary: "CEO summarized the operating plan.",
          started_at: DateTime.add(now, -180, :second),
          completed_at: DateTime.add(now, -120, :second),
          input_tokens: 12_000,
          output_tokens: 1_500
        })

      failed =
        Repo.insert!(%Run{
          agent_id: ceo.id,
          issue_id: issue.id,
          company_id: issue.company_id,
          status: "failed",
          adapter: "claude_code",
          error_reason: "Provider rejected the request.",
          log_excerpt: "HTTP 401",
          started_at: DateTime.add(now, -90, :second),
          completed_at: DateTime.add(now, -80, :second)
        })

      running =
        Repo.insert!(%Run{
          agent_id: ceo.id,
          issue_id: issue.id,
          company_id: issue.company_id,
          status: "running",
          adapter: "claude_code",
          workspace_path: "/tmp/cympho-ceo-run",
          started_at: DateTime.add(now, -30, :second)
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Runtime run ledger"
      assert html =~ ~s(id="runtime-run-ledger-#{running.id}")
      assert html =~ ~s(id="runtime-run-ledger-#{failed.id}")
      assert html =~ ~s(id="runtime-run-ledger-#{completed.id}")
      assert html =~ "Running"
      assert html =~ "Failed"
      assert html =~ "Completed"
      assert html =~ "CEO Runtime"
      assert html =~ "claude code"
      assert html =~ "Runtime is still in flight."
      assert html =~ "Provider rejected the request."
      assert html =~ "CEO summarized the operating plan."
      assert html =~ "/tmp/cympho-ceo-run"
      assert html =~ "12,000 in"
      assert html =~ "1,500 out"

      assert html =~ "1m 0s"
      assert html =~ "10s"
    end

    test "shows pending agent wake in the handoff lane", %{issue: issue} do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO",
          role: :ceo,
          status: :idle
        })

      {:ok, issue} = Issues.update_issue(issue, %{status: :todo, assignee_id: ceo.id})

      Repo.insert!(%AgentWake{
        agent_id: ceo.id,
        issue_id: issue.id,
        reason: "manual_dispatch",
        status: "pending",
        triggered_by_type: "system",
        triggered_by_id: "test"
      })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Handoff lane"
      assert html =~ "Waiting on agent"
      assert html =~ "Wake queued for CEO"
      assert html =~ "Manual dispatch"
    end

    test "shows direct sub-issues", %{issue: issue} do
      {:ok, _child} =
        create_issue(%{
          title: "Child execution task",
          description: "Engineer-owned acceptance criteria",
          status: :todo,
          priority: :medium,
          parent_id: issue.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Sub-issues"
      assert html =~ "Child execution task"
      assert html =~ "Engineer-owned acceptance criteria"
    end

    test "renders work products in the activity timeline", %{issue: issue} do
      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          kind: "code_change",
          title: "Implementation diff",
          description: "Changed the LiveView and added tests."
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Work product"
      assert html =~ "Implementation diff"
      assert html =~ "Changed the LiveView and added tests."
    end

    test "shows failed run reason in the activity timeline", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "failed",
        adapter: "claude_code",
        error_reason: "Adapter command exited with code 1",
        log_excerpt: "missing provider configuration"
      })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Executive digest"
      assert html =~ "Needs attention"
      assert html =~ "Latest blocker"
      assert html =~ "Missing credentials"
      assert html =~ "Credentials missing"
      assert html =~ "Adapter command exited with code 1"
      assert html =~ "missing provider configuration"
    end

    test "filters activity timeline from signal to runs", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Noise Filter Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, comment} =
        Comments.create_comment(%{
          body: "[owner_update] Owner-visible agent note",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      {:ok, routine_comment} =
        Comments.create_comment(%{
          body: "Still reading through context.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      run =
        Repo.insert!(%Run{
          agent_id: agent.id,
          issue_id: issue.id,
          company_id: issue.company_id,
          status: "completed",
          adapter: "process",
          continuation_summary: "Completed run with owner-visible summary"
        })

      quiet_run =
        Repo.insert!(%Run{
          agent_id: agent.id,
          issue_id: issue.id,
          company_id: issue.company_id,
          status: "completed",
          adapter: "process"
        })

      {:ok, work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "code_change",
          title: "Signal artifact",
          description: "A useful artifact remains visible in signal."
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Signal"
      assert html =~ "Showing 3 signal events · 2 routine events hidden"
      assert html =~ "Signal mode keeps tagged comments"
      assert html =~ "Owner-visible agent note"
      assert html =~ "Completed run with owner-visible summary"
      assert html =~ "Signal artifact"
      assert html =~ "Thread rollup"
      assert html =~ "folding 1 routine note"
      assert html =~ "Comments and All preserve the full audit trail"
      assert html =~ "entry-run-#{run.id}"
      refute html =~ "entry-run-#{quiet_run.id}"
      refute html =~ "entry-comment-#{routine_comment.id}"

      html =
        view
        |> element("#issue-executive-digest button[phx-value-filter='all']", "Open raw timeline")
        |> render_click()

      assert html =~ "entry-run-#{run.id}"
      assert html =~ "entry-run-#{quiet_run.id}"
      assert html =~ "entry-comment-#{routine_comment.id}"
      assert html =~ "Still reading through context."

      html =
        view
        |> element("button[phx-value-filter='runs']")
        |> render_click()

      assert html =~ "entry-run-#{run.id}"
      assert html =~ "entry-run-#{quiet_run.id}"
      assert html =~ "Completed run with owner-visible summary"
      refute html =~ "entry-comment-#{comment.id}"
      refute html =~ "entry-comment-#{routine_comment.id}"
      refute html =~ "entry-work_product-#{work_product.id}"

      html =
        view
        |> element("button[phx-value-filter='comments']")
        |> render_click()

      assert html =~ "entry-comment-#{comment.id}"
      assert html =~ "entry-comment-#{routine_comment.id}"
      assert html =~ "Still reading through context."
    end

    test "comment form accepts input", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      form =
        form(view, "#comment-form", %{
          "comment" => %{
            "author_type" => "user",
            "author_id" => "new-author",
            "body" => "New comment body"
          }
        })

      assert form
    end

    test "comment templates prefill tagged owner-readable comments", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      html =
        view
        |> element("button[phx-value-template='delivery']")
        |> render_click()

      assert html =~ "[delivery]"
      assert html =~ "What happened:"
      assert html =~ "Files changed:"
      assert html =~ "Verification:"
      assert html =~ "Risks:"
    end

    test "resolve review gates loads delivery guidance", %{issue: issue} do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Digest actions"
      assert html =~ "Open raw timeline"
      assert html =~ "Resolve review gates"
      assert html =~ "Completion contract"
      assert html =~ "Engineer / delivery owner"
      assert html =~ "CTO / reviewer"
      assert html =~ "CEO / owner liaison"
      assert html =~ "Add completion note"
      assert html =~ "Attach work product"
      assert html =~ "Why this action?"
      assert html =~ "Shown because the Agent completion note gate is blocking this issue."
      assert html =~ "Signal view hides repetitive routine notes"

      html =
        view
        |> element("#issue-executive-digest button[phx-value-action='delivery_note']")
        |> render_click()

      assert html =~ "Delivery comment template loaded"
      assert html =~ "[delivery] What happened"
    end

    test "resolve review gates attaches work product evidence", %{issue: issue} do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Resolve review gates"
      assert html =~ "Attach work product"

      html =
        view
        |> element("#issue-executive-digest button[phx-value-action='work_product']")
        |> render_click()

      assert html =~ "Work product form opened"
      assert html =~ ~s(id="issue-work-product-form")
      assert html =~ "Attach artifact evidence"

      html =
        view
        |> form("#work-product-form", %{
          "work_product" => %{
            "title" => "Manual Evidence Bundle",
            "kind" => "url",
            "url" => "https://example.com/review-notes",
            "description" => "Reviewer-visible notes from the issue page."
          }
        })
        |> render_submit()

      assert html =~ "Work product attached"
      assert html =~ "Manual Evidence Bundle"
      refute html =~ "Attach a work product with"

      [work_product] = WorkProducts.list_work_products(issue.id)
      assert work_product.title == "Manual Evidence Bundle"
      assert work_product.kind == "url"
      assert work_product.url == "https://example.com/review-notes"
      assert work_product.metadata["source"] == "issue_show"
    end

    test "queues an auto-nudge for missing delivery evidence", %{issue: issue} do
      {:ok, engineer} =
        create_agent(%{
          name: "Delivery Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress,
          assigned_role: "engineer"
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Auto-nudges"
      assert html =~ "Digest actions"
      assert html =~ "Delivery Agent"
      assert html =~ "Nudge delivery owner"

      assert html =~
               "Shown because Delivery Agent is the best available owner for missing digest evidence."

      assert html =~ "Queue Delivery Agent with the missing evidence request."

      html =
        view
        |> element(
          "#issue-executive-digest button[phx-value-key='delivery:#{issue.id}:#{engineer.id}']"
        )
        |> render_click()

      assert html =~ "Auto-nudge queued for Delivery Agent"
      assert html =~ "Queued"
      assert html =~ "Ask for one tagged delivery note"

      updated = Issues.get_issue!(issue.id)
      assert updated.assignee_id == engineer.id
      assert Inbox.get_inbox_state(issue.id, engineer.id)
      assert [_wake | _] = Wakes.list_issue_wakes(issue.id)

      assert Enum.any?(Comments.list_comments(issue.id), fn comment ->
               comment.author_type == "system" and
                 comment.body =~ "Auto-nudge queued for Delivery Agent"
             end)
    end

    test "queues a contract nudge from the completion contract card", %{issue: issue} do
      {:ok, engineer} =
        create_agent(%{
          name: "Delivery Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress,
          assignee_id: engineer.id,
          assigned_role: "engineer"
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body: "[delivery] Done.",
          author_type: "agent",
          author_id: engineer.id,
          issue_id: issue.id
        })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: engineer.id,
          kind: "document",
          title: "Partial evidence",
          description: "Evidence exists, but the delivery comment needs the contract fields."
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Completion contract"
      assert html =~ "Nudge delivery contract"
      assert html =~ "Verification"

      html =
        view
        |> element(
          "#issue-executive-digest button[phx-value-contract='delivery_contract']",
          "Nudge delivery contract"
        )
        |> render_click()

      assert html =~ "Contract nudge queued for Delivery Agent"
      assert html =~ "Pending nudge for Delivery Agent"

      assert [wake] = Wakes.list_review_nudges([issue.id])
      assert wake.metadata["contract_key"] == "delivery_contract"
      assert "contract_delivery_contract" in wake.metadata["blocker_keys"]
    end

    test "queues PR quality nudge from the issue sidebar", %{issue: issue} do
      {:ok, engineer} =
        create_agent(%{
          name: "PR Repair Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress,
          assignee_id: engineer.id,
          assigned_role: "engineer",
          github_pr_url: "https://github.com/acme/app/pull/42",
          monitor_state: %{
            "pr_quality" => %{
              "status" => "attention",
              "status_label" => "Needs PR fixes",
              "summary" => "2 PR contract gaps need fixes.",
              "gaps" => [
                %{"label" => "Branch name", "detail" => "Expected branch to include CYM-7."}
              ]
            }
          }
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Needs PR fixes"
      assert html =~ "Nudge agent to fix PR"
      assert html =~ "PR repair packet"
      assert html =~ "Expected branch"
      assert html =~ "Expected title"
      assert html =~ "gh pr edit https://github.com/acme/app/pull/42"
      assert html =~ "PR body template"

      html =
        view
        |> element("#issue-github-pr button[phx-value-contract='pr_quality']")
        |> render_click()

      assert html =~ "Contract nudge queued for PR Repair Agent"

      assert [wake] = Wakes.list_review_nudges([issue.id])
      assert wake.metadata["contract_key"] == "pr_quality"
      assert "pr_quality" in wake.metadata["blocker_keys"]
    end

    test "shows satisfied review nudge after evidence clears it", %{issue: issue} do
      {:ok, cto} =
        create_agent(%{
          name: "Review Captain",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, agent} =
        create_agent(%{
          name: "Delivery Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_review
        })

      {:ok, _delivery_comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered the work. Files changed: review evidence. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Review evidence",
          description: "Evidence for review."
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Nudge CTO review"

      view
      |> element(
        "#issue-executive-digest button[phx-value-key='cto_review:#{issue.id}:#{cto.id}']"
      )
      |> render_click()

      assert [_pending] = Wakes.list_review_nudges([issue.id])

      {:ok, _review_comment} =
        Comments.create_comment(%{
          body:
            "[review] Verdict: accepted. What happened: evidence accepted. Verification: passed. Gaps: none. Follow-up issues: none. Next decision: close.",
          author_type: "agent",
          author_id: cto.id,
          issue_id: issue.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert [] = Wakes.list_review_nudges([issue.id])
      assert html =~ "Review nudges satisfied"
      assert html =~ "Cleared"
      assert html =~ "CTO/CEO review decision"
    end

    test "next owner strip points missing artifact work at assignee", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Evidence Owner",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress,
          assignee_id: agent.id
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered reviewable work. Files changed: reviewable evidence. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Next owner"
      assert html =~ "Evidence Owner"
      assert html =~ "Engineer"
      assert html =~ "Work product"
      assert html =~ "Attach work product"
      assert html =~ "should attach a work product"
    end

    test "review gate query opens work product resolver", %{issue: issue} do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}?gate=work_product")

      assert html =~ "Work product form opened"
      assert html =~ ~s(id="issue-work-product-form")
      assert html =~ ~s(data-clean-url="/issues/#{issue.id}#issue-work-product-form")
      assert html =~ "Attach artifact evidence"
    end

    test "review gate query preloads comment resolver", %{issue: issue} do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}?gate=delivery_note")

      assert html =~ "Delivery comment template loaded"
      assert html =~ ~s(data-clean-url="/issues/#{issue.id}#issue-comments")
      assert html =~ "[delivery] What happened"
    end

    test "resolve review gates loads review guidance when only approval is missing", %{
      issue: issue
    } do
      {:ok, _cto} =
        create_agent(%{
          name: "Review Captain",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, agent} =
        create_agent(%{
          name: "Review Helper Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_review
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered reviewable work. Files changed: reviewable evidence. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Reviewable evidence",
          description: "Non-code evidence."
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Resolve review gates"
      assert html =~ "Next owner"
      assert html =~ "Review Captain"
      assert html =~ "CTO"
      assert html =~ "CTO/CEO review decision"
      assert html =~ "Add review comment"

      html =
        view
        |> element("#issue-next-owner button[phx-value-action='review_comment']")
        |> render_click()

      assert html =~ "Review comment template loaded"
      assert html =~ "[review] Verdict"
    end

    test "comment form submits with server-side owner defaults", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")
      current_user_id = :sys.get_state(view.pid).socket.assigns.current_user.id

      view
      |> form("#comment-form", %{
        "comment" => %{
          "body" => "[owner_update] What happened: owner posted a status update."
        }
      })
      |> render_submit()

      [comment] = Comments.list_comments(issue.id)
      assert comment.author_type == "user"
      assert comment.author_id == current_user_id
      assert comment.body =~ "[owner_update]"
    end
  end

  describe "Show - Inline Title Edit" do
    test "shows edit button for title", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "start_editing"
      assert html =~ ~s(field="title")
    end

    test "enters edit mode and saves title", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='title']")
      |> render_click()

      assert render(view) =~ "Save"
      assert render(view) =~ "Cancel"

      view
      |> form("form[phx-submit='save_title']", %{"title" => "Updated Title"})
      |> render_submit()

      assert render(view) =~ "Updated Title"
      assert render(view) =~ "Title updated"
    end

    test "rejects empty title", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='title']")
      |> render_click()

      view
      |> form("form[phx-submit='save_title']", %{"title" => "   "})
      |> render_submit()

      assert render(view) =~ "Title cannot be empty"
    end

    test "cancels title editing", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='title']")
      |> render_click()

      assert render(view) =~ "Cancel"

      view
      |> element("button[phx-click='cancel_editing']")
      |> render_click()

      refute render(view) =~ ~s(phx-submit="save_title")
    end
  end

  describe "Show - Inline Description Edit" do
    test "enters edit mode and saves description", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='description']")
      |> render_click()

      assert render(view) =~ ~s(phx-submit="save_description")

      view
      |> form("form[phx-submit='save_description']", %{"description" => "New description"})
      |> render_submit()

      assert render(view) =~ "New description"
      assert render(view) =~ "Description updated"
    end
  end

  describe "Show - Status Combobox" do
    test "shows status combobox with valid transitions", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "combobox_status"
      # backlog can transition to todo, in_progress, blocked
      assert html =~ ~s(data-combobox-id="todo")
      assert html =~ ~s(data-combobox-id="in_progress")
      assert html =~ ~s(data-combobox-id="blocked")
    end

    test "valid status transition succeeds", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "todo"})

      assert render(view) =~ "Status updated to todo"

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :todo
    end

    test "invalid status transition shows error", %{issue: _issue} do
      {:ok, issue} =
        create_issue(%{
          title: "Done Issue",
          description: "Test",
          status: :backlog
        })

      # backlog -> done is not a valid direct transition
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "done"})

      assert render(view) =~ "Invalid transition"
    end

    test "review gates block moving to review without delivery evidence" do
      {:ok, issue} =
        create_issue(%{
          title: "Needs evidence before review",
          description: "Owner request is clear.",
          status: :todo,
          priority: :medium
        })

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "in_review"})

      html = render(view)
      assert html =~ "Review gates blocking status change"
      assert html =~ "Runtime verification"
      assert html =~ "Agent completion note"
      assert Issues.get_issue!(issue.id).status == :todo
    end

    test "review gates allow moving to review once delivery evidence exists" do
      {:ok, agent} =
        create_agent(%{
          name: "Evidence Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Evidence ready",
          description: "Owner request is clear.",
          status: :in_progress,
          priority: :medium
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered the reviewable work. Files changed: review evidence. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Review evidence",
          description: "Non-code review evidence."
        })

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "in_review"})

      assert render(view) =~ "Status updated to in_review"
      assert Issues.get_issue!(issue.id).status == :in_review
    end

    test "approval gates block closing without CTO or CEO review decision" do
      {:ok, agent} =
        create_agent(%{
          name: "Delivery Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Cannot close yet",
          description: "Owner request is clear.",
          status: :in_progress,
          priority: :medium
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered the work. Files changed: closure evidence. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Closure evidence",
          description: "Non-code closure evidence."
        })

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "done"})

      html = render(view)
      assert html =~ "Approval gates blocking closure"
      assert html =~ "CTO/CEO review decision"
      assert Issues.get_issue!(issue.id).status == :in_progress
    end
  end

  describe "Show - Priority Combobox" do
    test "shows priority combobox", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "combobox_priority"
      assert html =~ ~s(data-combobox-id="low")
      assert html =~ ~s(data-combobox-id="medium")
      assert html =~ ~s(data-combobox-id="high")
    end

    test "priority change succeeds", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-priority-combobox")
      |> render_hook("combobox_priority", %{"selected" => "low"})

      assert render(view) =~ "Priority updated"

      updated = Issues.get_issue!(issue.id)
      assert updated.priority == :low
    end
  end

  describe "Show - Assignee Management" do
    test "shows assignee combobox when no assignee", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "combobox_assignee"
      assert html =~ "Unassigned"
    end

    test "assigns an agent to the issue", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-assignee-combobox")
      |> render_hook("combobox_assignee", %{"selected" => agent.id})

      html = render(view)
      assert html =~ "Test Agent"
      assert html =~ "Assignee updated"

      updated = Issues.get_issue!(issue.id)
      assert updated.assignee_id == agent.id
    end

    test "unassigns an agent from the issue", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Remove Me",
          role: :engineer,
          status: :running
        })

      {:ok, _} = Issues.update_issue(issue, %{assignee_id: agent.id})

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      html = render(view)
      assert html =~ "Remove Me"

      view
      |> element("#issue-assignee-combobox")
      |> render_hook("combobox_assignee", %{"selected" => nil})

      html = render(view)
      assert html =~ "Assignee removed"

      updated = Issues.get_issue!(issue.id)
      assert updated.assignee_id == nil
    end

    test "shows agent status badge when assigned", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Busy Agent",
          role: :cto,
          status: :running
        })

      {:ok, _} = Issues.update_issue(issue, %{assignee_id: agent.id})

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Busy Agent"
    end
  end
end
