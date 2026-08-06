defmodule CymphoWeb.McpController do
  use CymphoWeb, :controller

  alias Cympho.Mcp.Server

  def tools(conn, _params) do
    agent = conn.assigns.current_agent
    # Merge only dynamic tools the authenticated agent is granted to call.
    json(conn, %{tools: Server.tools_for(agent)})
  end

  def invoke(conn, %{"tool" => tool_name, "args" => args}) do
    agent = conn.assigns.current_agent
    result = Server.call_tool(tool_name, args || %{}, agent)
    respond_tool_result(conn, result)
  end

  def invoke(conn, %{"tool" => tool_name}) do
    invoke(conn, %{"tool" => tool_name, "args" => %{}})
  end

  def invoke(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing 'tool' parameter"})
  end

  # Stable HTTP contract for mutation throttle: 429 + body that always carries
  # `error: "rate_limited"` so clients can key off a single string.
  defp respond_tool_result(conn, %{error: "rate_limited"} = result) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{error: "rate_limited", result: result})
  end

  defp respond_tool_result(conn, result) do
    conn
    |> put_status(:ok)
    |> json(%{result: result})
  end
end
