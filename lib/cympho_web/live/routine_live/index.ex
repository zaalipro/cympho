defmodule CymphoWeb.RoutineLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Repo
  alias Cympho.Routines
  alias Cympho.Routines.Routine

  @stale_run_after_seconds 2 * 60 * 60
  @recent_failure_window_seconds 24 * 60 * 60

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:infinite_scroll, %{})
      |> assign_routine_overview()

    {:ok, init_stream(socket, :routine, &fetch_routines(socket, &1))}
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
  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :routine, &fetch_routines(socket, &1))}
  end

  @impl true
  def handle_event("delete_routine", %{"id" => id}, socket) do
    case get_scoped_routine(socket, id) do
      {:ok, routine} ->
        {:ok, _} = Routines.archive_routine(routine)
        {:noreply, refresh_routines(socket)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Routine not found")}
    end
  end

  @impl true
  def handle_event("pause_routine", %{"id" => id}, socket) do
    case get_scoped_routine(socket, id) do
      {:ok, routine} ->
        case Routines.pause_routine(routine) do
          {:ok, _} ->
            {:noreply, refresh_routines(socket)}

          {:error, :invalid_transition} ->
            {:noreply,
             put_flash(socket, :error, "Cannot pause a routine in #{routine.status} state")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Routine not found")}
    end
  end

  @impl true
  def handle_event("resume_routine", %{"id" => id}, socket) do
    case get_scoped_routine(socket, id) do
      {:ok, routine} ->
        case Routines.resume_routine(routine) do
          {:ok, _} ->
            {:noreply, refresh_routines(socket)}

          {:error, :invalid_transition} ->
            {:noreply,
             put_flash(socket, :error, "Cannot resume a routine in #{routine.status} state")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Routine not found")}
    end
  end

  defp fetch_routines(socket, cursor) do
    Routines.list_routines_page(company_id: current_company_id(socket), after: cursor)
  end

  defp refresh_routines(socket) do
    socket
    |> assign_routine_overview()
    |> reset_stream(:routine, &fetch_routines(socket, &1))
  end

  defp assign_routine_overview(socket) do
    company_id = current_company_id(socket)
    health = Routines.health_summary(company_id)
    command_routines = command_routines(company_id)

    socket
    |> assign(:routine_health, health)
    |> assign(:routine_command, build_routine_command(health, command_routines))
  end

  defp command_routines(company_id) do
    Routines.list_routines(company_id: company_id)
    |> Repo.preload([:triggers, :runs])
  end

  defp get_scoped_routine(socket, id) do
    case current_company_id(socket) do
      nil -> Routines.get_routine(id)
      company_id -> Routines.get_company_routine(company_id, id)
    end
  end

  defp current_company_id(%{assigns: %{current_company: %{id: id}}}), do: id
  defp current_company_id(_socket), do: nil

  defp build_routine_command(%{metrics: metrics}, routines) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stale_before = DateTime.add(now, -@stale_run_after_seconds, :second)
    recent_failure_after = DateTime.add(now, -@recent_failure_window_seconds, :second)
    active_routines = Enum.filter(routines, &(&1.status == :active))

    triggerless = Enum.find(active_routines, &without_enabled_trigger?/1)
    stale = Enum.find(routines, &has_stale_run?(&1, stale_before))
    failed = Enum.find(routines, &has_recent_failure?(&1, recent_failure_after))
    paused = Enum.find(routines, &(&1.status == :paused))
    runnable = Enum.find(active_routines, &(not without_enabled_trigger?(&1)))

    command =
      cond do
        metrics.total_routines == 0 ->
          %{
            tone: :empty,
            badge: "Not configured",
            heading: "Create the first routine",
            detail:
              "Start a recurring operational loop that creates work automatically instead of waiting for manual intake.",
            action_label: "New routine",
            action_path: "/routines/new",
            focus_label: nil,
            focus_detail: nil
          }

        triggerless ->
          %{
            tone: :critical,
            badge: "Trigger gap",
            heading: "Add trigger to routine",
            detail:
              "#{triggerless.name} is active, but no enabled schedule or webhook trigger can fire it.",
            action_label: "Open routine",
            action_path: "/routines/#{triggerless.id}",
            focus_label: triggerless.name,
            focus_detail: "Active without enabled trigger"
          }

        stale ->
          %{
            tone: :critical,
            badge: "Stuck run",
            heading: "Clear stale routine execution",
            detail: "#{stale.name} has a pending or running execution older than two hours.",
            action_label: "Open run history",
            action_path: "/routines/#{stale.id}",
            focus_label: stale.name,
            focus_detail: latest_run_label(stale)
          }

        failed ->
          %{
            tone: :warning,
            badge: "Recent failure",
            heading: "Review failed routine",
            detail:
              "#{failed.name} failed recently. Inspect the generated issue or repair the routine before it repeats.",
            action_label: "Open failed routine",
            action_path: "/routines/#{failed.id}",
            focus_label: failed.name,
            focus_detail: latest_run_label(failed)
          }

        paused ->
          %{
            tone: :paused,
            badge: "Paused work",
            heading: "Audit paused routine",
            detail:
              "#{paused.name} is paused and will not create work until an owner resumes or archives it.",
            action_label: "Open paused routine",
            action_path: "/routines/#{paused.id}",
            focus_label: paused.name,
            focus_detail: "Paused recurring work"
          }

        runnable ->
          %{
            tone: :healthy,
            badge: "Ready",
            heading: "Routine loop is operational",
            detail:
              "#{metrics.active_routines} active routine#{plural_suffix(metrics.active_routines)} can create recurring work. Review run history before adding more automation.",
            action_label: "Open routine",
            action_path: "/routines/#{runnable.id}",
            focus_label: runnable.name,
            focus_detail: latest_run_label(runnable)
          }

        true ->
          %{
            tone: :empty,
            badge: "No active loop",
            heading: "Create or resume recurring work",
            detail:
              "Routine records exist, but no active routine can currently create autonomous work.",
            action_label: "New routine",
            action_path: "/routines/new",
            focus_label: nil,
            focus_detail: nil
          }
      end

    command
    |> Map.put(:active_count, metrics.active_routines)
    |> Map.put(:trigger_gap_count, metrics.active_without_triggers)
    |> Map.put(:stale_count, metrics.stale_runs)
    |> Map.put(:failure_count, metrics.recent_failures)
    |> Map.put(:paused_count, metrics.paused_routines)
  end

  defp without_enabled_trigger?(routine) do
    Enum.empty?(routine.triggers) or Enum.all?(routine.triggers, &(&1.enabled == false))
  end

  defp has_stale_run?(routine, stale_before) do
    Enum.any?(routine.runs, fn run ->
      run.status in ["pending", "running"] and before?(run.triggered_at, stale_before)
    end)
  end

  defp has_recent_failure?(routine, recent_failure_after) do
    Enum.any?(routine.runs, fn run ->
      run.status == "failed" and
        after_or_equal?(run.completed_at || run.triggered_at, recent_failure_after)
    end)
  end

  defp latest_run_label(%{runs: []}), do: "No runs yet"

  defp latest_run_label(%{runs: runs}) do
    runs
    |> Enum.max_by(&(&1.triggered_at || ~U[1970-01-01 00:00:00Z]), DateTime)
    |> then(fn run ->
      "#{routine_label(run.status)} · #{routine_label(run.trigger_type)}"
    end)
  end

  defp before?(nil, _datetime), do: false
  defp before?(datetime, cutoff), do: DateTime.compare(datetime, cutoff) == :lt
  defp after_or_equal?(nil, _datetime), do: false
  defp after_or_equal?(datetime, cutoff), do: DateTime.compare(datetime, cutoff) in [:gt, :eq]

  def routine_label(nil), do: "Unknown"

  def routine_label(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def routine_status_class(:active), do: "border-success/20 bg-success/10 text-success"
  def routine_status_class(:paused), do: "border-amber-500/20 bg-amber-500/10 text-amber-400"

  def routine_status_class(:archived),
    do: "border-text-quaternary/20 bg-text-quaternary/10 text-text-tertiary"

  def routine_status_class(_), do: "border-border bg-surface text-text-tertiary"

  def routine_priority_class(:critical), do: "border-brand/25 bg-brand/10 text-brand"
  def routine_priority_class(:high), do: "border-amber-500/25 bg-amber-500/10 text-amber-400"
  def routine_priority_class(:medium), do: "border-brand/25 bg-brand/10 text-brand"

  def routine_priority_class(:low),
    do: "border-text-quaternary/20 bg-text-quaternary/10 text-text-tertiary"

  def routine_priority_class(_), do: "border-border bg-surface text-text-tertiary"

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :atom, default: :neutral

  def routine_health_metric(assigns) do
    ~H"""
    <div class="bg-surface/70 px-3 py-2 text-center">
      <p class={"font-mono text-[18px] font-590 leading-none #{routine_metric_text(@tone)}"}>
        {@value}
      </p>
      <p class="mt-1 text-[10px] uppercase tracking-[0.12em] text-text-quaternary">
        {@label}
      </p>
    </div>
    """
  end

  def routine_health_badge(:critical), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def routine_health_badge(:warning), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  def routine_health_badge(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  def routine_health_badge(:empty), do: "border-border bg-surface text-text-tertiary"
  def routine_health_badge(_), do: "border-border bg-surface text-text-tertiary"

  def routine_posture_label(:empty), do: "Setup posture"
  def routine_posture_label(_level), do: "Automation posture"

  def routine_posture_text(:empty) do
    "No recurring automation is configured. Create one routine, attach a trigger, then watch run history here."
  end

  def routine_posture_text(_level) do
    "Triggers, run freshness, recent failures, and paused recurring work are quiet."
  end

  def routine_metric_text(:critical), do: "text-red-300"
  def routine_metric_text(:warning), do: "text-amber-300"
  def routine_metric_text(:ok), do: "text-emerald-300"
  def routine_metric_text(_), do: "text-text-primary"

  defp plural_suffix(1), do: ""
  defp plural_suffix(_), do: "s"

  def routine_command_badge(:critical), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def routine_command_badge(:warning), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def routine_command_badge(:paused), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"

  def routine_command_badge(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  def routine_command_badge(_), do: "border-border bg-surface text-text-tertiary"

  def routine_command_action(:critical),
    do: "border-red-500/25 bg-red-500/10 text-red-300 hover:bg-red-500/15"

  def routine_command_action(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300 hover:bg-amber-500/15"

  def routine_command_action(:paused),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-300 hover:bg-blue-500/15"

  def routine_command_action(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300 hover:bg-emerald-500/15"

  def routine_command_action(_),
    do:
      "border-border bg-surface text-text-secondary hover:bg-surface-hover hover:text-text-primary"

  def routine_recommendation_class(:critical), do: "border-red-500/20 bg-red-500/10 text-red-100"

  def routine_recommendation_class(:warning),
    do: "border-amber-500/20 bg-amber-500/10 text-amber-100"

  def routine_recommendation_class(_), do: "border-border bg-surface text-text-secondary"

  def routine_next_action_class(:critical), do: "border-red-500/25 bg-red-500/10 text-red-100"

  def routine_next_action_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-100"

  def routine_next_action_class(:ok),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-100"

  def routine_next_action_class(_), do: "border-border bg-surface text-text-secondary"

  def routine_next_action_path(%{key: :create_first_routine}), do: "/routines/new"
  def routine_next_action_path(_action), do: "/routines"
end
