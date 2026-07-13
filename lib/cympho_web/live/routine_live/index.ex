defmodule CymphoWeb.RoutineLive.Index do
  use CymphoWeb, :live_view
  import CymphoWeb.RoutineLive.FormHelpers, only: [schedule_summary: 1, next_run: 1, raw_cron: 1]
  alias Cympho.Repo
  alias Cympho.Routines
  alias Cympho.Routines.Routine

  @stale_run_after_seconds 2 * 60 * 60
  @recent_failure_window_seconds 24 * 60 * 60

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:digest_density, "compact")
      |> assign(:infinite_scroll, %{})
      |> assign_routine_overview()

    {:ok, init_stream(socket, :routine, &fetch_routines(socket, &1))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, nil, params), do: apply_action(socket, :index, params)

  defp apply_action(socket, :index, params) do
    socket
    |> assign(:page_title, "Routines")
    |> assign(:routine, nil)
    |> assign(:digest_density, normalize_digest_density(params["density"]))
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
    page = Routines.list_routines_page(company_id: current_company_id(socket), after: cursor)
    %{page | entries: Repo.preload(page.entries, [:triggers, :runs])}
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

  defp routine_index_url("detailed"), do: ~p"/routines?#{%{density: "detailed"}}"
  defp routine_index_url(_density), do: ~p"/routines"

  defp normalize_digest_density("compact"), do: "compact"
  defp normalize_digest_density("detailed"), do: "detailed"
  defp normalize_digest_density(_), do: "compact"

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

  # ── Smart routine card ─────────────────────────────────────────────────────
  # Each card answers "is it healthy and when does it run next?". Only a routine
  # that needs a person right now (failed / stuck / missing trigger) is loud.

  attr :id, :string, required: true
  attr :routine, :map, required: true
  attr :density, :string, required: true

  def routine_card(assigns) do
    routine = assigns.routine
    signal = routine_card_signal(routine)

    assigns =
      assigns
      |> assign(:signal, signal)
      |> assign(:pill, routine_signal_pill(signal))
      |> assign(:outcome, routine_last_outcome(routine))
      |> assign(:next, next_run(routine.triggers))
      |> assign(:schedule, schedule_summary(routine.triggers))
      |> assign(:cron, raw_cron(routine.triggers))

    ~H"""
    <article
      id={@id}
      class={[
        "group card-lift rounded-xl border transition-colors",
        routine_signal_card_class(@signal),
        if(@density == "compact", do: "p-3", else: "p-4")
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <div class="flex min-w-0 items-center gap-2">
            <span
              class={["h-2 w-2 shrink-0 rounded-full", routine_status_dot(@routine.status)]}
              title={"Status: #{routine_label(@routine.status)}"}
            >
            </span>
            <.app_link
              navigate={~p"/routines/#{@routine.id}"}
              class="truncate text-sm font-590 text-text-primary hover:text-brand"
            >
              {@routine.name}
            </.app_link>
            <span
              :if={@pill}
              class={["shrink-0 rounded-full border px-2 py-0.5 text-[11px] font-590", elem(@pill, 1)]}
            >
              {elem(@pill, 0)}
            </span>
          </div>

          <div class="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-text-tertiary">
            <span class="inline-flex items-center gap-1.5" title={@cron && "cron: #{@cron}"}>
              <.icon name="hero-clock-mini" class="h-3.5 w-3.5 text-text-quaternary" />
              {@schedule}
            </span>
            <span :if={@next} class="text-text-quaternary">Next run {@next}</span>
            <span :if={@outcome} class="inline-flex items-center gap-1.5">
              <span class={["h-1.5 w-1.5 rounded-full", @outcome.dot]}></span> Last {@outcome.label}
            </span>
            <span class="uppercase tracking-[0.1em] text-[10px] text-text-quaternary">
              {routine_label(@routine.status)}
            </span>
          </div>

          <p
            :if={@density == "detailed"}
            class="mt-2 max-w-3xl text-sm leading-5 text-text-tertiary"
          >
            {@routine.description || "No description provided."}
          </p>
          <div
            :if={@density == "detailed"}
            class="ui-advanced-only mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-[11px] text-text-quaternary"
          >
            <span>{routine_label(@routine.priority)} priority</span>
            <span>{routine_label(@routine.concurrency_policy)}</span>
            <span>Catch-up: {routine_label(@routine.catch_up_policy)}</span>
            <span>Cap {@routine.catch_up_cap}</span>
          </div>
        </div>

        <div class="flex shrink-0 items-center gap-1.5">
          <.app_link
            navigate={~p"/routines/#{@routine.id}"}
            class="inline-flex min-h-[32px] items-center rounded-lg border border-brand/25 bg-brand/10 px-3 py-1.5 text-xs font-590 text-brand transition-colors hover:bg-brand/15"
          >
            Open
          </.app_link>
          <div class="flex items-center gap-1 opacity-70 transition-opacity group-hover:opacity-100 focus-within:opacity-100">
            <.app_link
              navigate={~p"/routines/#{@routine.id}/edit"}
              class="rounded-lg border border-border bg-button px-2.5 py-1.5 text-xs font-510 text-text-tertiary transition-colors hover:bg-button-hover hover:text-text-primary"
            >
              Edit
            </.app_link>
            <button
              :if={@routine.status == :active}
              type="button"
              class="rounded-lg border border-border bg-button px-2.5 py-1.5 text-xs font-510 text-text-tertiary transition-colors hover:bg-button-hover hover:text-text-primary"
              phx-click="pause_routine"
              phx-value-id={@routine.id}
              data-confirm="Pause this routine? It stops creating work until resumed."
            >
              Pause
            </button>
            <button
              :if={@routine.status == :paused}
              type="button"
              class="rounded-lg border border-success/20 bg-success/10 px-2.5 py-1.5 text-xs font-510 text-success transition-colors hover:bg-success/15"
              phx-click="resume_routine"
              phx-value-id={@routine.id}
              data-confirm="Resume this routine? It will create work on its next trigger."
            >
              Resume
            </button>
            <button
              :if={@routine.status != :archived}
              type="button"
              class="rounded-lg border border-border bg-button px-2.5 py-1.5 text-xs font-510 text-text-tertiary transition-colors hover:bg-button-hover hover:text-rose-300"
              phx-click="delete_routine"
              phx-value-id={@routine.id}
              data-confirm="Archive this routine? It stops running and moves out of the active list."
            >
              Archive
            </button>
          </div>
        </div>
      </div>
    </article>
    """
  end

  # Highest-urgency signal wins; only failed/stale/trigger_gap are "act now".
  def routine_card_signal(routine) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stale_before = DateTime.add(now, -@stale_run_after_seconds, :second)
    recent_failure_after = DateTime.add(now, -@recent_failure_window_seconds, :second)

    cond do
      routine.status == :archived -> :archived
      has_recent_failure?(routine, recent_failure_after) -> :failed
      has_stale_run?(routine, stale_before) -> :stale
      routine.status == :active and without_enabled_trigger?(routine) -> :trigger_gap
      routine.status == :paused -> :paused
      true -> :ok
    end
  end

  def routine_signal_card_class(:failed),
    do: "border-rose-500/35 bg-rose-500/[0.05] hover:border-rose-500/50"

  def routine_signal_card_class(:stale),
    do: "border-rose-500/30 bg-rose-500/[0.04] hover:border-rose-500/45"

  def routine_signal_card_class(:trigger_gap),
    do: "border-amber-500/30 bg-amber-500/[0.04] hover:border-amber-500/45"

  def routine_signal_card_class(_),
    do: "border-border bg-surface hover:border-border-hover hover:bg-surface-hover"

  def routine_signal_pill(:failed),
    do: {"Failed recently", "border-rose-500/30 bg-rose-500/10 text-rose-300"}

  def routine_signal_pill(:stale),
    do: {"Run stuck", "border-rose-500/30 bg-rose-500/10 text-rose-300"}

  def routine_signal_pill(:trigger_gap),
    do: {"Needs a trigger", "border-amber-500/30 bg-amber-500/10 text-amber-300"}

  def routine_signal_pill(_), do: nil

  def routine_status_dot(:active), do: "bg-emerald-400/70"
  def routine_status_dot(:paused), do: "bg-amber-400/70"
  def routine_status_dot(_), do: "bg-text-quaternary/40"

  def routine_last_outcome(%{runs: []}), do: nil

  def routine_last_outcome(%{runs: runs}) when is_list(runs) do
    run = Enum.max_by(runs, &(&1.triggered_at || ~U[1970-01-01 00:00:00Z]), DateTime)

    %{
      dot: CymphoWeb.RoutineLive.FormHelpers.routine_run_dot(run.status),
      label: routine_label(run.status)
    }
  end

  def routine_last_outcome(_), do: nil

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
