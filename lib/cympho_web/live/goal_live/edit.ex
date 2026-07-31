defmodule CymphoWeb.GoalLive.Edit do
  use CymphoWeb, :live_view
  alias Cympho.Goals
  alias CymphoWeb.GoalLive.FormHelpers

  import CymphoWeb.GoalLive.FormHelpers, only: [field_hint: 1]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case get_scoped_goal(socket, id) do
      {:ok, goal} ->
        changeset = Goals.change_goal(goal)

        socket =
          socket
          |> assign(goal: goal, form: to_form(changeset))
          |> FormHelpers.assign_context_options(current_goal_id: goal.id)

        {:ok, socket}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/goals")}
    end
  end

  @impl true
  def handle_event("save", %{"goal" => goal_params}, socket) do
    with {:ok, goal_params} <-
           FormHelpers.scoped_goal_params(socket, goal_params,
             current_goal_id: socket.assigns.goal.id
           ) do
      case Goals.update_goal(socket.assigns.goal, goal_params) do
        {:ok, goal} ->
          {:noreply, push_navigate(socket, to: ~p"/goals/#{goal.id}")}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    else
      {:error, :not_found} ->
        {:noreply,
         put_flash(socket, :error, "Choose a project and parent goal from this company.")}
    end
  end

  defp get_scoped_goal(socket, id) do
    with {:ok, goal} <- Goals.get_goal(id),
         :ok <- authorize_goal(socket, goal) do
      {:ok, goal}
    end
  end

  defp authorize_goal(socket, goal) do
    case socket.assigns[:current_company] do
      %{id: company_id} when goal.company_id == company_id -> :ok
      nil -> :ok
      _ -> {:error, :not_found}
    end
  end
end
