defmodule CymphoWeb.AgentControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.{Agents, Authentication, Companies, Projects}

  setup do
    {:ok, company} =
      Companies.create_company(%{
        name: "Agent Co #{System.unique_integer([:positive])}",
        slug: "agent-co-#{System.unique_integer([:positive])}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Test Agent",
        role: :engineer,
        status: :idle,
        company_id: company.id
      })

    {:ok, {_key, agent_token}} = Authentication.create_agent_api_key(agent.id, "Test Key")

    {:ok, project} =
      Projects.create_project(%{
        name: "Test Project",
        prefix: "TST",
        company_id: company.id
      })

    %{agent: agent, agent_token: agent_token, project: project, company: company}
  end

  defp put_api_key(conn, key), do: put_req_header(conn, "x-api-key", key)

  describe "GET /api/agents/:id/inbox" do
    test "returns empty list for agent with no assignments", %{
      conn: conn,
      agent: agent,
      agent_token: token
    } do
      conn =
        conn
        |> put_api_key(token)
        |> get("/api/agents/#{agent.id}/inbox")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns only issues assigned to the agent", %{
      conn: conn,
      agent: agent,
      agent_token: token,
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
        |> put_api_key(token)
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
      agent_token: token,
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
        |> put_api_key(token)
        |> get("/api/agents/#{agent.id}/inbox")

      assert %{"data" => [first | _]} = json_response(conn, 200)
      assert first["title"] == "High Priority"
    end

    test "filters out completed and backlog issues", %{
      conn: conn,
      agent: agent,
      agent_token: token,
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
        |> put_api_key(token)
        |> get("/api/agents/#{agent.id}/inbox")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns 404 for non-existent agent", %{conn: conn, agent_token: token} do
      conn =
        conn
        |> put_api_key(token)
        |> get("/api/agents/00000000-0000-0000-0000-000000000000/inbox")

      assert %{"errors" => _} = json_response(conn, 404)
    end

    test "returns 401 when authentication header is missing", %{conn: conn, agent: agent} do
      conn = get(conn, "/api/agents/#{agent.id}/inbox")
      assert %{"errors" => _} = json_response(conn, 401)
    end
  end

  describe "PATCH /api/agents/:id/status" do
    test "updates own status to sleeping", %{conn: conn, agent: agent, agent_token: token} do
      conn =
        conn
        |> put_api_key(token)
        |> patch("/api/agents/#{agent.id}/status", %{"status" => "sleeping"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "sleeping"
      assert data["last_heartbeat_at"] != nil
    end

    test "updates own status to offline", %{conn: conn, agent: agent, agent_token: token} do
      conn =
        conn
        |> put_api_key(token)
        |> patch("/api/agents/#{agent.id}/status", %{"status" => "offline"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "offline"
    end

    test "updates own status to idle", %{conn: conn, agent: agent, agent_token: token} do
      {:ok, _} = Agents.update_agent(agent, %{status: :sleeping})

      conn =
        conn
        |> put_api_key(token)
        |> patch("/api/agents/#{agent.id}/status", %{"status" => "idle"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "idle"
    end

    test "CTO can update any agent's status", %{conn: conn, agent: agent, company: company} do
      {:ok, cto} =
        Agents.create_agent(%{
          name: "CTO Agent",
          role: :cto,
          company_id: company.id
        })

      {:ok, {_key, cto_token}} = Authentication.create_agent_api_key(cto.id, "CTO Key")

      conn =
        conn
        |> put_api_key(cto_token)
        |> patch("/api/agents/#{agent.id}/status", %{"status" => "sleeping"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "sleeping"
    end

    test "CEO can update any agent's status", %{conn: conn, agent: agent, company: company} do
      {:ok, ceo} =
        Agents.create_agent(%{
          name: "CEO Agent",
          role: :ceo,
          company_id: company.id
        })

      {:ok, {_key, ceo_token}} = Authentication.create_agent_api_key(ceo.id, "CEO Key")

      conn =
        conn
        |> put_api_key(ceo_token)
        |> patch("/api/agents/#{agent.id}/status", %{"status" => "offline"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "offline"
    end

    test "returns 403 when another agent tries to update status", %{
      conn: conn,
      agent: agent,
      company: company
    } do
      {:ok, other} =
        Agents.create_agent(%{
          name: "Other Agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, {_key, other_token}} = Authentication.create_agent_api_key(other.id, "Other Key")

      conn =
        conn
        |> put_api_key(other_token)
        |> patch("/api/agents/#{agent.id}/status", %{"status" => "sleeping"})

      assert %{"errors" => _} = json_response(conn, 403)
    end

    test "returns 422 for invalid status", %{conn: conn, agent: agent, agent_token: token} do
      conn =
        conn
        |> put_api_key(token)
        |> patch("/api/agents/#{agent.id}/status", %{"status" => "invalid"})

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "returns 400 when status field is missing", %{conn: conn, agent: agent, agent_token: token} do
      conn =
        conn
        |> put_api_key(token)
        |> patch("/api/agents/#{agent.id}/status", %{})

      assert %{"errors" => _} = json_response(conn, 400)
    end

    test "returns 403 for non-existent agent (unauthorized to update different agent)", %{conn: conn, agent_token: token} do
      conn =
        conn
        |> put_api_key(token)
        |> patch("/api/agents/00000000-0000-0000-0000-000000000000/status", %{"status" => "idle"})

      assert %{"errors" => _} = json_response(conn, 403)
    end

    test "returns 401 when authentication header is missing", %{conn: conn, agent: agent} do
      conn = patch(conn, "/api/agents/#{agent.id}/status", %{"status" => "idle"})
      assert %{"errors" => _} = json_response(conn, 401)
    end
  end
end
