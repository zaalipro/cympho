defmodule CymphoWeb.RoutineLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Routines
  alias Cympho.Routines.Routine

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :routines, Routines.list_routines())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, nil, _params), do: apply_action(socket, :index, %{})

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Routines")
    |> assign(:routine, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Routine")
    |> assign(:routine, %Routine{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Routine")
    |> assign(:routine, Routines.get_routine!(id))
  end

  @impl true
  def handle_event("delete_routine", %{"id" => id}, socket) do
    routine = Routines.get_routine!(id)
    {:ok, _} = Routines.archive_routine(routine)
    {:noreply, assign(socket, :routines, Routines.list_routines())}
  end

  @impl true
  def handle_event("pause_routine", %{"id" => id}, socket) do
    routine = Routines.get_routine!(id)

    case Routines.pause_routine(routine) do
      {:ok, _} ->
        {:noreply, assign(socket, :routines, Routines.list_routines())}

      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Cannot pause a routine in #{routine.status} state")}
    end
  end

  @impl true
  def handle_event("resume_routine", %{"id" => id}, socket) do
    routine = Routines.get_routine!(id)

    case Routines.resume_routine(routine) do
      {:ok, _} ->
        {:noreply, assign(socket, :routines, Routines.list_routines())}

      {:error, :invalid_transition} ->
        {:noreply,
         put_flash(socket, :error, "Cannot resume a routine in #{routine.status} state")}
    end
  end
end
