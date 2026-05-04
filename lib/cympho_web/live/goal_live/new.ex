defmodule CymphoWeb.GoalLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Goals
  alias Cympho.Goals.Goal
  alias Cympho.Projects

  @impl true
  def mount(_params, _session, socket) do
    changeset = Goals.change_goal(%Goal{})
    {:ok, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"goal" => goal_params}, socket) do
    case Goals.create_goal(Map.merge(goal_params, goal_scope(socket))) do
      {:ok, _goal} ->
        {:noreply, push_navigate(socket, to: ~p"/goals")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp goal_scope(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} ->
        project_id =
          company_id
          |> Projects.list_projects_by_company()
          |> List.first()
          |> case do
            nil -> nil
            project -> project.id
          end

        %{"company_id" => company_id, "project_id" => project_id}

      _ ->
        %{}
    end
  end
end
