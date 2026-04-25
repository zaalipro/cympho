defmodule CymphoWeb.Plugs.AgentAuth do
  @moduledoc """
  Authentication plug for agent requests.

  Supports three authentication methods:
  1. JWT tokens (Authorization: Bearer <token>) - for heartbeat runs
  2. API keys (X-API-Key: <key>) - for agent API access
  3. X-Agent-ID header - legacy method for internal requests
  """

  import Plug.Conn
  import Ecto.Query, only: [from: 2]
  alias Cympho.Agents
  alias Cympho.AgentAuthJWT

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      # Try JWT authentication first
      has_jwt_header?(conn) ->
        authenticate_with_jwt(conn)

      # Try API key authentication
      has_api_key_header?(conn) ->
        authenticate_with_api_key(conn)

      # Fall back to legacy X-Agent-ID header
      true ->
        authenticate_with_agent_id(conn)
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
         {:ok, claims} <- AgentAuthJWT.verify_token(token),
         {:ok, agent_id} <- AgentAuthJWT.get_agent_id(claims),
         {:ok, run_id} <- AgentAuthJWT.get_run_id(claims),
         {:ok, agent} <- Agents.get_agent(agent_id) do
      conn
      |> assign(:current_agent, agent)
      |> assign(:run_id, run_id)
      |> assign(:auth_method, :jwt)
    else
      _ ->
        unauthorized(conn, "Invalid or expired JWT token")
    end
  end

  defp authenticate_with_api_key(conn) do
    with [api_key | _] <- get_req_header(conn, "x-api-key"),
         {:ok, agent_api_key} <- get_agent_api_key(api_key),
         {:ok, agent} <- Agents.get_agent(agent_api_key.agent_id) do
      # Update last_used_at timestamp asynchronously
      Task.start(fn -> update_last_used(agent_api_key) end)

      conn
      |> assign(:current_agent, agent)
      |> assign(:auth_method, :api_key)
      |> assign(:api_key_id, agent_api_key.id)
    else
      _ ->
        unauthorized(conn, "Invalid API key")
    end
  end

  defp authenticate_with_agent_id(conn) do
    case get_req_header(conn, "x-agent-id") do
      [id | _] when is_binary(id) and byte_size(id) > 0 ->
        case Agents.get_agent(id) do
          {:ok, agent} ->
            assign(conn, :current_agent, agent)
            |> assign(:auth_method, :agent_id)

          {:error, :not_found} ->
            unauthorized(conn, "Invalid agent identity")
        end

      _ ->
        unauthorized(conn, "Missing authentication credentials")
    end
  end

  defp get_agent_api_key(api_key) do
    key_hash = Cympho.Agents.AgentApiKey.hash_api_key(api_key)

    query =
      from(ak in Cympho.Agents.AgentApiKey,
        where: ak.key_hash == ^key_hash,
        where: is_nil(ak.expires_at) or ak.expires_at > ^DateTime.utc_now(),
        preload: [:agent]
      )

    case Cympho.Repo.one(query) do
      nil -> {:error, :not_found}
      api_key -> {:ok, api_key}
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
