defmodule CymphoWeb.RoutineLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Routines
  alias Cympho.Routines.Routine

  @impl true
  def mount(_params, _session, socket) do
    changeset = Routines.change_routine(%Routine{})

    socket =
      assign(socket, changeset: changeset, form: to_form(changeset), page_title: "New Routine")

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"routine" => routine_params}, socket) do
    case Routines.create_routine(routine_params) do
      {:ok, routine} ->
        {:noreply, push_navigate(socket, to: ~p"/routines/#{routine.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
    end
  end
end
