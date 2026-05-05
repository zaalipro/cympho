defmodule CymphoWeb.DashboardLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Agents
  alias Cympho.Issues

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
    end

    test "shows agent count from database", %{conn: conn} do
      {:ok, _} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          url_key: "test1"
        })

      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Test Agent"
    end

    test "shows issue status breakdown", %{conn: conn} do
      {:ok, _} = Issues.create_issue(%{title: "Dash Issue", description: "d", status: :backlog})

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
end
