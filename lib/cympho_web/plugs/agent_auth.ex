defmodule CymphoWeb.Plugs.AgentAuth do
  @moduledoc """
  Authentication plug for agent requests.

  Supports two authentication methods:
  1. JWT tokens (Authorization: Bearer <token>) — for heartbeat runs
  2. API keys (X-API-Key: <key>) — for agent API access
  """

  import Plug.Conn
  import Ecto.Query, only: [from: 2]
  alias Cympho.Authentication

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      has_jwt_header?(conn) ->
        authenticate_with_jwt(conn)

      has_api_key_header?(conn) ->
        authenticate_with_api_key(conn)

      true ->
        unauthorized(conn, "Missing authentication credentials")
    end
  end

  defp has_jwt_header?(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> _token] -> true
      _ -> false
    end
  end

  defp has_api_key_header?(conn) do
    case get_req_header(conn, "x-api-key") do
      [key | _] when is_binary(key) and byte_size(key) > 0 -> true
      _ -> false
    end
  end

  defp authenticate_with_jwt(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, %{agent: agent, run: run}} <- Authentication.authenticate_heartbeat_token(token) do
      conn
      |> assign(:current_agent, agent)
      |> assign(:run_id, run.id)
      |> assign(:auth_method, :jwt)
    else
      _ ->
        unauthorized(conn, "Invalid or expired JWT token")
    end
  end

  defp authenticate_with_api_key(conn) do
    with [api_key | _] <- get_req_header(conn, "x-api-key"),
         {:ok, {agent_api_key, agent}} <- Authentication.authenticate_agent_api_key(api_key) do
      # Fire-and-forget update; skip in test to avoid sandbox disconnect noise
      unless Application.get_env(:cympho, :env) == :test do
        Task.Supervisor.start_child(
          Cympho.TaskSupervisor,
          fn -> update_last_used(agent_api_key) end,
          restart: :temporary
        )
      end

      conn
      |> assign(:current_agent, agent)
      |> assign(:auth_method, :api_key)
      |> assign(:api_key_id, agent_api_key.id)
    else
      _ ->
        unauthorized(conn, "Invalid API key")
    end
  end

  defp update_last_used(api_key) do
    Cympho.Repo.update_all(
      from(ak in Cympho.Agents.AgentApiKey, where: ak.id == ^api_key.id),
      set: [last_used_at: DateTime.utc_now()]
    )
  end

  defp unauthorized(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{errors: [%{detail: message}]})
    |> halt()
  end
end
