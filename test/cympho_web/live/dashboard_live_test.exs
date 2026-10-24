defmodule CymphoWeb.DashboardLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Cympho.AgentActions
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Comments
  alias Cympho.Companies
  alias Cympho.Dashboard
  alias Cympho.Finances.BudgetIncident
  alias Cympho.Finances.BudgetPolicy
  alias Cympho.Finances.TokenUsage
  alias Cympho.Goals
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Issues.IssueThreadInteraction
  alias Cympho.OwnerAttention
  alias Cympho.Projects
  alias Cympho.R3Fixtures
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

      # r3: the page is called Home (N3); the Advanced panels stay below it.
      assert html =~ "<title data-suffix=\" · Cympho\">Home · Cympho</title>"
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

    # r3: the Simple glance (prompt bar and the Active / Waiting / Agents tiles)
    # and its Simple Needs-you cards are replaced by the r3 Home (plan §0.2):
    # one H1, the Next step, Needs you, Last 24 hours.
    test "renders the r3 Home", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")
      main = main_doc(view)

      assert [{"div", _, _}] = Floki.find(main, "div.frame[data-page='home']")
      assert text(main, "h1") == "Home"
      assert [_] = Floki.find(main, "section.next")
      assert text(main, "section[aria-labelledby='day-t'] h2") == "Last 24 hours"
      assert length(Floki.find(main, ".pw")) == 1
    end

    test "Home's decisions match OwnerAttention.unresolved_count (nav parity)", %{
      conn: conn
    } do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      # Blocked work is human-action membership for every owner — creates OA
      # items without forcing a next_actions card collapse edge case alone.
      {:ok, _blocked} =
        create_issue(%{
          title: "Owner must decide",
          status: :blocked,
          company_id: company.id,
          assignee_user_id: user.id
        })

      {:ok, _approval} =
        Cympho.BoardApprovals.create_board_approval(%{
          title: "Approve hire for count parity",
          category: "agent_hire",
          company_id: company.id
        })

      oa_count = Cympho.OwnerAttention.unresolved_count(company.id, user)
      assert oa_count >= 2

      expected = min(99, oa_count)

      {:ok, view, html} = live(conn, "/dashboard")

      # r3: the Waiting tile is gone; Home lists the same decisions the nav badge
      # counts, the first as the Next step and the rest as Needs-you rows.
      main = main_doc(view)
      decisions = 1 + length(Floki.find(main, "section[aria-labelledby='ny-t'] li.row"))
      assert decisions == expected

      badge =
        html
        |> Floki.parse_document!()
        |> Floki.find("[data-testid='nav-badge-inbox']")
        |> Floki.text()
        |> String.trim()

      assert badge == Integer.to_string(expected)
    end

    test "the Simple view never deep-links advanced-only /operations#*", %{
      conn: conn
    } do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        create_agent(%{
          name: "Fail Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          company_id: company.id
        })

      {:ok, issue} =
        create_issue(%{
          title: "Failed run issue",
          status: :todo,
          company_id: company.id,
          assignee_id: agent.id
        })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "failed",
        adapter: "codex",
        error_reason: "OPENAI_API_KEY not set"
      })

      {:ok, view, html} = live(conn, "/dashboard")

      # Advanced still deep-links the ops console.
      assert html =~ ~s(href="/operations#runtime-failures")

      # r3: the Simple view is the r3 Home (the Simple cards are gone). Its links
      # land on owner-visible routes — never /operations#*, which is advanced-only.
      simple_hrefs =
        view
        |> main_doc()
        |> Floki.filter_out(".ui-advanced-only")
        |> Floki.find("a[href]")
        |> hrefs()

      assert simple_hrefs != []

      for href <- simple_hrefs do
        refute String.starts_with?(href, "/operations"),
               "Simple Home must not target advanced-only ops: #{href}"
      end

      # The failed run is the Next step, opened on its task.
      assert "/issues/#{issue.id}?from=/" in simple_hrefs
    end

    test "Needs you surfaces stuck in_progress work even with zero blocked or failures", %{
      conn: conn,
      current_company: company
    } do
      {:ok, agent} =
        create_agent(%{
          name: "Stuck Engineer",
          role: :engineer,
          status: :idle,
          url_key: "stuck-eng"
        })

      stale_at =
        DateTime.utc_now() |> DateTime.add(-3 * 3600, :second) |> DateTime.truncate(:second)

      {:ok, issue} =
        create_issue(%{
          title: "Swarm task never finished",
          description: "in progress past threshold",
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: stale_at
        })

      # Confirm patrol sees the stall and there are no blocked/failure signals.
      patrol = Dashboard.patrol_summary(company.id)
      assert patrol.stuck_count > 0
      assert patrol.blocked_count == 0

      {:ok, view, html} = live(conn, "/dashboard")

      assert html =~ "Swarm task never finished"
      assert html =~ ~s(href="/issues/#{issue.id}")
      refute html =~ "Nothing needs you. The team is working."
      # Dual-mode copy: advanced keeps patrol vocabulary; simple stays plain.
      assert html =~ "patrol thresholds"
      # r3: the Simple words are the Next step's (the stall is the first problem).
      main = main_doc(view)
      assert text(main, ".next .paper .nt") == "Check on #{issue.identifier}"
      assert text(main, ".next .paper .obj") =~ "Work stalled"
      refute text(main, ".next") =~ "patrol"
    end

    test "app shell exposes clear desktop and mobile mode controls", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      document = Floki.parse_document!(html)

      # r3: the one Simple/Advanced control is the account row's segment (n2);
      # the old phone header toggle went with the phone header (D10).
      assert Floki.find(document, "[data-ui-mode-toggle]") == []
      assert Floki.find(document, "[data-sidebar-ui-mode-switch]") != []
      assert length(Floki.find(document, "[data-ui-mode-option]")) == 2
      assert Floki.text(Floki.find(document, "[data-sidebar-ui-mode-switch]")) =~ "Simple"
      assert Floki.text(Floki.find(document, "[data-sidebar-ui-mode-switch]")) =~ "Advanced"

      assert html =~ ~s(aria-describedby="interface-mode-help")
      assert html =~ "Simple shows guided essentials"
      assert html =~ "Advanced shows full controls and diagnostics"
      [mode_status] = Floki.find(document, "[data-ui-mode-status]")
      assert Floki.attribute(mode_status, "aria-live") == ["polite"]
      assert Floki.attribute(mode_status, "aria-atomic") == ["true"]
      assert Floki.find(document, "aside.rail #interface-mode-help") == []
      assert Floki.find(document, "header [data-ui-mode-status]") == []
    end

    test "client mode control announces the action and resulting mode" do
      source = File.read!(Path.join([File.cwd!(), "assets/js/app.js"]))

      assert source =~ ~s|toggle.setAttribute("aria-label", `Switch to ${nextLabel} view`)|
      assert source =~ ~s|status.textContent = `${activeLabel} view enabled`|
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
      assert html =~ "Cost guardrails"
      assert html =~ "Extension surface"

      # Readiness renders one card per concern: the org, runtime, and agent
      # guide primitives restated their signal card's summary verbatim.
      refute html =~ "Org hierarchy"
      refute html =~ "Wake loop"
      refute html =~ "Issue memory"

      readiness = element_text(html, "[data-testid='autonomy-readiness']")

      assert readiness =~ "Create mission"
      assert readiness =~ "Create budget"
      assert html =~ ~s(href="/budgets/new")
    end

    test "owner sees global runtime controls in the app shell" do
      conn = authenticated_conn(%{role: "owner", is_board_member: true})
      {:ok, view, html} = live(conn, "/dashboard")

      assert html =~ ~s(data-testid="runtime-controls")
      assert has_element?(view, "summary[aria-label='Company controls']")
      assert html =~ ~s(data-testid="runtime-status-trigger")
      # r3: the power line shows the company state; that agents are off on this
      # server is the first line of the company switch's menu (D1).
      assert html =~ ~s(title="Runtime: Full power")
      assert html =~ "Agents are switched off on this server"
      assert html =~ "Pause"
      assert html =~ "Stop"
      assert html =~ ~s(action="/runtime-control/pause")
      assert html =~ ~s(action="/runtime-control/stop")
      assert html =~ ~s(data-runtime-menu-close)
      refute html =~ ~s(data-testid="desktop-runtime-topbar")
      # r3: the n2 rail and phone top bar replace the drawer sidebar (D10).
      assert html =~ ~s(aria-label="Company and navigation")
      assert html =~ ~s(aria-label="Company and quick actions")
      refute html =~ ~s(id="sidebar")
    end

    test "members and viewers cannot see or forge dashboard company controls" do
      for role <- ["member", "viewer"] do
        conn = authenticated_conn(%{role: role, is_board_member: false})
        company = current_company()

        {:ok, view, _html} = live(conn, "/dashboard")

        refute has_element?(view, "summary[aria-label='Company controls']")

        render_click(view, "low_power_company")
        reloaded = Companies.get_company!(company.id)
        refute Companies.low_power?(reloaded)

        render_click(view, "pause_company")
        assert Companies.get_company!(company.id).status == "active"

        {:ok, _paused} =
          Companies.execute_company_update(reloaded, %{
            status: "paused",
            paused_at: DateTime.utc_now() |> DateTime.truncate(:second),
            paused_reason: "authorization test setup"
          })

        render_click(view, "resume_company")
        assert Companies.get_company!(company.id).status == "paused"
      end
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

      # r3: company state in the power line, the server fact in the menu (D1).
      assert html =~ ~s(title="Runtime: Paused")
      assert html =~ "Agents are switched off on this server"
      assert html =~ "Resume"
      assert html =~ ~s(action="/runtime-control/resume")
      refute html =~ ~s(action="/runtime-control/pause")
    end

    test "low power company shell topbar offers full power instead of low power" do
      conn = authenticated_conn(%{role: "owner", is_board_member: true})
      {:ok, _company} = Companies.enter_low_power_mode(current_company(), "after hours")

      {:ok, _view, html} = live(conn, "/dashboard")

      # r3: company state in the power line, the server fact in the menu (D1).
      assert html =~ ~s(title="Runtime: Low power")
      assert html =~ "Agents are switched off on this server"
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
      # r3: the sign-off is the Next step, a review the owner accepts or sends
      # back (plan P1); the old "Owner decision" card badge went with the card.
      assert text(Floki.parse_document!(html), ".next .paper .eyebrow") =~ "Review"
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
      # r3: the decision is gone from the Next step and Needs you; the task now
      # shows where finished work is listed (Last 24 hours).
      doc = Floki.parse_fragment!(html)
      refute text(doc, ".next") =~ "Owner accepts from dashboard"
      refute text(doc, "section[aria-labelledby='ny-t']") =~ "Owner accepts from dashboard"
      assert text(doc, "section[aria-labelledby='day-t'] .fin") =~ "Owner accepts from dashboard"

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

      assert html =~ "Stuck work"
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

    test "surfaces launch-ready executive overview on dashboard", %{conn: conn} do
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
      assert html =~ "Executive Overview"
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

  describe "r3 Home" do
    setup do
      nw = R3Fixtures.northwind!()
      %{nw: nw, conn: live_session_conn(Phoenix.ConnTest.build_conn(), nw.user, nw.company)}
    end

    test "the Next step is the problem first: Resume Mira", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/")
      main = main_doc(view)

      assert text(main, "h1") == "Home"
      assert text(main, ".next .paper .nt") == "Resume Mira"
      assert text(main, ".next .paper .eyebrow") =~ "Problem"
      assert text(main, ".next .paper .obj") =~ "Mira stopped after 3 failed attempts"
      assert length(Floki.find(main, ".next figure.rb .rb-bar")) == 3

      foot = text(main, ".next .paper .pf")
      assert foot =~ "NW-10"
      assert foot =~ "$3.68"

      assert [primary] = Floki.find(main, ".pw")
      assert Floki.text(primary) =~ "Resume Mira"
      assert Floki.attribute(primary, "phx-click") == ["resume_agent"]
      assert Floki.attribute(primary, "phx-value-id") == [nw.agents["Mira"].id]

      ink = text(main, ".next .ink")
      assert ink =~ "After you resume"
      assert ink =~ "Mira can take new work."
      assert ink =~ "NW-10 stays unassigned until someone retries it."

      assert Floki.attribute(Floki.find(main, ".next .ink a.pd"), "href") == [
               "/issues/#{nw.issues["NW-10"].id}?from=/"
             ]
    end

    test "Needs you lists the other decisions in the owner's order", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/")
      rows = Floki.find(main_doc(view), "section[aria-labelledby='ny-t'] li.row")

      assert Enum.map(rows, &text(&1, ".rt")) == [
               "Answer Ravi's question",
               "Answer Priya's question",
               "Review Ravi's work",
               "Hire a QA engineer"
             ]

      assert Enum.map(rows, &text(&1, "a.go")) == ["Answer", "Answer", "Review", "Open vote"]

      assert Enum.flat_map(rows, &Floki.attribute(Floki.find(&1, "a.go"), "href")) == [
               "/issues/#{nw.issues["NW-6"].id}?from=/",
               "/issues/#{nw.issues["NW-7"].id}?from=/",
               "/issues/#{nw.issues["NW-4"].id}?from=/",
               "/board-approvals/#{nw.hire.id}?from=/"
             ]

      first_meta = text(hd(rows), ".rm")
      assert first_meta =~ "Question"
      assert first_meta =~ "NW-6"
      assert first_meta =~ "Ravi"
      assert first_meta =~ hhmm(nw, 208)

      assert main_doc(view) |> Floki.find("section[aria-labelledby='ny-t'] a.lnk") |> hrefs() ==
               ["/inbox"]
    end

    test "the paused time is said once in the Simple view", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/")

      simple =
        view
        |> main_doc()
        |> Floki.filter_out(".ui-advanced-only")
        |> Floki.raw_html()

      assert length(String.split(simple, hhmm(nw, 228))) == 2
    end

    test "Last 24 hours: what finished, what it cost, and the limit", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      [day] = Floki.find(main_doc(view), "section[aria-labelledby='day-t']")

      assert text(day, ".strip .cell:first-child .v") == "2"
      assert text(day, ".strip .cell:first-child .l") == "tasks finished"
      assert text(day, ".strip .cell:last-child .v") == "$14.82"

      assert Enum.map(Floki.find(day, ".fin li"), &text(&1, ".mono")) == ["NW-3", "NW-8"]

      assert text(day, ".lim-line") ==
               "$186.50 of $300 in the last 30 days (62%)"

      assert [meter] = Floki.find(day, ".lim .tk")
      assert Floki.attribute(meter, "data-ticks") == ["60"]
      assert hrefs(Floki.find(day, ".cf a")) == ["/activity", "/costs"]
    end

    test "the phone team block shows the team and what Theo is doing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      [team] = Floki.find(main_doc(view), "section.team-m")

      assert length(Floki.find(team, ".roster li")) == 7

      theo =
        team
        |> Floki.find(".roster li")
        |> Enum.find(&(text(&1, ".m-name") == "Theo"))

      assert text(theo, ".m-word") =~ "reviewing NW-9"
      assert text(theo, ".m-word") =~ "28 min"
      assert hrefs(Floki.find(team, ".card-h a")) == ["/agents"]
    end

    test "the rail's for-you chips add up to the Inbox badge", %{conn: conn, nw: nw} do
      {:ok, _view, html} = live(conn, "/")
      doc = Floki.parse_document!(html)

      badge =
        doc |> Floki.find("[data-testid='nav-badge-inbox']") |> Floki.text() |> String.trim()

      chips =
        doc
        |> Floki.find("#team-roster li")
        |> Map.new(fn li -> {text(li, ".m-name"), chip_count(li)} end)

      assert badge == "5"
      assert Enum.sum(Map.values(chips)) == 5

      assert chips == %{
               "Mira" => 1,
               "Priya" => 1,
               "Ravi" => 2,
               "Theo" => 1,
               "Ada" => 0,
               "Jun" => 0,
               "Sol" => 0
             }

      assert OwnerAttention.unresolved_count(nw.company.id, nw.user) == 5
    end

    test "Resume Mira resumes her; the task she left is the next problem", %{
      conn: conn,
      nw: nw
    } do
      {:ok, view, _html} = live(conn, "/")

      view |> element(".next .ink button.pw") |> render_click()

      assert Repo.get!(Agent, nw.agents["Mira"].id).status == :idle
      # Her timed-out run on NW-10 is now the task's own problem (B1: a failed run
      # outranks the blocked task on one row).
      assert text(main_doc(view), ".next .paper .nt") == "See why NW-10 stopped"
      assert text(main_doc(view), ".next .paper .eyebrow") =~ "Problem"
    end

    test "resume refuses another company's agent", %{conn: conn} do
      other = R3Fixtures.northwind!()
      {:ok, view, _html} = live(conn, "/")

      render_click(view, "resume_agent", %{"id" => other.agents["Mira"].id})

      assert Repo.get!(Agent, other.agents["Mira"].id).status == :paused
    end

    test "a member cannot resume an agent", %{nw: nw} do
      member = member_conn(nw.company)
      {:ok, view, _html} = live(member, "/")

      render_click(view, "resume_agent", %{"id" => nw.agents["Mira"].id})

      assert Repo.get!(Agent, nw.agents["Mira"].id).status == :paused
    end

    test "with no problem, the first question is the Next step and is answered inline", %{
      conn: conn,
      nw: nw
    } do
      clear_problem!(nw)
      {:ok, view, _html} = live(conn, "/")
      main = main_doc(view)

      assert text(main, ".next .paper .nt") == "Answer Ravi's question"
      assert text(main, ".next .paper .eyebrow") =~ "Question"
      assert text(main, ".next .paper .quote") =~ "what should happen first?"

      assert Enum.map(Floki.find(main, ".next .ink .opt .ot"), &Floki.text/1) == [
               "Retry automatically after 3 days",
               "Email the customer first",
               "Both: email now, retry in 3 days",
               "Or write your own answer"
             ]

      assert Floki.find(main, ".next .ink input.opt-in[checked]") == []
      assert [_] = Floki.find(main, ".next .ink textarea[name='own_response']")

      assert text(main, ".next .ink .ink-note") ==
               "After you send: Ravi gets your answer as a comment and is asked to carry on with NW-6."

      assert [primary] = Floki.find(main, ".pw")
      assert Floki.text(primary) =~ "Send answer"

      view
      |> form(".next form.ink", %{"response" => "Email the customer first"})
      |> render_submit()

      assert Repo.get!(IssueThreadInteraction, nw.questions["Q1"].id).status == :responded
      assert "Email the customer first" in user_comments(nw.issues["NW-6"])
      assert Repo.get!(Cympho.Issues.Issue, nw.issues["NW-6"].id).status == :todo
      assert text(main_doc(view), ".next .paper .nt") == "Answer Priya's question"
    end

    test "an own answer is sent as written", %{conn: conn, nw: nw} do
      clear_problem!(nw)
      {:ok, view, _html} = live(conn, "/")

      view
      |> form(".next form.ink", %{
        "response" => "own",
        "own_response" => "Retry once, then email them"
      })
      |> render_submit()

      assert Repo.get!(IssueThreadInteraction, nw.questions["Q1"].id).status == :responded
      assert "Retry once, then email them" in user_comments(nw.issues["NW-6"])
    end

    test "an empty answer is refused", %{conn: conn, nw: nw} do
      clear_problem!(nw)
      {:ok, view, _html} = live(conn, "/")

      render_submit(view, "respond_questions", %{"_id" => nw.questions["Q1"].id})

      assert_push_event(view, "toast", %{
        message: "Choose an answer or write your own.",
        type: "error"
      })

      assert Repo.get!(IssueThreadInteraction, nw.questions["Q1"].id).status == :pending
    end

    test "an answer to another company's question is refused", %{conn: conn, nw: nw} do
      other = R3Fixtures.northwind!()
      clear_problem!(nw)
      {:ok, view, _html} = live(conn, "/")

      render_submit(view, "respond_questions", %{
        "_id" => other.questions["Q1"].id,
        "response" => "Email the customer first"
      })

      assert Repo.get!(IssueThreadInteraction, other.questions["Q1"].id).status == :pending
    end

    test "a review is opened to decide (S7)", %{conn: conn, nw: nw} do
      clear_problem!(nw)
      clear_questions!(nw)
      {:ok, view, _html} = live(conn, "/")
      main = main_doc(view)

      assert text(main, ".next .paper .nt") == "Review Ravi's work"
      assert text(main, ".next .paper .eyebrow") =~ "Review"
      assert text(main, ".next .ink") =~ "After you accept: NW-4 is marked Done."
      assert [primary] = Floki.find(main, ".pw")
      assert Floki.text(primary) =~ "Open NW-4 to decide"
      assert hrefs([primary]) == ["/issues/#{nw.issues["NW-4"].id}?from=/"]
    end

    test "an approval opens the vote", %{conn: conn, nw: nw} do
      clear_problem!(nw)
      clear_questions!(nw)
      # NW-4's review wake is done and the task moved just now (not a stalled review).
      Repo.update!(Ecto.Changeset.change(nw.review_wake, status: "completed"))

      Repo.update!(
        Ecto.Changeset.change(nw.issues["NW-4"],
          updated_at: DateTime.truncate(DateTime.utc_now(), :second)
        )
      )

      {:ok, view, _html} = live(conn, "/")
      main = main_doc(view)

      assert text(main, ".next .paper .nt") == "Hire a QA engineer"
      assert text(main, ".next .paper .eyebrow") =~ "Approval"
      # The vote page keeps the reason (work track), so the library sentence holds (ground H7).
      assert text(main, ".next .ink .ink-note") ==
               "On the vote page you approve or deny; your reason is saved with your vote."

      assert [primary] = Floki.find(main, ".pw")
      assert Floki.text(primary) =~ "Open vote"
      assert hrefs([primary]) == ["/board-approvals/#{nw.hire.id}?from=/"]
    end

    test "Home follows owner-attention changes live", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/")

      {:ok, _} = Agents.resume_agent(nw.agents["Mira"])

      wait_until(fn ->
        assert text(main_doc(view), ".next .paper .nt") == "See why NW-10 stopped"
      end)
    end
  end

  describe "r3 Home company-wide states" do
    test "agents switched off with nothing to decide: Turn agents on", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      main = main_doc(view)

      assert text(main, ".next .paper .nt") == "Turn agents on"
      assert text(main, ".next .paper .obj") =~ "Agents are switched off on this server."
      assert [summary] = Floki.find(main, ".next .ink details.howto summary.pw")
      assert Floki.text(summary) =~ "How to turn agents on"
      assert length(Floki.find(main, ".pw")) == 1
      assert Floki.find(main, "section[aria-labelledby='ny-t']") == []
    end

    test "paused at the spending limit: Raise the spending limit", %{
      conn: conn,
      current_company: company
    } do
      policy =
        %BudgetPolicy{}
        |> BudgetPolicy.changeset(%{
          company_id: company.id,
          scope: "company",
          period: "monthly",
          budget_limit_usd: Decimal.new("300.00"),
          warning_threshold_pct: Decimal.new("80.0"),
          action_on_exceed: "block"
        })
        |> Repo.insert!()

      Repo.insert!(%TokenUsage{
        company_id: company.id,
        provider: "test",
        model: "test",
        input_tokens: 1,
        output_tokens: 1,
        total_tokens: 2,
        cost_usd: Decimal.new("300.00")
      })

      Repo.insert!(%BudgetIncident{
        company_id: company.id,
        budget_policy_id: policy.id,
        event_type: "budget_exceeded",
        spend_usd: Decimal.new("300.00"),
        budget_limit_usd: Decimal.new("300.00")
      })

      {:ok, view, _html} = live(conn, "/")
      main = main_doc(view)

      assert text(main, ".next .paper .eyebrow") =~ "Company paused"
      assert text(main, ".next .paper .nt") == "Raise the spending limit"

      assert text(main, ".next .paper .obj") ==
               "Agents stopped: the $300 limit for the last 30 days was reached."

      assert [_] = Floki.find(main, ".next .paper .tk.full")
      assert text(main, ".next .ink") =~ "Press Resume agents to start work again."
      assert [primary] = Floki.find(main, ".pw")
      assert Floki.text(primary) =~ "Change limit"
      assert hrefs([primary]) == ["/costs"]
      assert hrefs(Floki.find(main, ".next .ink a.pd")) == ["/costs"]
    end
  end

  defp main_doc(view), do: view |> render() |> Floki.parse_fragment!()

  defp text(node, selector), do: node |> Floki.find(selector) |> Floki.text() |> squish()

  defp squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp hrefs(nodes), do: Enum.flat_map(nodes, &Floki.attribute(&1, "href"))

  defp hhmm(nw, minutes),
    do: nw.anchor |> R3Fixtures.at(minutes) |> Calendar.strftime("%H:%M")

  defp chip_count(li) do
    case li |> Floki.find(".fy") |> Floki.text() |> String.split(" ") do
      [n | _] when n != "" -> String.to_integer(n)
      _ -> 0
    end
  end

  defp user_comments(issue) do
    Repo.all(
      from(c in Cympho.Comments.Comment,
        where: c.issue_id == ^issue.id and c.author_type == "user",
        select: c.body
      )
    )
  end

  defp member_conn(company) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Cympho.Users.create_user(%{
        email: "home-member-#{unique}@example.com",
        name: "Home Member",
        password: "password1234"
      })

    {:ok, _} =
      Companies.create_membership(%{user_id: user.id, company_id: company.id, role: "member"})

    live_session_conn(Phoenix.ConnTest.build_conn(), user, company)
  end

  # No problem left: Mira resumed and the task she left (NW-10) called off.
  defp clear_problem!(nw) do
    {:ok, _} = Agents.resume_agent(nw.agents["Mira"])
    Repo.update!(Ecto.Changeset.change(nw.issues["NW-10"], status: :cancelled))
  end

  # Both questions answered: their tasks are back in To do.
  defp clear_questions!(nw) do
    for {question, task} <- [{"Q1", "NW-6"}, {"Q2", "NW-7"}] do
      Repo.update!(Ecto.Changeset.change(nw.questions[question], status: :responded))
      Repo.update!(Ecto.Changeset.change(nw.issues[task], status: :todo))
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
