defmodule CymphoWeb.GoalLive.Edit do
  use CymphoWeb, :live_view
  alias Cympho.Goals

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Goals.get_goal(id) do
      {:ok, goal} ->
        changeset = Goals.change_goal(goal)
        {:ok, assign(socket, goal: goal, form: to_form(changeset))}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/goals")}
    end
  end

  @impl true
  def handle_event("save", %{"goal" => goal_params}, socket) do
    case Goals.update_goal(socket.assigns.goal, goal_params) do
      {:ok, goal} ->
        {:noreply, push_navigate(socket, to: ~p"/goals/#{goal.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
