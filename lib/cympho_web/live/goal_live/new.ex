defmodule CymphoWeb.GoalLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Goals
  alias Cympho.Goals.Goal
  alias CymphoWeb.GoalLive.FormHelpers

  @impl true
  def mount(_params, _session, socket) do
    changeset = Goals.change_goal(%Goal{})

    socket =
      socket
      |> assign(form: to_form(changeset))
      |> FormHelpers.assign_context_options()

    {:ok, socket}
  end

  @impl true
  def handle_event("save", %{"goal" => goal_params}, socket) do
    with {:ok, goal_params} <-
           FormHelpers.scoped_goal_params(socket, goal_params, put_company_scope: true) do
      case Goals.create_goal(goal_params) do
        {:ok, _goal} ->
          {:noreply, push_navigate(socket, to: ~p"/goals")}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    else
      {:error, :not_found} ->
        {:noreply,
         put_flash(socket, :error, "Choose a project and parent goal from this company.")}
    end
  end
end
