defmodule CymphoWeb.GoalLive.FormHelpers do
  @moduledoc false

  use Phoenix.Component

  alias Cympho.{Goals, Projects}

  attr :text, :string, required: true

  @doc "Collapses a form section's help paragraph into a hoverable `?` marker."
  def field_hint(assigns) do
    ~H"""
    <span
      role="img"
      aria-label={@text}
      title={@text}
      class="inline-flex h-5 w-5 shrink-0 cursor-help items-center justify-center rounded-full border border-border text-[11px] font-590 text-text-quaternary"
    >
      ?
    </span>
    """
  end

  def assign_context_options(socket, opts \\ []) do
    company_id = current_company_id(socket)
    current_goal_id = Keyword.get(opts, :current_goal_id)

    socket
    |> assign(:goal_type_options, goal_type_options())
    |> assign(:project_options, project_options(company_id))
    |> assign(:parent_goal_options, parent_goal_options(company_id, current_goal_id))
  end

  def scoped_goal_params(socket, params, opts \\ []) do
    company_id = current_company_id(socket)
    current_goal_id = Keyword.get(opts, :current_goal_id)

    with {:ok, parent} <- validate_parent_ref(company_id, params["parent_id"], current_goal_id) do
      params = maybe_inherit_parent_project(params, parent)

      with :ok <- validate_project_ref(company_id, params["project_id"]) do
        {:ok, maybe_put_company_scope(company_id, params, Keyword.get(opts, :put_company_scope))}
      end
    end
  end

  defp goal_type_options do
    [
      {"Mission", "mission"},
      {"Initiative", "initiative"},
      {"Milestone", "milestone"}
    ]
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

  defp parent_goal_options(nil, _current_goal_id), do: [{"No parent goal", ""}]

  defp parent_goal_options(company_id, current_goal_id) do
    options =
      company_id
      |> Goals.list_goals_by_company()
      |> Enum.reject(&(&1.status != "active"))
      |> Enum.reject(&(current_goal_id && &1.id == current_goal_id))
      |> Enum.map(&{goal_option_label(&1), &1.id})

    [{"No parent goal", ""} | options]
  end

  defp validate_project_ref(_company_id, nil), do: :ok
  defp validate_project_ref(_company_id, ""), do: :ok

  defp validate_project_ref(company_id, project_id) when is_binary(company_id) do
    case Projects.get_company_project(company_id, project_id) do
      {:ok, _project} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  defp validate_project_ref(_company_id, _project_id), do: {:error, :not_found}

  defp validate_parent_ref(_company_id, nil, _current_goal_id), do: {:ok, nil}
  defp validate_parent_ref(_company_id, "", _current_goal_id), do: {:ok, nil}

  defp validate_parent_ref(_company_id, parent_id, current_goal_id)
       when is_binary(parent_id) and parent_id == current_goal_id do
    {:error, :not_found}
  end

  defp validate_parent_ref(company_id, parent_id, _current_goal_id) when is_binary(company_id) do
    Goals.get_company_goal(company_id, parent_id)
  end

  defp validate_parent_ref(_company_id, _parent_id, _current_goal_id), do: {:error, :not_found}

  defp maybe_inherit_parent_project(params, %{project_id: project_id})
       when is_binary(project_id) do
    if blank?(params["project_id"]) do
      Map.put(params, "project_id", project_id)
    else
      params
    end
  end

  defp maybe_inherit_parent_project(params, _parent), do: params

  defp maybe_put_company_scope(nil, params, _put_scope?), do: params
  defp maybe_put_company_scope(_company_id, params, false), do: params

  defp maybe_put_company_scope(company_id, params, _put_scope?),
    do: Map.put(params, "company_id", company_id)

  defp blank?(value), do: value in [nil, ""]

  defp goal_option_label(%{goal_type: type, title: title}) do
    "#{goal_type_label(type)} · #{title}"
  end

  defp goal_type_label(:mission), do: "Mission"
  defp goal_type_label(:initiative), do: "Initiative"
  defp goal_type_label(:milestone), do: "Milestone"
  defp goal_type_label(_type), do: "Goal"

  defp current_company_id(%{assigns: %{current_company: %{id: id}}}), do: id
  defp current_company_id(_socket), do: nil
end
