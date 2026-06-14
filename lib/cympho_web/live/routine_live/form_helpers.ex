defmodule CymphoWeb.RoutineLive.FormHelpers do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Cympho.{Agents, Projects}
  alias Cympho.Agents.Agent

  def assign_context_options(socket) do
    company_id = current_company_id(socket)

    socket
    |> assign(:agent_options, agent_options(company_id))
    |> assign(:project_options, project_options(company_id))
  end

  def scoped_routine_params(socket, params, opts \\ []) do
    company_id = current_company_id(socket)

    with :ok <- validate_agent_ref(company_id, params["agent_id"]),
         :ok <- validate_project_ref(company_id, params["project_id"]) do
      {:ok, maybe_put_company_scope(company_id, params, Keyword.get(opts, :put_company_scope))}
    end
  end

  defp maybe_put_company_scope(nil, params, _put_scope?), do: params
  defp maybe_put_company_scope(_company_id, params, false), do: params

  defp maybe_put_company_scope(company_id, params, _put_scope?),
    do: Map.put_new(params, "company_id", company_id)

  defp validate_agent_ref(_company_id, nil), do: :ok
  defp validate_agent_ref(_company_id, ""), do: :ok

  defp validate_agent_ref(company_id, agent_id) when is_binary(company_id) do
    case Agents.get_company_agent(company_id, agent_id) do
      {:ok, _agent} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  defp validate_agent_ref(_company_id, _agent_id), do: {:error, :not_found}

  defp validate_project_ref(_company_id, nil), do: :ok
  defp validate_project_ref(_company_id, ""), do: :ok

  defp validate_project_ref(company_id, project_id) when is_binary(company_id) do
    case Projects.get_company_project(company_id, project_id) do
      {:ok, _project} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  defp validate_project_ref(_company_id, _project_id), do: {:error, :not_found}

  defp agent_options(nil), do: [{"No default owner", ""}]

  defp agent_options(company_id) do
    options =
      company_id
      |> Agents.list_agents_by_company()
      |> Enum.reject(&(&1.governance_status == "terminated"))
      |> Enum.map(&{agent_option_label(&1), &1.id})

    [{"No default owner", ""} | options]
  end

  defp project_options(nil), do: [{"No project context", ""}]

  defp project_options(company_id) do
    options =
      company_id
      |> Projects.list_projects_by_company()
      |> Enum.reject(&(&1.status == :archived))
      |> Enum.map(&{&1.name, &1.id})

    [{"No project context", ""} | options]
  end

  defp agent_option_label(%{name: name, role: role}) do
    "#{name} · #{Agent.role_label(role)}"
  end

  defp current_company_id(%{assigns: %{current_company: %{id: id}}}), do: id
  defp current_company_id(_socket), do: nil
end
