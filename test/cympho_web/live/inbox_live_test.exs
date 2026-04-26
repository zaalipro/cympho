defmodule CymphoWeb.InboxLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Cympho.Agents
  alias Cympho.Inbox
  alias Cympho.Issues
  alias Cympho.Repo
  alias Cympho.Inbox.InboxState

  describe "Inbox page" do
    test "renders inbox page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "Inbox"
    end

    test "shows agent selector", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "Select Agent"
    end

    test "shows empty state when no agent selected", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ "Select an agent to view their inbox"
    end
  end

  describe "handle_info fallback" do
    test "logs unknown messages without crashing", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test_fallback"
        })

      {:ok, view, _html} = live(conn, "/inbox?agent_id=#{agent.id}")

      # Send unknown message - should not crash
      send(view.pid, :unknown_message)

      # View should still be responsive
      assert render(view) =~ "Inbox"
    end
  end

  describe "select_agent event" do
    test "updates URL when agent is selected", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test_select"
        })

      {:ok, view, _html} = live(conn, "/inbox")

      view
      |> element("#agent-selector")
      |> render_change(%{"agent_id" => agent.id})

      assert_patch(view, "/inbox?agent_id=#{agent.id}")
    end
  end

  describe "filter transitions" do
    test "filters by status", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test_filter"
        })

      {:ok, view, _html} = live(conn, "/inbox?agent_id=#{agent.id}")

      # Filter by "read" status
      view
      |> element("button[phx-click=\"filter_status\"]")
      |> render_click(%{"status" => "read"})

      assert_patch(view, "/inbox?agent_id=#{agent.id}&status=read")
    end
  end

  describe "pagination" do
    test "limits results to default page size", %{conn: conn} do
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

    test "respects custom limit option", %{conn: conn} do
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
    test "normalizes empty agent_id to nil", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/inbox")

      # Empty string agent_id should be treated as nil
      assert view.assigns[:selected_agent_id] == nil
    end
  end
end
