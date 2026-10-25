defmodule CymphoWeb.GoalLive.FormHelpers do
  @moduledoc false

  use CymphoWeb, :html

  alias Cympho.{Goals, Projects}

  attr :form, :any, required: true
  attr :goal_type_options, :list, required: true
  attr :parent_goal_options, :list, required: true
  attr :project_options, :list, required: true
  attr :submit, :string, required: true, doc: "\"Create goal\" | \"Save goal\""
  attr :cancel, :string, required: true, doc: "where Cancel goes"

  @doc "The goal form shared by New and Edit (v7 L7/L9): two field cards and the ink card."
  def goal_form(assigns) do
    ~H"""
    <.form_pair id="goal-form" for={@form} phx-submit="save" heading="After you save" verb="save">
      <.band_card id="gf-goal-t" title="Goal">
        <div class="flds">
          <.input
            field={@form[:title]}
            label="Title"
            required
            placeholder="Ship Q3 launch"
            wrapper_class="full"
          />
          <.input
            field={@form[:description]}
            label="Success criteria"
            type="textarea"
            rows={5}
            placeholder="What must be true when it is done, and what proves it."
            wrapper_class="full"
          />
        </div>
      </.band_card>

      <.band_card id="gf-fit-t" title="Where it fits">
        <div class="flds">
          <.input
            type="select"
            field={@form[:goal_type]}
            label="Type"
            value={@form[:goal_type].value || :mission}
            options={@goal_type_options}
            help="Missions sit at the top; an initiative with no parent becomes a mission."
          />
          <.input
            type="select"
            field={@form[:parent_id]}
            label="Parent goal"
            value={@form[:parent_id].value || ""}
            options={@parent_goal_options}
          />
          <.input
            type="select"
            field={@form[:project_id]}
            label="Project"
            value={@form[:project_id].value || ""}
            options={@project_options}
            help="Left empty, a child goal uses its parent's project."
          />
          <.input
            type="select"
            field={@form[:status]}
            label="Status"
            value={@form[:status].value || "active"}
            options={[{"Active", "active"}, {"Completed", "completed"}, {"Cancelled", "cancelled"}]}
          />
          <.input
            type="select"
            field={@form[:priority]}
            label="Priority"
            value={@form[:priority].value || "medium"}
            options={[
              {"Critical", "critical"},
              {"High", "high"},
              {"Medium", "medium"},
              {"Low", "low"}
            ]}
          />
          <.input field={@form[:target_date]} type="date" label="Target date" />
        </div>
      </.band_card>

      <:effect>
        <.consequences rows={[{:done, "New tasks can be linked to it."}]} />
      </:effect>
      <:secondary>
        <.ghost_pill navigate={@cancel}>Cancel</.ghost_pill>
      </:secondary>
      <:primary>
        <.primary_pill type="submit" phx-disable-with="Saving…">{@submit}</.primary_pill>
      </:primary>
    </.form_pair>
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
