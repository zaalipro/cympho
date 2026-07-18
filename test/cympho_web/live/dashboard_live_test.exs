defmodule CymphoWeb.DashboardLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Cympho.AgentActions
  alias Cympho.Agents
  alias Cympho.Comments
  alias Cympho.Companies
  alias Cympho.Finances.BudgetPolicy
  alias Cympho.Goals
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Projects
  alias Cympho.Repo
  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake
  alias CymphoWeb.ConnCase

  defp create_agent(attrs), do: Agents.create_agent(scoped_attrs(attrs))
  defp create_issue(attrs), do: Issues.create_issue(scoped_attrs(attrs))

  defp element_attrs(html, selector) do
    html
    |> Floki.parse_document!()
    |> Floki.find(selector)
    |> case do
      [{_tag, attrs, _children} | _rest] -> Map.new(attrs)
      [] -> %{}
    end
  end

  defp element_text(html, selector) do
    html
    |> Floki.parse_document!()
    |> Floki.find(selector)
    |> Floki.text()
  end

  describe "Dashboard page" do
    test "root route redirects to dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Dashboard"
      assert html =~ "Active Agents"
    end

    test "a run_status broadcast keeps the dashboard alive", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")

      # Regression: the dashboard subscribes to company runs but had no clause
      # for the %Phoenix.Socket.Broadcast{event: "run_status"} struct and no
      # catch-all, so any run start/fail crashed it.
      payload = %{
        event_type: :run_failed,
        resource_id: Ecto.UUID.generate(),
        issue_id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate(),
        status: "failed",
        adapter: "claude_code",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      CymphoWeb.Endpoint.broadcast("company:#{current_company_id()}:runs", "run_status", payload)

      assert render(view) =~ "Active Agents"
    end

    test "renders the simple-mode home glance", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Today"
      assert html =~ "What should the team do?"
      assert html =~ "Active"
      assert html =~ "Waiting"
      assert html =~ "Agents"
    end

    test "app shell exposes one visible simple and advanced mode toggle", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      document = Floki.parse_document!(html)

      assert length(Floki.find(document, "[data-ui-mode-toggle]")) == 1
      assert Floki.find(document, "[data-sidebar-ui-mode-toggle]") != []
      assert Floki.text(Floki.find(document, "[data-sidebar-ui-mode-toggle]")) =~ "Interface"
      assert Floki.text(Floki.find(document, "[data-ui-mode-label]")) =~ "Simple"
    end

    test "renders dashboard with metric cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Active Agents"
      assert html =~ "Agents"
      assert html =~ "Closed 7d"
      assert html =~ "Runtime capacity"
      assert html =~ "Autonomy readiness"
      assert html =~ "Runtime"
      assert html =~ "Agent guides"
      assert html =~ "Autonomous operating readiness"
      refute html =~ "Paperclip operating parity"
      refute html =~ "Paperclip"
      refute html =~ "Parity"
      refute html =~ "parity"
      assert html =~ "operating primitives"
      assert html =~ "Mission links"
      assert html =~ "Wake loop"
      assert html =~ "Cost guardrails"
      assert html =~ "Issue memory"
      assert html =~ "Extension surface"

      operating_readiness = element_text(html, "[data-testid='operating-readiness']")

      assert operating_readiness =~ "Create mission"
      assert operating_readiness =~ "Create budget"
      assert html =~ ~s(href="/budgets/new")
    end

    test "owner sees global runtime controls in the app shell" do
      conn = authenticated_conn(%{role: "owner", is_board_member: true})
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ ~s(data-testid="runtime-controls")
      assert html =~ ~s(data-testid="runtime-status-trigger")
      assert html =~ "Full power"
      assert html =~ "Pause"
      assert html =~ "Stop"
      assert html =~ ~s(action="/runtime-control/pause")
      assert html =~ ~s(action="/runtime-control/stop")
      assert html =~ ~s(data-runtime-menu-close)
      refute html =~ ~s(data-testid="desktop-runtime-topbar")
      assert html =~ ~s(id="sidebar")
      assert html =~ ~s(data-mobile-drawer)
      assert html =~ ~s(aria-controls="sidebar")
      assert html =~ ~s(aria-expanded="false")
    end

    test "paused company shell topbar offers resume instead of pause" do
      conn = authenticated_conn(%{role: "owner", is_board_member: true})

      {:ok, _company} =
        Companies.execute_company_update(current_company(), %{
          status: "paused",
          paused_at: DateTime.utc_now() |> DateTime.truncate(:second),
          paused_reason: "maintenance"
        })

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ ~s(title="Runtime: Paused")
      assert html =~ "Resume"
      assert html =~ ~s(action="/runtime-control/resume")
      refute html =~ ~s(action="/runtime-control/pause")
    end

    test "low power company shell topbar offers full power instead of low power" do
      conn = authenticated_conn(%{role: "owner", is_board_member: true})
      {:ok, _company} = Companies.enter_low_power_mode(current_company(), "after hours")

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ ~s(title="Runtime: Low power")
      assert html =~ "Full power"
      assert html =~ ~s(action="/runtime-control/resume")
      refute html =~ ~s(action="/runtime-control/low-power")
    end

    test "renders spend posture and budget next action", %{
      conn: conn,
      current_company: company
    } do
      %BudgetPolicy{}
      |> BudgetPolicy.changeset(%{
        company_id: company.id,
        scope: "company",
        period: "monthly",
        budget_limit_usd: Decimal.new("100.00"),
        warning_threshold_pct: Decimal.new("80.0")
      })
      |> Repo.insert!()

      Repo.insert!(%Run{
        company_id: company.id,
        status: "completed",
        adapter: "codex",
        cost_usd: Decimal.new("85.00"),
        input_tokens: 100,
        output_tokens: 50,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "30d cost"
      assert html =~ "$85.00"
      assert html =~ "Watch spend"
      assert html =~ "Budget spend needs review"
      assert html =~ "Review budget"
      assert html =~ ~s(href="/budgets")
    end

    test "warns when dashboard spend has unpriced token usage", %{
      conn: conn,
      current_company: company
    } do
      Repo.insert!(%Run{
        company_id: company.id,
        status: "completed",
        adapter: "codex",
        cost_usd: Decimal.new("0.00"),
        input_tokens: 1_000_000,
        output_tokens: 500_000,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "+ unpriced"
      assert html =~ "Pricing missing for token usage"
      assert html =~ ~s(href="/costs")
    end

    test "renders goal alignment coverage and next action", %{
      conn: conn,
      current_company: company
    } do
      {:ok, project} =
        Projects.create_project(%{
          name: "Dashboard Strategy Project",
          prefix: "DSP",
          company_id: company.id
        })

      {:ok, mission} =
        Goals.create_goal(%{
          title: "Dashboard Mission",
          company_id: company.id,
          project_id: project.id,
          goal_type: :mission
        })

      {:ok, _aligned} =
        Issues.create_issue(%{
          title: "Aligned dashboard work",
          company_id: company.id,
          project_id: project.id,
          goal_id: mission.id,
          status: :todo
        })

      {:ok, _floating} =
        Issues.create_issue(%{
          title: "Floating dashboard work",
          company_id: company.id,
          status: :todo,
          priority: :critical
        })

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Goal links"
      assert html =~ "50"
      assert html =~ "1 floating"
      assert html =~ "Some work has no goal"
      assert html =~ ~s(href="/goals")
    end

    test "shows runtime capacity pressure from local CLI slots", %{conn: conn} do
      {:ok, _agent} =
        create_agent(%{
          name: "Fanout Agent",
          role: :engineer,
          adapter: :codex,
          status: :idle,
          max_concurrent_jobs: 6
        })

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "High pressure"
      assert html =~ "running now"
      assert html =~ "Runtime capacity"
    end

    test "renders all computed next actions", %{conn: conn} do
      {:ok, _} = create_issue(%{title: "Blocked work", status: :blocked})

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Needs you"
      assert html =~ "Needs setup"
      assert html =~ "Review mode is on"
      assert html =~ "Nothing runs or spends money — it is safe to inspect and edit the company."
      assert html =~ "Go live when ready"
      assert html =~ ~s(href="/operations#runtime-launch-checklist")
      assert html =~ "Later"
      assert html =~ "blocked issue"
      assert html =~ "Review blockers"
      assert html =~ ~s(href="/kanban")
    end

    test "renders owner execution health from operations signals", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        create_agent(%{
          name: "Dashboard Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          max_concurrent_jobs: 6,
          company_id: company.id
        })

      {:ok, issue} =
        create_issue(%{
          title: "Needs owner brief",
          description: "Prepare the CEO-facing update.",
          status: :in_review,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, issue.id, "manual_dispatch", "system", "test", %{
          "source" => "review_nudge",
          "nudge_group_key" => "owner:#{issue.id}:#{agent.id}",
          "blocker_keys" => ["ceo_owner_update"],
          "blocker_labels" => ["CEO owner update"],
          "summary" => "Ask the CEO agent to leave an owner-ready update."
        })

      stale_time =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.truncate(:second)

      Repo.update_all(from(w in AgentWake, where: w.id == ^wake.id),
        set: [inserted_at: stale_time]
      )

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "failed",
        adapter: "codex",
        error_reason: "OPENAI_API_KEY not set",
        log_excerpt: "missing OPENAI_API_KEY"
      })

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Execution health"
      assert html =~ "Owner morning brief"
      assert html =~ "Review nudges"
      assert html =~ "Stale nudges"
      assert html =~ "CTO review"
      assert html =~ "Owner updates"
      assert html =~ "Runtime failures"
      assert html =~ "CLI pressure"
      assert html =~ ~s(href="/operations#review-nudges")
      assert html =~ ~s(href="/operations#runtime-failures")
      assert html =~ ~s(href="/operations#runtime-capacity")
    end

    test "promotes CEO owner signoff decisions on dashboard", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, issue, _ceo} =
        create_dashboard_owner_signoff(company, "Owner signs off from dashboard")

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Needs you"
      assert html =~ "Owner decision"
      assert html =~ "CEO owner update needs decision"
      assert html =~ "1 CEO owner update is ready for acceptance or revision."
      assert html =~ "Review signoff"
      assert html =~ ~s(href="/operations#owner-signoff-queue")
      assert html =~ "Owner updates"
      assert html =~ "Awaiting acceptance"
      assert html =~ ~s(data-testid="dashboard-owner-signoff-actions")
      assert html =~ "Owner signs off from dashboard"
      assert html =~ "Accept and close"
      assert html =~ "Request revision"

      assert Issues.get_issue!(issue.id).status == :blocked
    end

    test "accepts CEO owner signoff from dashboard", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, issue, _ceo} =
        create_dashboard_owner_signoff(company, "Owner accepts from dashboard")

      {:ok, view, html} = live(conn, "/dashboard")

      assert html =~ "Accept and close"

      html =
        view
        |> element(
          "button[phx-click='accept_owner_verification'][phx-value-issue-id='#{issue.id}']",
          "Accept and close"
        )
        |> render_click()

      refute html =~ "CEO owner update needs decision"
      refute html =~ "Accept and close"
      refute html =~ "Owner accepts from dashboard"

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :done
      assert is_nil(updated.assignee_id)
    end

    test "requests CEO owner revision from dashboard", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, issue, ceo} =
        create_dashboard_owner_signoff(company, "Owner requests revision from dashboard")

      {:ok, view, html} = live(conn, "/dashboard")

      assert html =~ "Request revision"

      html =
        view
        |> element(
          "button[phx-click='request_owner_revision'][phx-value-issue-id='#{issue.id}']",
          "Request revision"
        )
        |> render_click()

      assert html =~ "Review mode is on"
      assert html =~ "Owner requests revision from dashboard"

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :todo
      assert updated.assignee_id == ceo.id
      assert Issues.dispatch_pinned?(updated)
    end

    test "does not mix owner signoff action with a separate draft CEO candidate", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, _signoff_issue, ceo} =
        create_dashboard_owner_signoff(company, "Owner signoff stays primary")

      {:ok, _candidate} =
        create_issue(%{
          title: "Dashboard hidden draft candidate",
          description: """
          Context: signup activation drops after project creation.
          Constraints / risks: must not slow first project creation.
          CEO first output ([owner_update], [handoff], or [blocked]): handoff if execution is needed.
          Evidence to inspect after the run: scoped child issues and verification notes.
          """,
          status: :todo,
          priority: :critical,
          company_id: company.id,
          assigned_role: "ceo",
          assignee_id: ceo.id
        })

      {:ok, _view, html} = live(conn, "/dashboard")

      lane_text =
        html
        |> Floki.parse_document!()
        |> Floki.find("[data-testid='dashboard-ceo-command-lane']")
        |> Floki.text()

      assert lane_text =~ "Owner signoff"
      assert lane_text =~ "Review owner signoff"
      refute lane_text =~ "Dashboard hidden draft candidate"
      refute lane_text =~ "Focused command"
    end

    test "renders autonomy patrol candidates and supervisor wake pressure", %{conn: conn} do
      {:ok, cto} =
        create_agent(%{
          name: "Patrol CTO",
          role: :cto,
          status: :idle
        })

      {:ok, engineer} =
        create_agent(%{
          name: "Patrol Engineer",
          role: :engineer,
          status: :idle,
          parent_id: cto.id
        })

      stale_time =
        DateTime.utc_now()
        |> DateTime.add(-3 * 3600, :second)
        |> DateTime.truncate(:second)

      {:ok, issue} =
        create_issue(%{
          title: "Silent checkout",
          description: "This issue stopped moving.",
          status: :in_progress,
          assignee_id: engineer.id,
          checked_out_at: stale_time
        })

      Repo.update_all(from(i in Cympho.Issues.Issue, where: i.id == ^issue.id),
        set: [updated_at: stale_time, checked_out_at: stale_time]
      )

      {:ok, _wake} = Wakes.wake_for_stalled_issue(cto.id, issue.id, %{})

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Autonomy patrol"
      assert html =~ "Intervention ready"
      assert html =~ "1 stalled issue needs supervisor intervention."
      assert html =~ "1 supervisor wake already queued."
      assert html =~ "Silent checkout"
      assert html =~ "Wake CTO: Patrol CTO"
    end

    test "points pre-runtime review nudges at launch instead of evidence follow-up", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        create_agent(%{
          name: "Dashboard CEO",
          role: :ceo,
          status: :idle,
          adapter: :claude_code,
          company_id: company.id
        })

      {:ok, issue} =
        create_issue(%{
          title: "Define the operating issue",
          description: "Capture the first CEO-owned issue.",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, issue.id, "manual_dispatch", "system", "test", %{
          "source" => "review_nudge",
          "nudge_group_key" => "owner:#{issue.id}:#{agent.id}",
          "blocker_keys" => ["runtime_verification", "agent_note", "work_product"],
          "blocker_labels" => ["Runtime verification", "Agent note", "Work product"],
          "summary" => "Ask for evidence after runtime starts."
        })

      stale_time =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.truncate(:second)

      Repo.update_all(from(w in AgentWake, where: w.id == ^wake.id),
        set: [inserted_at: stale_time]
      )

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Runtime launch is waiting"
      assert html =~ "Open launch checklist"
      assert html =~ "Launch nudges"
      assert html =~ "Launch waits"
      assert html =~ "Runtime not started"
      assert html =~ ~s(href="/operations#runtime-launch-checklist")
      refute html =~ "Review nudges are stale"
    end

    test "surfaces CEO outcome attention in next actions", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, ceo} =
        create_agent(%{
          name: "Dashboard Outcome CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        create_issue(%{
          title: "CEO outcome needs owner follow-up",
          description: "CEO turn failed before the owner signal landed.",
          status: :todo,
          priority: :critical,
          company_id: company.id,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: issue.id,
        status: "failed",
        adapter: "process",
        error_reason: "provider timeout"
      })

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "CEO outcomes need attention"
      assert html =~ "1 CEO outcome needs owner follow-up after failed or silent turns."
      assert html =~ "Open CEO monitor"
      assert html =~ ~s(href="/operations#ceo-outcome-monitor")
    end

    test "surfaces launch-ready CEO command lane on dashboard", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, ceo} =
        create_agent(%{
          name: "Dashboard Launch CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        create_issue(%{
          title: "Dashboard CEO launch packet",
          description: """
          Context: signup activation drops after project creation.
          Constraints / risks: must not slow first project creation.
          Definition of done: CEO creates a plan or handoff with acceptance criteria.
          CEO first output ([owner_update] or [handoff]): handoff if execution is needed.
          Evidence to inspect after the run: scoped child issues and verification notes.
          """,
          status: :todo,
          priority: :high,
          company_id: company.id,
          assigned_role: "ceo",
          assignee_id: ceo.id
        })

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ ~s(data-testid="dashboard-ceo-command-lane")
      assert html =~ "CEO command lane"
      assert html =~ "Ready to launch"
      assert html =~ "First useful CEO result"
      assert html =~ "Dashboard CEO launch packet"
      assert html =~ "Owner brief 6/6"
      assert html =~ "Ready for CEO launch"
      assert html =~ "Run focused CEO issue"
      assert html =~ "Focused command"
      assert html =~ "Copy command"
      assert html =~ ~s(data-testid="dashboard-ceo-focused-command")
      assert html =~ ~s(href="/operations#runtime-launch-checklist")
      assert html =~ ~s(href="/operations#ceo-flow-verifier")
      assert html =~ ~s(href="/issues/#{issue.id}")

      command_attrs =
        element_attrs(
          html,
          "#dashboard-ceo-focused-command button[data-copy-label='Copy command']"
        )

      assert command_attrs["data-copy-text"] =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"
      assert command_attrs["data-copy-text"] =~ "mise exec -- mix phx.server"
    end

    test "does not expose dashboard focused command before owner brief is ready", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, ceo} =
        create_agent(%{
          name: "Dashboard Draft CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        create_issue(%{
          title: "Dashboard CEO draft launch packet",
          description: """
          Context: signup activation drops after project creation.
          Constraints / risks: must not slow first project creation.
          CEO first output ([owner_update], [handoff], or [blocked]): handoff if execution is needed.
          Evidence to inspect after the run: scoped child issues and verification notes.
          """,
          status: :todo,
          priority: :high,
          company_id: company.id,
          assigned_role: "ceo",
          assignee_id: ceo.id
        })

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ ~s(data-testid="dashboard-ceo-command-lane")
      assert html =~ "Dashboard CEO draft launch packet"
      assert html =~ "Owner brief 5/6"
      assert html =~ "Needs one more pass"
      assert html =~ ~s(href="/issues/#{issue.id}")
      refute html =~ ~s(data-testid="dashboard-ceo-focused-command")
      refute html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"
    end

    test "shows agent count from database", %{conn: conn} do
      {:ok, _} =
        create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test1"
        })

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Test Agent"
    end

    test "shows issue status breakdown", %{conn: conn} do
      {:ok, _} = create_issue(%{title: "Dash Issue", description: "d", status: :backlog})

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Issues by Status"
    end

    test "shows bottleneck section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Bottlenecks"
    end

    test "shows throughput chart section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Issue Throughput"
    end

    test "shows agent status breakdown", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Agents by Status"
    end

    test "shows routine health section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Routine Health"
    end
  end

  defp create_dashboard_owner_signoff(company, title) do
    {:ok, ceo} =
      create_agent(%{
        name: "Dashboard Signoff CEO",
        role: :ceo,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo", "model" => "custom"},
        company_id: company.id
      })

    {:ok, issue} =
      create_issue(%{
        title: title,
        status: :in_progress,
        priority: :critical,
        assigned_role: "ceo",
        company_id: company.id,
        assignee_id: ceo.id
      })

    Repo.insert!(%Run{
      company_id: company.id,
      agent_id: ceo.id,
      issue_id: issue.id,
      adapter: "process",
      status: "completed"
    })

    assert {:ok, _comment} =
             Comments.create_comment(%{
               issue_id: issue.id,
               author_type: "agent",
               author_id: ceo.id,
               body:
                 "[owner_update] What happened: CEO verified the business outcome. Business status: ready for owner signoff. Evidence inspected: completed child issues. Verification: reviewed the evidence packet. Remaining risk: low. Current state: waiting for owner verification. Next decision: owner accepts or requests revision. Owner decision needed: verify or request revision."
             })

    assert {:ok, _result} =
             AgentActions.execute(issue, ceo, [
               %{
                 "type" => "block_issue",
                 "reason" => owner_signoff_block_reason()
               }
             ])

    {:ok, Issues.get_issue!(issue.id), ceo}
  end

  defp live_session_conn(conn, user, company) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_id", user.id)
    |> Plug.Conn.put_session("company_id", company.id)
  end

  defp owner_signoff_block_reason do
    """
    Cause: CEO is handing this back for owner verification.
    Attempted fix: inspected the CEO owner update and confirmed no agent work remains.
    Needs: owner must verify the CEO owner update before closure.
    Current state: no agent work remains; issue is waiting on owner acceptance or revision.
    Next decision: owner accepts the update or reopens it for revision.
    Restart packet: open the CEO owner update, inspect evidence, then accept or request revision.
    """
    |> String.trim()
  end
end
