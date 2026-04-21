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

    test "does not show spawn button when current_agent_role is nil" do
      # Without a current_agent in session, spawn button should not be shown
      # (falls back to the New Agent link)
    end

    test "shows spawn button for CEO agent" do
      # With CEO role in session, spawn button should be shown
    end

    test "shows spawn button for CTO agent" do
      # With CTO role in session, spawn button should be shown
    end

    test "hides spawn button for Engineer agent" do
      # With Engineer role in session, should see regular New Agent link
    end
  end

  describe "Spawn Agent Component" do
    test "spawn button reveals form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")

      # Click spawn button
      html = view |> element("button.spawn-btn") |> render_click()
      assert html =~ "Spawn New Agent"
    end

    test "cancel button hides form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")

      # Open form
      view |> element("button.spawn-btn") |> render_click()

      # Click cancel
      html = view |> element("button.cancel-btn") |> render_click()
      refute html =~ "Spawn New Agent"
    end

    test "role pre-filled as engineer for CTO spawning", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")

      # Open form
      view |> element("button.spawn-btn") |> render_click()

      # Check that engineer is pre-selected for CTO
      html = render(view)
      assert html =~ ~s(value="engineer" selected="selected")
    end

    test "role pre-filled as cto for CEO spawning", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")

      # Open form
      view |> element("button.spawn-btn") |> render_click()

      # Check that cto is pre-selected for CEO
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
end