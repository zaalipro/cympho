defmodule CymphoWeb.RoutineLive.Index do
  use CymphoWeb, :live_view
  import CymphoWeb.RoutineLive.FormHelpers, only: [schedule_summary: 1, next_run: 1, raw_cron: 1]
  alias Cympho.Agents
  alias Cympho.Routines
  alias Cympho.Routines.Routine

  @impl true
  def mount(_params, _session, socket) do
    if is_binary(current_company_id(socket)) do
      socket =
        socket
        |> assign(:digest_density, "compact")
        |> assign(:infinite_scroll, %{})
        |> assign_routine_overview()

      {:ok, init_stream(socket, :routine, &fetch_routines(socket, &1))}
    else
      {:ok, redirect(socket, to: ~p"/onboarding")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, nil, params), do: apply_action(socket, :index, params)

  defp apply_action(socket, :index, params) do
    socket
    |> assign(:page_title, "Repeating tasks")
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
    Routines.list_routines_overview_page(company_id: current_company_id(socket), after: cursor)
  end

  defp refresh_routines(socket) do
    socket
    |> assign_routine_overview()
    |> reset_stream(:routine, &fetch_routines(socket, &1))
  end

  defp assign_routine_overview(socket) do
    company_id = current_company_id(socket)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    health = Routines.health_summary(company_id, now: now)
    command_routines = Routines.routine_command_candidates(company_id, now: now)
    health = put_next_action_routine_id(health, command_routines)

    socket
    |> assign(:routine_health, health)
    |> assign(:routine_command, build_routine_command(health, command_routines))
    |> assign(:agent_names, agent_names(company_id))
  end

  # The row's meta line names each repeating task's default owner.
  defp agent_names(nil), do: %{}

  defp agent_names(company_id) do
    company_id
    |> Agents.list_agents_by_company()
    |> Map.new(&{&1.id, &1.name})
  end

  defp put_next_action_routine_id(
         %{next_action: %{key: :add_triggers} = action} = health,
         routines
       ) do
    routine_id =
      case Enum.find(routines, &(&1.status == :active and without_enabled_trigger?(&1))) do
        %{id: id} -> id
        _ -> nil
      end

    if is_binary(routine_id) do
      %{health | next_action: Map.put(action, :routine_id, routine_id)}
    else
      health
    end
  end

  defp put_next_action_routine_id(health, _routines), do: health

  defp get_scoped_routine(socket, id) do
    case current_company_id(socket) do
      nil -> {:error, :not_found}
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
    active_routines = Enum.filter(routines, &(&1.status == :active))

    triggerless = Enum.find(active_routines, &without_enabled_trigger?/1)
    stale = Enum.find(routines, & &1.has_stale_run)
    failed = Enum.find(routines, & &1.has_recent_failure)
    paused = Enum.find(routines, &(&1.status == :paused))
    runnable = Enum.find(active_routines, &(not without_enabled_trigger?(&1)))

    command =
      cond do
        metrics.total_routines == 0 ->
          %{
            badge: "None yet",
            heading: "Set up the first repeating task",
            detail:
              "A repeating task files work on a schedule, so you don't have to remember to.",
            action_label: "New repeating task",
            action_path: "/routines/new",
            focus_label: nil,
            focus_detail: nil
          }

        triggerless ->
          %{
            badge: "No trigger",
            heading: "Give a repeating task a schedule",
            detail:
              "#{triggerless.name} is on, but nothing can set it off — add a schedule or webhook.",
            action_label: "Open it",
            action_path: "/routines/#{triggerless.id}",
            focus_label: triggerless.name,
            focus_detail: "Active without enabled trigger"
          }

        stale ->
          %{
            badge: "Stuck run",
            heading: "A run looks stuck",
            detail: "#{stale.name} has a run that's been going for over two hours.",
            action_label: "Open run history",
            action_path: "/routines/#{stale.id}",
            focus_label: stale.name,
            focus_detail: latest_run_label(stale)
          }

        failed ->
          %{
            badge: "Recent failure",
            heading: "Look at the failed run",
            detail: "#{failed.name} failed recently. Worth a look before it runs again.",
            action_label: "Open it",
            action_path: "/routines/#{failed.id}",
            focus_label: failed.name,
            focus_detail: latest_run_label(failed)
          }

        paused ->
          %{
            badge: "Paused",
            heading: "A repeating task is paused",
            detail: "#{paused.name} won't file work until you resume or archive it.",
            action_label: "Open it",
            action_path: "/routines/#{paused.id}",
            focus_label: paused.name,
            focus_detail: "Paused"
          }

        runnable ->
          %{
            badge: "Running",
            heading: "Repeating tasks are running",
            detail:
              "#{metrics.active_routines} active repeating task#{plural_suffix(metrics.active_routines)} filing work on schedule.",
            action_label: "Open it",
            action_path: "/routines/#{runnable.id}",
            focus_label: runnable.name,
            focus_detail: latest_run_label(runnable)
          }

        true ->
          %{
            badge: "None active",
            heading: "None are running",
            detail:
              "You have repeating tasks, but none are active. Resume one or create a new one.",
            action_label: "New repeating task",
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

  defp latest_run_label(%{runs: []}), do: "No runs yet"

  defp latest_run_label(%{runs: runs}) do
    runs
    |> Enum.max_by(&(&1.triggered_at || ~U[1970-01-01 00:00:00Z]), DateTime)
    |> then(fn run ->
      "#{routine_label(run.status)} · #{routine_label(run.trigger_type)}"
    end)
  end

  def routine_label(nil), do: "Unknown"

  def routine_label(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  # ── Row ────────────────────────────────────────────────────────────────────
  # Each row answers "is it healthy and when does it run next?". Only a repeating
  # task that needs a person (failed / stuck / no trigger) carries a status.

  attr :id, :string, required: true
  attr :routine, :map, required: true
  attr :agent_names, :map, required: true
  attr :density, :string, required: true

  def routine_row(assigns) do
    triggers = assigns.routine.triggers

    assigns =
      assigns
      |> assign(:status, routine_status(assigns.routine))
      |> assign(:schedule, schedule_summary(triggers))
      |> assign(:next, next_run(triggers))
      |> assign(:cron, raw_cron(triggers))
      |> assign(:agent, assigns.agent_names[assigns.routine.agent_id])

    ~H"""
    <.list_row
      tag="div"
      id={@id}
      title={@routine.name}
      navigate={~p"/routines/#{@routine.id}"}
      status={@status}
    >
      <:meta>
        <span title={@cron && "cron: #{@cron}"}>{@schedule}</span><span :if={@agent}><span aria-hidden="true"> · </span>{@agent}</span><span :if={
          @next
        }><span aria-hidden="true"> · </span>Next run {@next}</span>
      </:meta>
      <:trail :if={@routine.status in [:paused, :archived]}>
        <span class="tag">{routine_label(@routine.status)}</span>
      </:trail>
      <:actions>
        <.pill
          :if={@routine.status == :active}
          phx-click="pause_routine"
          phx-value-id={@routine.id}
          data-confirm="Pause this routine? It stops creating work until resumed."
        >
          Pause
        </.pill>
        <.pill
          :if={@routine.status == :paused}
          phx-click="resume_routine"
          phx-value-id={@routine.id}
          data-confirm="Resume this routine? It will create work on its next trigger."
        >
          Resume
        </.pill>
        <.overflow_menu id={"routine-menu-#{@routine.id}"} label={"Actions for #{@routine.name}"}>
          <.menu_item navigate={~p"/routines/#{@routine.id}/edit"}>Edit</.menu_item>
          <.menu_item
            :if={@routine.status != :archived}
            danger
            phx-click="delete_routine"
            phx-value-id={@routine.id}
            data-confirm="Archive this routine? It stops running and moves out of the active list."
          >
            Archive
          </.menu_item>
        </.overflow_menu>
      </:actions>
      <:below :if={@density == "detailed"}>
        <p class="gl-sub">{@routine.description || "No description provided."}</p>
        <p class="ui-advanced-only help">
          {routine_label(@routine.priority)} priority<span aria-hidden="true"> · </span>{routine_label(
            @routine.concurrency_policy
          )}<span aria-hidden="true"> · </span>Missed runs: {routine_label(@routine.catch_up_policy)}<span aria-hidden="true"> · </span>Max {@routine.catch_up_cap}
        </p>
      </:below>
    </.list_row>
    """
  end

  @doc "Only a repeating task that needs a person carries a status word."
  def routine_status(%{status: :archived}), do: nil
  # has_recent_failure is any failed run in the last day, not the latest run's outcome.
  def routine_status(%{has_recent_failure: true}), do: {:stopped, "Failed recently"}
  def routine_status(%{has_stale_run: true}), do: {:waiting, "Run stuck"}

  def routine_status(%{status: :active} = routine) do
    if without_enabled_trigger?(routine), do: {:waiting, "Needs a trigger"}
  end

  def routine_status(_routine), do: nil

  def recommendation_kind(:critical), do: :problem
  def recommendation_kind(:warning), do: :question
  def recommendation_kind(_severity), do: :neutral

  def routine_posture_text(:empty) do
    "No recurring automation is configured. Create one routine, attach a trigger, then watch run history here."
  end

  def routine_posture_text(_level) do
    "Triggers, run freshness, recent failures, and paused recurring work are quiet."
  end

  defp plural_suffix(1), do: ""
  defp plural_suffix(_), do: "s"

  def routine_next_action_path(%{key: :add_triggers, routine_id: id}), do: "/routines/" <> id
  def routine_next_action_path(%{key: :create_first_routine}), do: "/routines/new"
  def routine_next_action_path(_action), do: "/routines"
end
