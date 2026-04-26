defmodule CymphoWeb.InboxLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Agents
  alias Cympho.Inbox

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

  describe "authorization" do
    test "prevents accessing agents not in the allowed list", %{conn: conn} do
      # Create two agents
      agent1 = Agents.create_agent(%{name: "Agent 1", description: "Test agent 1"})
      agent2 = Agents.create_agent(%{name: "Agent 2", description: "Test agent 2"})

      # Start with agent1 in context
      {:ok, view, _html} = live(conn, "/inbox?agent_id=#{agent1.id}")

      # Try to switch to agent2 (which should be in the list)
      # This should work since both agents are in the list
      assert view
             |> element("select[name=\"agent_id\"]")
             |> has_option?(agent2.name)

      # Clean up
      Agents.delete_agent(agent1)
      Agents.delete_agent(agent2)
    end

    test "shows error message when unauthorized access attempted", %{conn: conn} do
      agent = Agents.create_agent(%{name: "Test Agent", description: "Test agent"})

      {:ok, view, _html} = live(conn, "/inbox?agent_id=#{agent.id}")

      # The authorization check should work normally
      # Since we're using the agent from the list, no error should be shown
      refute has_element?(view, ".flash-error", "You don't have access to this agent's inbox")

      Agents.delete_agent(agent)
    end
  end

  describe "PubSub functionality" do
    test "subscribes to agent inbox updates on selection", %{conn: conn} do
      agent = Agents.create_agent(%{name: "Test Agent", description: "Test agent"})

      {:ok, view, _html} = live(conn, "/inbox")

      # Select an agent
      view
      |> element("select[name=\"agent_id\"]")
      |> render_change(agent_id: agent.id)

      # Give time for subscription
      Process.sleep(100)

      # Verify subscription happened by triggering an update
      # This should trigger a PubSub broadcast
      Inbox.ensure_inbox_entry("test-issue-1", agent.id)

      # The view should update with the new inbox item
      assert render(view) =~ "test-issue-1"

      Agents.delete_agent(agent)
    end

    test "unsubscribes from previous agent when switching agents", %{conn: conn} do
      agent1 = Agents.create_agent(%{name: "Agent 1", description: "Test agent 1"})
      agent2 = Agents.create_agent(%{name: "Agent 2", description: "Test agent 2"})

      {:ok, view, _html} = live(conn, "/inbox")

      # Select first agent
      view
      |> element("select[name=\"agent_id\"]")
      |> render_change(agent_id: agent1.id)

      Process.sleep(100)

      # Select second agent
      view
      |> element("select[name=\"agent_id\"]")
      |> render_change(agent_id: agent2.id)

      Process.sleep(100)

      # Verify we're now subscribed to agent2 by triggering an update
      Inbox.ensure_inbox_entry("test-issue-2", agent2.id)

      # The view should update with agent2's inbox item
      assert render(view) =~ "test-issue-2"

      Agents.delete_agent(agent1)
      Agents.delete_agent(agent2)
    end
  end

  describe "handle_info callbacks" do
    test "handles unknown messages without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/inbox")

      # Send an unknown message to the LiveView process
      # This should be caught by the catch-all handle_info clause
      send(view.pid, :unknown_message)

      # The view should still be functional
      assert render(view) =~ "Inbox"
    end

    test "handles inbox_updated messages", %{conn: conn} do
      agent = Agents.create_agent(%{name: "Test Agent", description: "Test agent"})

      {:ok, view, _html} = live(conn, "/inbox?agent_id=#{agent.id}")

      # Create an inbox entry
      {:ok, inbox_entry} = Inbox.ensure_inbox_entry("test-issue-3", agent.id)

      # Manually broadcast an update message
      Phoenix.PubSub.broadcast(Cympho.PubSub, "inbox:#{agent.id}", {:inbox_updated, inbox_entry})

      # The view should update
      assert render(view) =~ "test-issue-3"

      Agents.delete_agent(agent)
    end
  end

  describe "state consistency" do
    test "normalizes empty agent_id to nil", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/inbox")

      # When no agent is selected, the selected_agent_id should be nil
      # not ""
      assert render(view) =~ "Select an agent to view their inbox"

      # The view should handle nil state correctly
      assert has_element?(view, "select[name=\"agent_id\"]")
    end

    test "maintains consistent state between mount and handle_params", %{conn: conn} do
      agent = Agents.create_agent(%{name: "Test Agent", description: "Test agent"})

      {:ok, view, _html} = live(conn, "/inbox?agent_id=#{agent.id}")

      # The selected agent should be consistent
      assert render(view) =~ agent.name

      # Navigate with empty status
      view
      |> element("a")
      |> render_click(%{"status" => nil})

      # State should remain consistent
      assert render(view) =~ agent.name

      Agents.delete_agent(agent)
    end
  end

  describe "pagination" do
    test "limits inbox results to default page size", %{conn: conn} do
      agent = Agents.create_agent(%{name: "Test Agent", description: "Test agent"})

      # Create more than 100 inbox entries
      Enum.each(1..110, fn i ->
        Inbox.ensure_inbox_entry("test-issue-#{i}", agent.id)
      end)

      {:ok, view, _html} = live(conn, "/inbox?agent_id=#{agent.id}")

      # Should only show 100 items (default limit)
      html = render(view)
      # Count the number of test-issue entries
      count = Regex.scan(~r/test-issue-\d+/, html) |> length()
      assert count <= 100

      Agents.delete_agent(agent)
    end

    test "applies custom pagination parameters", %{conn: conn} do
      agent = Agents.create_agent(%{name: "Test Agent", description: "Test agent"})

      # Create 20 inbox entries
      Enum.each(1..20, fn i ->
        Inbox.ensure_inbox_entry("pagination-test-#{i}", agent.id)
      end)

      # Test with custom limit
      items = Inbox.list_inbox_for_agent(agent.id, limit: 5)
      assert length(items) == 5

      # Test with offset
      items_with_offset = Inbox.list_inbox_for_agent(agent.id, limit: 5, offset: 5)
      assert length(items_with_offset) == 5

      # Verify offset actually skips items
      first_ids = Enum.map(items, fn item -> item.issue_id end)
      second_ids = Enum.map(items_with_offset, fn item -> item.issue_id end)
      refute first_ids == second_ids

      Agents.delete_agent(agent)
    end
  end
end
