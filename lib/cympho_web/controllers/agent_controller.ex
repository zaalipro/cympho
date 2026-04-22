defmodule CymphoWeb.AgentController do
  use CymphoWeb, :controller

  alias Cympho.Agents

  action_fallback CymphoWeb.FallbackController

  def inbox(conn, %{"id" => id}) do
    with {:ok, _agent} <- Agents.get_agent(id) do
      issues = Agents.list_agent_inbox(id)
      json(conn, %{data: issues})
    end
  end

  def update_status(conn, %{"id" => id, "status" => status}) do
    with {:ok, agent} <- Agents.get_agent(id) do
      attrs = %{"status" => status}

      case Agents.update_agent_status(agent, attrs) do
        {:ok, updated} ->
          json(conn, %{data: CymphoWeb.AgentJSON.status_data(updated)})

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def update_status(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: CymphoWeb.ErrorJSON)
    |> render(:"error", message: "Missing required field: status")
  end
end
