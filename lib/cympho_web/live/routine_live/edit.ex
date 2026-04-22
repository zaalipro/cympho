defmodule CymphoWeb.RoutineLive.Edit do
  use CymphoWeb, :live_view
  alias Cympho.Routines

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Routines.get_routine(id) do
      {:ok, routine} ->
        changeset = Routines.change_routine(routine)
        {:ok, assign(socket, routine: routine, changeset: changeset, page_title: "Edit Routine")}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/routines")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"routine" => routine_params}, socket) do
    case Routines.update_routine(socket.assigns.routine, routine_params) do
      {:ok, routine} ->
        {:noreply, push_navigate(socket, to: ~p"/routines/#{routine.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end
end
