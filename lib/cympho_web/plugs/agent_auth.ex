defmodule CymphoWeb.Plugs.AgentAuth do
  @moduledoc """
  Authenticates API callers as agents via the X-Agent-ID header.

  Sets conn.assigns[:current_agent] on success. Returns 401 if the header
  is missing or the agent does not exist.
  """
  import Plug.Conn

  alias Cympho.Agents

  @header "x-agent-id"

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, @header) do
      [id | _] when is_binary(id) and byte_size(id) > 0 ->
        case Agents.get_agent(id) do
          {:ok, agent} ->
            assign(conn, :current_agent, agent)

          {:error, :not_found} ->
            conn
            |> put_status(:unauthorized)
            |> Phoenix.Controller.json(%{errors: [%{detail: "Invalid agent identity"}]})
            |> halt()
        end

      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{errors: [%{detail: "Missing X-Agent-ID header"}]})
        |> halt()
    end
  end
end
