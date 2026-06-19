defmodule CymphoWeb.McpControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.{Agents, Authentication, Comments, Companies, Issues}

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
end
