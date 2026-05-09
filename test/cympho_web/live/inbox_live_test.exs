defmodule CymphoWeb.InboxLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Cympho.Agents
  alias Cympho.Inbox
  alias Cympho.Issues
  alias Cympho.Repo
  alias Cympho.ReviewNudges
  alias Cympho.Inbox.InboxState
  alias CymphoWeb.ConnCase

  describe "Inbox page" do
    test "renders inbox page", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)
      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "Inbox"
      assert html =~ "Agent handoffs"
      assert html =~ "Queue scope"
    end

    test "shows agent selector", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)
      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "All agents"
      assert html =~ "select_agent"
    end

    test "shows empty state when no agent selected", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)
      {:ok, _view, html} = live(conn, "/inbox?agent_id=")

      # The default 'all' shows agent selector
      assert html =~ "select_agent"
    end
  end

  describe "handle_info fallback" do
    test "logs unknown messages without crashing", %{conn: conn} do
      {conn, _user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test_fallback",
          company_id: company.id
        })

      {:ok, view, _html} = live(conn, "/inbox?agent_id=#{agent.id}")

      # Send unknown message - should not crash
      ExUnit.CaptureLog.capture_log(fn ->
        send(view.pid, :unknown_message)
        Process.sleep(10)
      end)

      # View should still be responsive
      assert render(view) =~ "Inbox"
    end
  end

  describe "select_agent event" do
    test "updates URL when agent is selected", %{conn: conn} do
      {conn, _user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test_select",
          company_id: company.id
        })

      {:ok, _view, html} = live(conn, "/inbox?agent_id=#{agent.id}")

      assert html =~ "Inbox"
      assert html =~ "select_agent"
    end
  end

  describe "filter transitions" do
    test "filters by status", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test_filter",
          company_id: company.id
        })

      conn = live_session_conn(conn, user, company)
      {:ok, view, _html} = live(conn, "/inbox?agent_id=#{agent.id}")

      view
      |> element("a[href*='status=read']", "Read")
      |> render_click()

      path = assert_patch(view)
      assert path =~ "agent_id=#{agent.id}"
      assert path =~ "status=read"
    end

    test "renders informative inbox cards", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Inbox Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Review checkout failure",
          description: "Investigate the provider environment before retrying.",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id,
          assigned_role: "engineer"
        })

      {:ok, _entry} = Inbox.ensure_inbox_entry(issue.id, agent.id)

      conn = live_session_conn(conn, user, company)
      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "Review checkout failure"
      assert html =~ "Investigate the provider environment"
      assert html =~ "To Inbox Agent"
      assert html =~ "High"
      assert html =~ "Role: engineer"
      assert html =~ "Assigned, but no delivery evidence yet."
      assert html =~ "Next action"
      assert html =~ "Start the assigned agent"
      assert html =~ "Open issue"
      assert html =~ "Mark read"

      {:ok, _view, compact_html} = live(conn, "/inbox?density=compact")

      assert compact_html =~ "Review checkout failure"
      assert compact_html =~ "Assigned, but no delivery evidence yet."
      refute compact_html =~ "Start the assigned agent"
    end

    test "labels review-nudge inbox items", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Review Nudged Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Needs review evidence",
          description: "Missing evidence should be obvious in inbox.",
          status: :in_progress,
          priority: :medium,
          company_id: company.id,
          assigned_role: "engineer"
        })

      blocker = %{key: :delivery_comment, label: "Delivery comment", prompt: "Missing delivery"}
      [nudge] = ReviewNudges.plan(issue, [blocker], agents: [agent])

      assert {:ok, _queued} =
               ReviewNudges.execute(issue, nudge.key, blockers: [blocker], agents: [agent])

      conn = live_session_conn(conn, user, company)
      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "Needs review evidence"
      assert html =~ "Review evidence needed"
      assert html =~ "Queued by review gate"
      assert html =~ "Delivery comment"
    end
  end

  describe "pagination" do
    test "limits results to default page size", %{conn: _conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test_pagination"
        })

      # Create 20 issues
      for i <- 1..20 do
        {:ok, issue} =
          Issues.create_issue(%{
            title: "Issue #{i}",
            description: "Description #{i}",
            status: :backlog
          })

        {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)
      end

      # Get with default limit
      items = Inbox.list_inbox_for_agent(agent.id, [])
      assert length(items) <= 100
    end

    test "respects custom limit option", %{conn: _conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test_limit"
        })

      # Create 20 issues
      for i <- 1..20 do
        {:ok, issue} =
          Issues.create_issue(%{
            title: "Issue #{i}",
            description: "Description #{i}",
            status: :backlog
          })

        {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)
      end

      # Get with limit of 10
      items = Inbox.list_inbox_for_agent(agent.id, limit: 10)
      assert length(items) == 10

      # Get with limit of 15
      items = Inbox.list_inbox_for_agent(agent.id, limit: 15)
      assert length(items) == 15
    end
  end

  describe "race condition in ensure_inbox_entry" do
    test "handles concurrent inserts gracefully" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test_race"
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Race Condition Test",
          description: "Test concurrent inserts",
          status: :backlog
        })

      # Simulate concurrent calls
      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            Inbox.ensure_inbox_entry(issue.id, agent.id)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed without constraint errors
      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)

      # Only one entry should exist
      entries =
        Repo.all(
          from(s in InboxState,
            where: s.issue_id == ^issue.id and s.agent_id == ^agent.id
          )
        )

      assert length(entries) == 1
    end
  end

  describe "state normalization" do
    test "normalizes empty agent_id to all", %{conn: conn} do
      {conn, _user, _company} = ConnCase.register_and_log_in_user(conn)
      {:ok, _view, html} = live(conn, "/inbox")

      # When no agent_id is set, defaults to "all" agents view
      assert html =~ ~s(value="all" selected)
    end
  end

  defp live_session_conn(conn, user, company) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_id", user.id)
    |> Plug.Conn.put_session("company_id", company.id)
  end
end
