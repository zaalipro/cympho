defmodule CymphoWeb.RoutineLive.Show do
  use CymphoWeb, :live_view

  import CymphoWeb.RoutineLive.FormHelpers,
    only: [schedule_summary: 1, next_run: 1, routine_run_dot: 1]

  alias Cympho.Routines
  alias Cympho.RoutineTriggers

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case get_scoped_routine(socket, id) do
      {:ok, routine} ->
        {:ok, assign_routine(socket, routine)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    case get_scoped_routine(socket, id) do
      {:ok, routine} ->
        {:noreply,
         socket
         |> assign(:page_title, routine.name)
         |> assign_routine(routine)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Routine not found")
         |> push_navigate(to: ~p"/")}
    end
  end

  defp assign_routine(socket, routine) do
    socket
    |> assign(:routine, routine)
    |> assign(:runs, RoutineTriggers.list_runs(routine.id, limit: 50))
    |> assign(:triggers, RoutineTriggers.list_triggers(routine.id))
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

      {:skip, _policy} ->
        {:noreply, put_flash(socket, :info, "A run is already active — skipped")}

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
        {:noreply, push_navigate(socket, to: ~p"/routines")}

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

  def run_status_class("completed"),
    do: "border-emerald-500/20 bg-emerald-500/10 text-emerald-300"

  def run_status_class("running"), do: "border-amber-500/20 bg-amber-500/10 text-amber-300"
  def run_status_class("pending"), do: "border-amber-500/20 bg-amber-500/10 text-amber-300"
  def run_status_class("failed"), do: "border-rose-500/25 bg-rose-500/10 text-rose-300"
  def run_status_class(_), do: "border-border bg-panel text-text-tertiary"

  def format_datetime(nil), do: "-"
  def format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")

  @doc "Most recent run, or nil (runs arrive newest-first from list_runs/2)."
  def last_run([]), do: nil
  def last_run([run | _]), do: run
  def last_run(_), do: nil

  @doc "Only-loud-when-needed health signal for the routine header."
  def show_alert(routine, triggers, runs) do
    cond do
      routine.status == :active and no_enabled_trigger?(triggers) -> :trigger_gap
      match?(%{status: "failed"}, last_run(runs)) -> :failed
      true -> :ok
    end
  end

  defp no_enabled_trigger?(triggers), do: Enum.all?(triggers, &(&1.enabled == false))

  def show_alert_class(:failed), do: "border-rose-500/25 bg-rose-500/[0.05]"
  def show_alert_class(:trigger_gap), do: "border-amber-500/25 bg-amber-500/[0.05]"
  def show_alert_class(_), do: "border-border bg-surface"

  def show_alert_note(:failed), do: "The last run failed — inspect it before the next trigger."

  def show_alert_note(:trigger_gap),
    do: "This routine is active but has no enabled trigger, so it cannot run on its own yet."

  def show_alert_note(_), do: nil

  defp get_scoped_routine(socket, id) do
    case current_company_id(socket) do
      nil -> Routines.get_routine(id)
      company_id -> Routines.get_company_routine(company_id, id)
    end
  end

  defp current_company_id(%{assigns: %{current_company: %{id: id}}}), do: id
  defp current_company_id(_socket), do: nil
end
