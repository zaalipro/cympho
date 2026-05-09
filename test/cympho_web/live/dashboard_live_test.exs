defmodule CymphoWeb.DashboardLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Cympho.Agents
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
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
      assert html =~ "blocked issue"
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
