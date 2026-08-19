defmodule CymphoWeb.McpControllerTest do
  use CymphoWeb.ConnCase, async: false

  alias Cympho.{Agents, Authentication, Comments, Companies, Issues, PrincipalPermissions}
  alias Cympho.RateLimiting.AgentActionLimiter

  setup %{conn: conn} do
    {:ok, company} =
      Companies.create_company(%{
        name: "MCP HTTP #{System.unique_integer([:positive])}",
        slug: "mcp-http-#{System.unique_integer([:positive])}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "MCP API Agent",
        role: :cto,
        status: :idle,
        company_id: company.id
      })

    {:ok, {_key, agent_token}} = Authentication.create_agent_api_key(agent.id, "MCP Test Key")

    conn = put_req_header(conn, "x-api-key", agent_token)

    %{conn: conn, company: company, agent: agent}
  end

  test "advertises issue comment tools", %{conn: conn} do
    conn = get(conn, "/api/mcp/tools")

    tool_names =
      conn
      |> json_response(200)
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])

    assert "list_issue_comments" in tool_names
    assert "create_issue_comment" in tool_names
  end

  test "returns issue comments through MCP call", %{conn: conn, company: company} do
    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "HTTP MCP trace",
        skip_auto_assign: true
      })

    {:ok, _comment} =
      Comments.create_comment(%{
        issue_id: issue.id,
        body: "Visible through MCP.",
        author_type: "system",
        author_id: "test"
      })

    conn =
      post(conn, "/api/mcp/call", %{
        "tool" => "list_issue_comments",
        "args" => %{"issue_id" => issue.id}
      })

    assert %{"result" => %{"total" => 1, "comments" => [comment]}} = json_response(conn, 200)
    assert comment["body"] == "Visible through MCP."
  end

  test "create_issue flood returns stable rate_limited error with 429", %{conn: conn} do
    AgentActionLimiter.reset()
    original = Application.get_env(:cympho, :agent_actions, [])
    Application.put_env(:cympho, :agent_actions, max_per_minute: 2)

    on_exit(fn ->
      Application.put_env(:cympho, :agent_actions, original)
      AgentActionLimiter.reset()
    end)

    for i <- 1..2 do
      c =
        post(conn, "/api/mcp/call", %{
          "tool" => "create_issue",
          "args" => %{"title" => "http create #{i}"}
        })

      assert %{"result" => %{"success" => true}} = json_response(c, 200)
    end

    limited =
      post(conn, "/api/mcp/call", %{
        "tool" => "create_issue",
        "args" => %{"title" => "http create blocked"}
      })

    body = json_response(limited, 429)
    assert body["error"] == "rate_limited"
    assert body["result"]["error"] == "rate_limited"
    assert body["result"]["success"] == false
  end

  test "static mutations require agent authority before rate limiting", %{company: company} do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "Restricted MCP Agent",
        role: :engineer,
        status: :idle,
        company_id: company.id
      })

    {:ok, {_key, token}} = Authentication.create_agent_api_key(agent.id, "Restricted MCP Key")

    denied =
      build_conn()
      |> put_req_header("x-api-key", token)
      |> post("/api/mcp/call", %{
        "tool" => "create_issue",
        "args" => %{"title" => "Not authorized"}
      })

    assert %{
             "result" => %{
               "error" => "Tool not authorized",
               "decision" => "deny",
               "static" => true,
               "success" => false
             }
           } = json_response(denied, 200)

    {:ok, _grant} =
      PrincipalPermissions.create_permission_grant(%{
        company_id: company.id,
        principal_id: agent.id,
        principal_type: "agent",
        permission: "task.create"
      })

    allowed =
      build_conn()
      |> put_req_header("x-api-key", token)
      |> post("/api/mcp/call", %{
        "tool" => "create_issue",
        "args" => %{"title" => "Explicitly authorized"}
      })

    assert %{"result" => %{"success" => true}} = json_response(allowed, 200)
  end

  test "lists and calls only granted dynamic tools", %{
    conn: conn,
    company: company,
    agent: agent
  } do
    alias Cympho.Mcp.{ToolGrants, ToolRegistry}

    {:ok, _tool} =
      ToolRegistry.register(company.id, %{
        "name" => "http_dynamic_echo",
        "description" => "HTTP dynamic tool"
      })

    # Not listed before grant
    names =
      conn
      |> get("/api/mcp/tools")
      |> json_response(200)
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])

    refute "http_dynamic_echo" in names

    deny_conn =
      post(conn, "/api/mcp/call", %{
        "tool" => "http_dynamic_echo",
        "args" => %{"x" => 1}
      })

    assert %{
             "result" => %{
               "error" => "Tool not authorized",
               "decision" => "deny"
             }
           } = json_response(deny_conn, 200)

    {:ok, grant} =
      ToolGrants.create_grant(%{
        company_id: company.id,
        tool_name: "http_dynamic_echo",
        agent_id: agent.id,
        status: "allow"
      })

    names =
      conn
      |> get("/api/mcp/tools")
      |> json_response(200)
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])

    assert "http_dynamic_echo" in names

    allow_conn =
      post(conn, "/api/mcp/call", %{
        "tool" => "http_dynamic_echo",
        "args" => %{"x" => 1}
      })

    assert %{
             "result" => %{
               "success" => false,
               "dynamic" => true,
               "tool" => "http_dynamic_echo",
               "error" => ":plugin_not_found"
             }
           } = json_response(allow_conn, 200)

    {:ok, _} = ToolGrants.revoke(grant.id, "immediate hide")

    names =
      conn
      |> get("/api/mcp/tools")
      |> json_response(200)
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])

    refute "http_dynamic_echo" in names

    revoked_conn =
      post(conn, "/api/mcp/call", %{
        "tool" => "http_dynamic_echo",
        "args" => %{}
      })

    assert %{
             "result" => %{
               "error" => "Tool not authorized",
               "decision" => "revoked"
             }
           } = json_response(revoked_conn, 200)
  end
end
