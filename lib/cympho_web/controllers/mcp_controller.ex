defmodule CymphoWeb.McpController do
  use CymphoWeb, :controller

  alias Cympho.Mcp.Server

  def tools(conn, _params) do
    json(conn, %{tools: Server.tools()})
  end

  def call(conn, %{"tool" => tool_name, "args" => args}) do
    result = Server.call_tool(tool_name, args || %{})

    conn
    |> put_status(200)
    |> json(%{result: result})
  end

  def call(conn, %{"tool" => tool_name}) do
    call(conn, %{"tool" => tool_name, "args" => %{}})
  end

  def call(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "Missing 'tool' parameter"})
  end
end
