defmodule CymphoWeb.GoalLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Goals
  alias Cympho.Goals.Goal

  @impl true
  def mount(_params, _session, socket) do
    changeset = Goals.change_goal(%Goal{})
    {:ok, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"goal" => goal_params}, socket) do
    case Goals.create_goal(goal_params) do
      {:ok, _goal} ->
        {:noreply, push_navigate(socket, to: ~p"/goals")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
