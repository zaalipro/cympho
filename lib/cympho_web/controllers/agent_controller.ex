defmodule CymphoWeb.AgentController do
  use CymphoWeb, :controller

  alias Cympho.Agents

  action_fallback CymphoWeb.FallbackController

  def create(conn, %{"agent" => agent_params}) do
    company_id =
      cond do
        company = conn.assigns[:current_company] -> company.id
        agent = conn.assigns[:current_agent] -> agent.company_id
        true -> nil
      end

    attrs =
      if company_id, do: Map.put(agent_params, "company_id", company_id), else: agent_params

    case Agents.create_agent(attrs) do
      {:ok, agent} ->
        conn |> put_status(:created) |> json(%{data: serialize_agent(agent)})

      {:error, :pending_board_approval, approval_id} ->
        conn
        |> put_status(:accepted)
        |> json(%{data: %{status: "pending_board_approval", approval_id: approval_id}})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: translate_errors(changeset)})
    end
  end

  def inbox(conn, %{"id" => id}) do
    company_id = caller_company_id(conn)

    with {:ok, _agent} <- Agents.get_company_agent(company_id, id) do
      issues = Agents.list_agent_inbox(id)
      json(conn, %{data: issues})
    end
  end

  def update_status(conn, %{"id" => id, "status" => status}) do
    company_id = caller_company_id(conn)

    with :ok <- authorize_status_update(conn, id),
         {:ok, agent} <- Agents.get_company_agent(company_id, id) do
      case Agents.update_agent_status(agent, %{"status" => status}) do
        {:ok, updated} -> json(conn, %{data: CymphoWeb.AgentJSON.status_data(updated)})
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  def update_status(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: CymphoWeb.ErrorJSON)
    |> render(:error, message: "Missing required field: status")
  end

  def update_role(conn, %{"id" => id, "role" => new_role}) do
    company_id = caller_company_id(conn)

    with {:ok, agent} <- Agents.get_company_agent(company_id, id) do
      case Agents.update_agent(agent, %{role: new_role}) do
        {:ok, updated} -> json(conn, %{data: updated})
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  def health_status(conn, %{"id" => id}) do
    company_id = caller_company_id(conn)

    with {:ok, agent} <- Agents.get_company_agent(company_id, id) do
      json(conn, %{data: CymphoWeb.AgentJSON.health_status(agent)})
    end
  end

  def all_health_statuses(conn, _params) do
    company_id = caller_company_id(conn)
    agents = Cympho.Companies.list_company_agents(company_id)
    json(conn, %{data: CymphoWeb.AgentJSON.all_health_statuses(agents)})
  end

  defp authorize_status_update(conn, target_id) do
    caller = conn.assigns[:current_agent]

    cond do
      caller && caller.id == target_id -> :ok
      caller && caller.role in [:cto, :ceo] -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp caller_company_id(conn) do
    cond do
      company = conn.assigns[:current_company] -> company.id
      agent = conn.assigns[:current_agent] -> agent.company_id
      true -> nil
    end
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp serialize_agent(agent) do
    %{
      id: agent.id,
      name: agent.name,
      role: agent.role,
      status: agent.status,
      company_id: agent.company_id,
      inserted_at: agent.inserted_at,
      updated_at: agent.updated_at
    }
  end
end
