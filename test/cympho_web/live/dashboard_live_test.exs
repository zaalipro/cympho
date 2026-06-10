defmodule CymphoWeb.DashboardLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Cympho.Agents
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

  describe "Dashboard page" do
    test "root route redirects to dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Dashboard"
      assert html =~ "Active Agents"
    end

    test "renders dashboard with metric cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Active Agents"
      assert html =~ "Agents"
      assert html =~ "Closed 7d"
      assert html =~ "Runtime capacity"
      assert html =~ "Autonomy readiness"
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
      assert html =~ "Floating work needs strategy links"
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
      assert html =~ "6 local slots"
      assert html =~ "Runtime capacity"
    end

    test "renders all computed next actions", %{conn: conn} do
      {:ok, _} = create_issue(%{title: "Blocked work", status: :blocked})

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Next actions"
      assert html =~ "Review mode is on"
      assert html =~ "Enable runtime when ready"
      assert html =~ ~s(href="/operations#runtime-launch-checklist")
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
          config: %{"command" => "echo"},
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

  defp live_session_conn(conn, user, company) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_id", user.id)
    |> Plug.Conn.put_session("company_id", company.id)
  end
end
