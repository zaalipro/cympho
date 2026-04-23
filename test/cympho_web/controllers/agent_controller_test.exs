defmodule CymphoWeb.AgentControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Agents
  alias Cympho.Projects

  setup do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "Test Agent",
        role: :engineer,
        status: :idle
      })

    {:ok, project} =
      Projects.create_project(%{
        name: "Test Project",
        prefix: "TST"
      })

    %{agent: agent, project: project}
  end

  describe "GET /api/agents/:id/inbox" do
    test "returns empty list for agent with no assignments", %{conn: conn, agent: agent} do
      conn =
        conn
        |> put_req_header("x-agent-id", agent.id)
        |> get("/api/agents/#{agent.id}/inbox")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns only issues assigned to the agent", %{
      conn: conn,
      agent: agent,
      project: project
    } do
      {:ok, _assigned} =
        Cympho.Issues.create_issue(%{
          title: "My Issue",
          description: "desc",
          status: :in_progress,
          priority: :high,
          assignee_id: agent.id,
          project_id: project.id
        })

      conn =
        conn
        |> put_req_header("x-agent-id", agent.id)
        |> get("/api/agents/#{agent.id}/inbox")

      assert %{"data" => [issue]} = json_response(conn, 200)
      assert issue["title"] == "My Issue"
      assert issue["status"] == "in_progress"
      assert issue["priority"] == "high"
      assert issue["assignee_id"] == agent.id
    end

    test "returns issues sorted by priority (high first)", %{
      conn: conn,
      agent: agent,
      project: project
    } do
      {:ok, _low} =
        Cympho.Issues.create_issue(%{
          title: "Low Priority",
          description: "desc",
          status: :todo,
          priority: :low,
          assignee_id: agent.id,
          project_id: project.id
        })

      {:ok, _high} =
        Cympho.Issues.create_issue(%{
          title: "High Priority",
          description: "desc",
          status: :todo,
          priority: :high,
          assignee_id: agent.id,
          project_id: project.id
        })

      conn =
        conn
        |> put_req_header("x-agent-id", agent.id)
        |> get("/api/agents/#{agent.id}/inbox")

      assert %{"data" => [first, second]} = json_response(conn, 200)
      assert first["priority"] == "high"
      assert second["priority"] == "low"
    end

    test "excludes issues with done or backlog status", %{
      conn: conn,
      agent: agent,
      project: project
    } do
      {:ok, _done} =
        Cympho.Issues.create_issue(%{
          title: "Done Issue",
          description: "desc",
          status: :done,
          priority: :high,
          assignee_id: agent.id,
          project_id: project.id
        })

      {:ok, _backlog} =
        Cympho.Issues.create_issue(%{
          title: "Backlog Issue",
          description: "desc",
          status: :backlog,
          priority: :medium,
          assignee_id: agent.id,
          project_id: project.id
        })

      conn =
        conn
        |> put_req_header("x-agent-id", agent.id)
        |> get("/api/agents/#{agent.id}/inbox")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns 404 for non-existent agent", %{conn: conn, agent: agent} do
      conn =
        conn
        |> put_req_header("x-agent-id", agent.id)
        |> get("/api/agents/00000000-0000-0000-0000-000000000000/inbox")

      assert %{"errors" => _} = json_response(conn, 404)
    end

    test "returns 401 when X-Agent-ID header is missing", %{conn: conn, agent: agent} do
      conn = get(conn, "/api/agents/#{agent.id}/inbox")
      assert %{"errors" => _} = json_response(conn, 401)
    end
  end

  describe "PATCH /api/agents/:id/status" do
    test "updates own status to sleeping", %{conn: conn, agent: agent} do
      conn =
        conn
        |> put_req_header("x-agent-id", agent.id)
        |> patch("/api/agents/#{agent.id}/status", %{"status" => "sleeping"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "sleeping"
      assert data["last_heartbeat_at"] != nil
    end

    test "updates own status to offline", %{conn: conn, agent: agent} do
      conn =
        conn
        |> put_req_header("x-agent-id", agent.id)
        |> patch("/api/agents/#{agent.id}/status", %{"status" => "offline"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "offline"
    end

    test "updates own status to idle", %{conn: conn, agent: agent} do
      {:ok, _} = Agents.update_agent(agent, %{status: :sleeping})

      conn =
        conn
        |> put_req_header("x-agent-id", agent.id)
        |> patch("/api/agents/#{agent.id}/status", %{"status" => "idle"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "idle"
    end

    test "CTO can update any agent's status", %{conn: conn, agent: agent} do
      {:ok, cto} =
        Agents.create_agent(%{
          name: "CTO Agent",
          role: :cto
        })

      conn =
        conn
        |> put_req_header("x-agent-id", cto.id)
        |> patch("/api/agents/#{agent.id}/status", %{"status" => "sleeping"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "sleeping"
    end

    test "CEO can update any agent's status", %{conn: conn, agent: agent} do
      {:ok, ceo} =
        Agents.create_agent(%{
          name: "CEO Agent",
          role: :ceo
        })

      conn =
        conn
        |> put_req_header("x-agent-id", ceo.id)
        |> patch("/api/agents/#{agent.id}/status", %{"status" => "offline"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "offline"
    end

    test "returns 403 when another agent tries to update status", %{conn: conn, agent: agent} do
      {:ok, other} =
        Agents.create_agent(%{
          name: "Other Agent",
          role: :engineer
        })

      conn =
        conn
        |> put_req_header("x-agent-id", other.id)
        |> patch("/api/agents/#{agent.id}/status", %{"status" => "sleeping"})

      assert %{"errors" => _} = json_response(conn, 403)
    end

    test "returns 422 for invalid status", %{conn: conn, agent: agent} do
      conn =
        conn
        |> put_req_header("x-agent-id", agent.id)
        |> patch("/api/agents/#{agent.id}/status", %{"status" => "invalid"})

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "returns 400 when status field is missing", %{conn: conn, agent: agent} do
      conn =
        conn
        |> put_req_header("x-agent-id", agent.id)
        |> patch("/api/agents/#{agent.id}/status", %{})

      assert %{"errors" => _} = json_response(conn, 400)
    end

    test "returns 404 for non-existent agent", %{conn: conn, agent: agent} do
      conn =
        conn
        |> put_req_header("x-agent-id", agent.id)
        |> patch("/api/agents/00000000-0000-0000-0000-000000000000/status", %{"status" => "idle"})

      assert %{"errors" => _} = json_response(conn, 404)
    end

    test "returns 401 when X-Agent-ID header is missing", %{conn: conn, agent: agent} do
      conn = patch(conn, "/api/agents/#{agent.id}/status", %{"status" => "idle"})
      assert %{"errors" => _} = json_response(conn, 401)
    end
  end
end
