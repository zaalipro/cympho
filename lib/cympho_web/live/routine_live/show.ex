defmodule CymphoWeb.RoutineLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Routines

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Routines.get_routine(id) do
      {:ok, routine} ->
        {:ok, assign(socket, routine: routine)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/routines")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, id)}
  end

  defp apply_action(socket, :show, id) do
    case Routines.get_routine(id) do
      {:ok, routine} ->
        socket
        |> assign(:page_title, routine.name)
        |> assign(:routine, routine)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Routine not found")
        |> push_navigate(to: ~p"/routines")
    end
  end

  @impl true
  def handle_event("pause_routine", _params, socket) do
    case Routines.pause_routine(socket.assigns.routine) do
      {:ok, routine} ->
        {:noreply, assign(socket, :routine, routine)}

      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Cannot pause a routine in #{socket.assigns.routine.status} state")}
    end
  end

  def handle_event("resume_routine", _params, socket) do
    case Routines.resume_routine(socket.assigns.routine) do
      {:ok, routine} ->
        {:noreply, assign(socket, :routine, routine)}

      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Cannot resume a routine in #{socket.assigns.routine.status} state")}
    end
  end

  def handle_event("archive_routine", _params, socket) do
    case Routines.archive_routine(socket.assigns.routine) do
      {:ok, _routine} ->
        {:noreply, push_navigate(socket, to: ~p"/routines")}

      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Cannot archive a routine in #{socket.assigns.routine.status} state")}
    end
  end
end
