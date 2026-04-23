defmodule CymphoWeb.DashboardControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Agents
  alias Cympho.Issues

  describe "GET /api/dashboard" do
    test "returns dashboard summary JSON", %{conn: conn} do
      conn = get(conn, ~p"/api/dashboard")
      assert %{"data" => data} = json_response(conn, 200)
      assert Map.has_key?(data, "active_agents")
      assert Map.has_key?(data, "total_agents")
      assert Map.has_key?(data, "throughput")
      assert Map.has_key?(data, "bottlenecks")
      assert Map.has_key?(data, "routine_health")
    end

    test "reflects created agents and issues", %{conn: conn} do
      {:ok, _} =
        Agents.create_agent(%{
          name: "Dash Agent",
          role: :engineer,
          status: :idle,
          url_key: "dash1"
        })

      {:ok, _} = Issues.create_issue(%{title: "Dash Issue", description: "desc"})

      conn = get(conn, ~p"/api/dashboard")
      %{"data" => data} = json_response(conn, 200)

      assert data["active_agents"] >= 1
      assert data["total_agents"] >= 1

      status_counts = data["issue_status_counts"]
      assert is_list(status_counts)
    end
  end
end
