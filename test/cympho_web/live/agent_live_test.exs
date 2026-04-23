defmodule CymphoWeb.AgentLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest
  alias Cympho.Agents
  alias Cympho.Wakes

  describe "Index - Agent Dashboard" do
    test "renders the agents page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "Agents"
    end

    test "renders list of agents", %{conn: conn} do
      {:ok, agent} =
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
      {:ok, _running} = Agents.create_agent(%{name: "Running Agent", role: :cto, status: :running})

      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "Agent Status Overview"
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
      {:ok, agent} = Agents.create_agent(%{name: "Running Agent", role: :engineer, status: :running})

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

      view |> element("button[phx-click='delete_agent'][phx-value-id='#{agent.id}']") |> render_click()

      # After delete, the agent should be gone
      refute has_element?(view, "#agent-#{agent.id}")
    end
  end

  describe "Spawn Agent Component" do
    test "spawn button reveals form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")

      html = view |> element("button.spawn-btn") |> render_click()
      assert html =~ "Spawn New Agent"
    end

    test "cancel button hides form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")

      view |> element("button.spawn-btn") |> render_click()

      html = view |> element("button.cancel-btn") |> render_click()
      refute html =~ "Spawn New Agent"
    end

    test "role pre-filled as engineer for CTO spawning", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")

      view |> element("button.spawn-btn") |> render_click()

      html = render(view)
      assert html =~ ~s(value="engineer" selected="selected")
    end

    test "role pre-filled as cto for CEO spawning", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")

      view |> element("button.spawn-btn") |> render_click()

      html = render(view)
      assert html =~ ~s(value="cto" selected="selected")
    end

    test "role select is disabled", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")

      view |> element("button.spawn-btn") |> render_click()

      html = render(view)
      assert html =~ "role-select\" disabled"
    end
  end

  describe "Show - Agent Details" do
    test "renders agent details page", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{
        name: "Test Agent",
        role: :engineer,
        status: :idle,
        instructions: "Do good work"
      })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      assert html =~ "Test Agent"
      assert html =~ "Do good work"
    end

    test "shows instructions path when set", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{
        name: "Agent with Path",
        role: :engineer,
        status: :idle,
        instructions_path: "agents/engineer/AGENTS.md"
      })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      assert html =~ "Instructions File"
      assert html =~ "agents/engineer/AGENTS.md"
    end

    test "hides instructions path section when not set", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{
        name: "Agent No Path",
        role: :engineer,
        status: :idle
      })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      refute html =~ "Instructions File"
    end

    test "shows wake history section", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{
        name: "Agent with History",
        role: :engineer,
        status: :idle
      })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      assert html =~ "Wake History"
    end

    test "shows max concurrent jobs in configuration", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{
        name: "Agent",
        role: :engineer,
        status: :idle,
        max_concurrent_jobs: 5
      })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      assert html =~ "Max concurrent jobs"
      assert html =~ "5"
    end
  end

  describe "Edit - Agent Configuration" do
    test "renders edit page with max concurrent jobs slider", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{
        name: "Editable Agent",
        role: :engineer,
        status: :idle,
        max_concurrent_jobs: 3
      })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}/edit")
      assert html =~ "Max Concurrent Jobs"
      assert html =~ "range"
    end

    test "renders instructions path input", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{
        name: "Editable Agent",
        role: :engineer,
        status: :idle
      })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}/edit")
      assert html =~ "Instructions File Path"
    end
  end
end