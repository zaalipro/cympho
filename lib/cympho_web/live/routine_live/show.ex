defmodule CymphoWeb.RoutineLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Routines
  alias Cympho.RoutineTriggers

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Routines.get_routine(id) do
      {:ok, routine} ->
        runs = RoutineTriggers.list_runs(routine.id, limit: 50)
        {:ok, assign(socket, routine: routine, runs: runs)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    case Routines.get_routine(id) do
      {:ok, routine} ->
        runs = RoutineTriggers.list_runs(routine.id, limit: 50)

        {:noreply,
         socket
         |> assign(:page_title, routine.name)
         |> assign(:routine, routine)
         |> assign(:runs, runs)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Routine not found")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("manual_run", _, socket) do
    routine = socket.assigns.routine

    case RoutineTriggers.manual_run(routine) do
      {:ok, %{run: _run}} ->
        runs = RoutineTriggers.list_runs(routine.id, limit: 50)

        {:noreply,
         socket
         |> assign(:runs, runs)
         |> put_flash(:info, "Run started")}

      {:error, :routine_paused} ->
        {:noreply, put_flash(socket, :error, "Cannot run a paused routine")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start run")}
    end
  end

  def handle_event("pause_routine", _params, socket) do
    case Routines.pause_routine(socket.assigns.routine) do
      {:ok, routine} ->
        {:noreply, assign(socket, :routine, routine)}

      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Cannot pause this routine")}
    end
  end

  def handle_event("resume_routine", _params, socket) do
    case Routines.resume_routine(socket.assigns.routine) do
      {:ok, routine} ->
        {:noreply, assign(socket, :routine, routine)}

      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Cannot resume this routine")}
    end
  end

  def handle_event("archive_routine", _params, socket) do
    case Routines.archive_routine(socket.assigns.routine) do
      {:ok, _routine} ->
        {:noreply, push_navigate(socket, to: ~p"/")}

      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Cannot archive this routine")}
    end
  end
end
