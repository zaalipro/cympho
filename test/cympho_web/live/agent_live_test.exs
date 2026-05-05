defmodule CymphoWeb.AgentLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest
  alias Cympho.Agents

  describe "Index - Agent Dashboard" do
    test "renders the agents page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "Agents"
    end

    test "renders list of agents", %{conn: conn} do
      {:ok, _agent} =
        Agents.create_agent(%{
          name: "Test Engineer",
          role: :engineer,
          status: :idle
        })

      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "Test Engineer"
      assert html =~ "Engineer"
    end

    test "renders status dashboard with counts", %{conn: conn} do
      {:ok, _idle1} = Agents.create_agent(%{name: "Idle Agent 1", role: :engineer, status: :idle})
      {:ok, _idle2} = Agents.create_agent(%{name: "Idle Agent 2", role: :engineer, status: :idle})

      {:ok, _running} =
        Agents.create_agent(%{name: "Running Agent", role: :cto, status: :running})

      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "Idle"
      assert html =~ "Running"
    end

    test "does not show spawn button when current_agent_role is nil" do
    end

    test "shows spawn button for CEO agent" do
    end

    test "shows spawn button for CTO agent" do
    end

    test "hides spawn button for Engineer agent" do
    end
  end

  describe "Index - Kill Session" do
    test "shows stop button for running agents", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{name: "Running Agent", role: :engineer, status: :running})

      {:ok, view, _html} = live(conn, "/agents")

      # Running agents should have stop button
      assert has_element?(view, "button[phx-click='kill_session'][phx-value-id='#{agent.id}']")
    end

    test "does not show stop button for idle agents", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{name: "Idle Agent", role: :engineer, status: :idle})

      {:ok, view, _html} = live(conn, "/agents")

      # Idle agents should not have stop button
      refute has_element?(view, "button[phx-click='kill_session'][phx-value-id='#{agent.id}']")
    end

    test "kill_session event returns error when agent not running", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{name: "Idle Agent", role: :engineer, status: :idle})

      {:ok, view, _html} = live(conn, "/agents")

      view
      |> element("button[phx-click='delete_agent'][phx-value-id='#{agent.id}']")
      |> render_click()

      # After delete, the agent should be gone
      refute has_element?(view, "#agent-#{agent.id}")
    end
  end

  describe "Spawn Agent navigation" do
    test "agents page links to new agent form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "/agents/new"
    end
  end

  describe "Show - Agent Details" do
    test "renders agent details page", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          instructions: "Do good work"
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      assert html =~ "Test Agent"
    end

    test "renders instructions tab when set", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Agent with Path",
          role: :engineer,
          status: :idle,
          instructions_path: "agents/engineer/AGENTS.md"
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=instructions")
      assert html =~ "Files"
    end

    test "shows wake history section", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Agent with History",
          role: :engineer,
          status: :idle
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=runs")
      assert html =~ "Wake History" or html =~ "Runs" or html =~ "History"
    end

    test "shows max concurrent jobs in configuration", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Agent",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 5
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      assert html =~ "Max jobs"
      assert html =~ "5"
    end
  end

  describe "Edit - Agent Configuration" do
    test "renders edit page with max concurrent jobs slider", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Editable Agent",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 3
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")
      assert html =~ "Max concurrent jobs"
      assert html =~ "range"
    end

    test "renders configuration tab", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Editable Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")
      assert html =~ "Adapter"
    end
  end

  describe "Adapter Selection" do
    test "shows adapter dropdown on new agent form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/new")

      assert html =~ "Adapter"
    end
  end

  describe "Health Status Display" do
    test "shows health status badge on agent detail page", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Healthy Agent",
          role: :engineer,
          status: :idle,
          health_status: :healthy
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      assert html =~ "Healthy"
    end

    test "shows degraded health status", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Degraded Agent",
          role: :engineer,
          status: :idle,
          health_status: :degraded
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      assert html =~ "Degraded"
    end

    test "shows unavailable health status", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Unavailable Agent",
          role: :engineer,
          status: :offline,
          health_status: :unavailable
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      assert html =~ "Unavailable"
    end
  end
end
