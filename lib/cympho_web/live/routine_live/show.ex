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

  def routine_label(nil), do: "-"

  def routine_label(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def run_status_class("completed"), do: "border-success/20 bg-success/10 text-success"
  def run_status_class("running"), do: "border-brand/20 bg-brand/10 text-brand"
  def run_status_class("pending"), do: "border-amber-500/20 bg-amber-500/10 text-amber-400"
  def run_status_class("failed"), do: "border-red-500/20 bg-red-500/10 text-red-400"
  def run_status_class(_), do: "border-border bg-panel text-text-tertiary"

  def format_datetime(nil), do: "-"
  def format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
end
