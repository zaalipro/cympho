defmodule Cympho.HeartbeatEngine.Watchdog do
  @moduledoc """
  Periodically checks for stale and orphaned runs, recovering them.

  The watchdog:
    - Finds runs with no heartbeat within the stale threshold
    - Finds orphaned runs with no active orchestrator process
    - Fails interrupted running work and cancels never-started orphan work
    - Optionally re-queues the associated issue for another agent
  """

  use GenServer, restart: :permanent

  alias Cympho.AgentHeartbeat
  alias Cympho.Finances
  alias Cympho.HeartbeatEngine
  alias Cympho.HeartbeatEngine.WakeupQueue
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Recovery
  alias Cympho.Recovery.RecoveryCase
  require Logger
  import Ecto.Query

  @default_check_interval :timer.minutes(5)
  @default_stale_threshold 15
  @default_initial_delay :timer.seconds(30)

  @check_interval Application.compile_env(
                    :cympho,
                    [:heartbeat_engine, :watchdog_check_interval],
                    @default_check_interval
                  )
  @stale_threshold Application.compile_env(
                     :cympho,
                     [:heartbeat_engine, :stale_threshold_minutes],
                     @default_stale_threshold
                   )
  # First check runs soon after (re)start instead of waiting a full interval,
  # so a watchdog crash/restart or node boot doesn't leave stale runs
  # unrecovered for an extra @check_interval.
  @initial_delay Application.compile_env(
                   :cympho,
                   [:heartbeat_engine, :watchdog_initial_delay],
                   @default_initial_delay
                 )

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers an immediate watchdog check.
  """
  @spec check_now() :: :ok
  def check_now do
    GenServer.cast(__MODULE__, :check_now)
  end

  @doc """
  Returns the last check results for debugging.
  """
  @spec last_results() :: map()
  def last_results do
    GenServer.call(__MODULE__, :last_results)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    Process.send_after(self(), :check, @initial_delay)
    {:ok, %{last_results: %{}, check_count: 0}}
  end

  @impl true
  def handle_cast(:check_now, state) do
    new_state = do_check(state)
    {:noreply, new_state}
  end

  def handle_cast(msg, state) do
    Logger.warning("Watchdog: unexpected cast #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:last_results, _from, state) do
    {:reply, state.last_results, state}
  end

  @impl true
  def handle_info(:check, state) do
    new_state = do_check(state)
    schedule_check()
    {:noreply, new_state}
  end

  def handle_info(msg, state) do
    Logger.warning("Watchdog: unexpected message #{inspect(msg)}")
    {:noreply, state}
  end

  # Internal

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval)
  end

  # A transient DB error must not crash the watchdog: a crash loses the timer
  # state and burns supervisor restart budget shared with the whole app. Log
  # and try again on the next tick instead.
  defp do_check(state) do
    run_check(state)
  rescue
    error ->
      Logger.error("Watchdog: check failed, will retry next tick",
        component: "watchdog",
        error: inspect(error)
      )

      %{state | check_count: state.check_count + 1}
  end

  defp run_check(state) do
    usage_reconciliation = reconcile_terminal_usage()
    recovery_stats = recovery_stats()
    stale_runs = HeartbeatEngine.find_stale_runs(@stale_threshold)
    stale_run_ids = MapSet.new(stale_runs, & &1.id)

    orphaned_runs =
      HeartbeatEngine.find_orphaned_runs()
      |> Enum.reject(&MapSet.member?(stale_run_ids, &1.id))

    {stale_recovered, recovery_stats} = recover_runs(stale_runs, :stale, recovery_stats)
    {orphaned_recovered, recovery_stats} = recover_runs(orphaned_runs, :orphaned, recovery_stats)

    stale_wake_claims = WakeupQueue.recover_stale_running(@stale_threshold)
    stranded_wake_agents = rewake_stranded_agents(stale_wake_claims.agent_ids)

    # Reclaim stranded :in_progress issues and age-threshold checkouts that
    # hold capacity without a live orchestrator/run. Same helpers the
    # dispatcher poll uses so either cadence covers the other (including
    # when autonomous dispatch is disabled).
    {orphaned_issues, orphaned_issue_telemetry} =
      Dispatcher.recover_orphaned_in_progress_with_telemetry()

    {stale_checkouts, stale_checkout_telemetry} =
      Dispatcher.recover_stale_checkouts_with_telemetry()

    # Budget hard-stop cleanup runs after the finance ledger commit. A crash
    # between commit and stop/cancel/pause leaves incomplete incidents; re-drive
    # them here (also covers node boot via the initial delay tick).
    hard_stops_completed = Finances.recover_incomplete_hard_stops()

    results = %{
      terminal_usage_reconciled: usage_reconciliation.reconciled,
      terminal_usage_reconciliation_failed: usage_reconciliation.failed,
      stale_found: length(stale_runs),
      stale_recovered: length(stale_recovered),
      orphaned_found: length(orphaned_runs),
      orphaned_recovered: length(orphaned_recovered),
      stale_wake_claims_recovered: stale_wake_claims.recovered,
      stranded_wake_agents: length(stranded_wake_agents),
      orphaned_issues_checked: orphaned_issues.checked,
      orphaned_issues_recovered: orphaned_issues.recovered,
      stale_checkouts_checked: stale_checkouts.checked,
      stale_checkouts_released: stale_checkouts.released,
      hard_stops_completed: hard_stops_completed,
      recovery_cases_created:
        recovery_stats.cases_created + orphaned_issue_telemetry.cases_created +
          stale_checkout_telemetry.cases_created,
      recovery_attempts:
        recovery_stats.attempts + orphaned_issue_telemetry.attempts +
          stale_checkout_telemetry.attempts,
      recovery_exhausted:
        recovery_stats.exhausted + Map.get(orphaned_issues, :exhausted, 0) +
          Map.get(stale_checkouts, :exhausted, 0),
      checked_at: DateTime.utc_now()
    }

    if results.terminal_usage_reconciled > 0 or results.terminal_usage_reconciliation_failed > 0 or
         results.stale_found > 0 or results.orphaned_found > 0 or
         results.stale_wake_claims_recovered > 0 or results.stranded_wake_agents > 0 or
         results.orphaned_issues_recovered > 0 or
         results.stale_checkouts_released > 0 or results.hard_stops_completed > 0 or
         results.recovery_cases_created > 0 or results.recovery_attempts > 0 or
         results.recovery_exhausted > 0 do
      Logger.info("Watchdog: #{inspect(results)}")
    end

    %{state | last_results: results, check_count: state.check_count + 1}
  end

  defp recovery_stats do
    existing_sources =
      from(c in RecoveryCase,
        where: c.state in ^RecoveryCase.active_states(),
        select: {c.source_type, c.source_id}
      )
      |> Cympho.Repo.all()
      |> MapSet.new()

    %{cases_created: 0, attempts: 0, exhausted: 0, existing_sources: existing_sources}
  end

  defp recover_runs(runs, kind, stats) do
    Enum.reduce(runs, {[], stats}, fn run, {recovered_runs, stats} ->
      result =
        case kind do
          :stale -> Recovery.recover_stale_run(run)
          :orphaned -> Recovery.recover_orphaned_run(run)
        end

      case result do
        {:ok, %{run: recovered, outcome: :recovered, case: recovery_case}} ->
          Logger.warning("Watchdog: recovered #{kind} run #{run.id} for agent #{run.agent_id}")

          maybe_requeue_issue(recovered)
          {[recovered | recovered_runs], record_recovery(stats, recovery_case, :recovered)}

        {:ok, %{run: _recovered, outcome: :superseded, case: recovery_case}} ->
          Logger.info(
            "Watchdog: #{kind} run #{run.id} finished before recovery (superseded)",
            component: "watchdog",
            agent_id: run.agent_id,
            issue_id: run.issue_id,
            run_id: run.id
          )

          {recovered_runs, record_recovery(stats, recovery_case, :superseded)}

        {:ok, %{outcome: outcome, case: recovery_case}}
        when outcome in [:scheduled, :exhausted] ->
          Logger.info(
            "Watchdog: #{kind} run #{run.id} recovery #{outcome}",
            component: "watchdog",
            agent_id: run.agent_id,
            issue_id: run.issue_id,
            run_id: run.id
          )

          {recovered_runs, record_recovery(stats, recovery_case, outcome)}

        {:error, :company_scope_required} ->
          # Recovery is fail-closed for unscoped or mismatched-tenant rows.
          # Leave the source untouched and never deliver a wake.
          Logger.warning(
            "Watchdog: skipped #{kind} run #{run.id} due to company scope validation"
          )

          {recovered_runs, stats}

        {:error, :already_claimed} ->
          {recovered_runs, stats}

        {:error, :not_due} ->
          {recovered_runs, stats}

        {:error, :exhausted} ->
          {recovered_runs, %{stats | exhausted: stats.exhausted + 1}}

        {:error, {:invalid_status, status}} ->
          Logger.info("Watchdog: #{kind} run finished before recovery",
            component: "watchdog",
            agent_id: run.agent_id,
            issue_id: run.issue_id,
            run_id: run.id,
            status: status
          )

          {recovered_runs, stats}

        {:error, reason} ->
          Logger.error("Watchdog: failed to recover #{kind} run #{run.id}: #{inspect(reason)}")
          {recovered_runs, stats}
      end
    end)
    |> then(fn {runs, stats} -> {Enum.reverse(runs), stats} end)
  end

  defp record_recovery(stats, recovery_case, outcome) do
    stats = %{stats | attempts: stats.attempts + 1}
    stats = if outcome == :exhausted, do: %{stats | exhausted: stats.exhausted + 1}, else: stats

    case recovery_case do
      %{source_type: source_type, source_id: source_id} = _case ->
        source = {source_type, source_id}

        if MapSet.member?(stats.existing_sources, source) do
          stats
        else
          %{
            stats
            | cases_created: stats.cases_created + 1,
              existing_sources: MapSet.put(stats.existing_sources, source)
          }
        end

      _ ->
        stats
    end
  end

  defp reconcile_terminal_usage do
    case HeartbeatEngine.reconcile_unrecorded_terminal_usage() do
      {:ok, count} ->
        %{reconciled: count, failed: 0}

      {:error, reason} ->
        Logger.error("Watchdog: terminal usage reconciliation failed; will retry next tick",
          component: "watchdog",
          error: inspect(reason)
        )

        %{reconciled: 0, failed: 1}
    end
  end

  # A wake row is durable but its delivery is a fire-and-forget PubSub
  # broadcast. When the target heartbeat process was dead (crash, node
  # restart, never started), the wake stays "pending" forever and the agent
  # sleeps through it. Sweep for old pending wakes and re-trigger — or
  # restart — the owning heartbeat loop.
  defp rewake_stranded_agents(recovered_agent_ids) do
    agent_ids =
      recovered_agent_ids
      |> Kernel.++(WakeupQueue.agent_ids_with_stale_pending(@stale_threshold))
      |> Enum.uniq()

    Enum.each(agent_ids, fn agent_id ->
      case AgentHeartbeat.trigger_heartbeat(agent_id) do
        :ok ->
          # Process alive — it may simply be busy, or it missed the original
          # broadcast. The re-trigger is idempotent and cheap either way.
          Logger.info("Watchdog: re-triggered heartbeat for stale pending wakes",
            component: "watchdog",
            agent_id: agent_id
          )

        {:error, :not_found} ->
          Logger.warning("Watchdog: heartbeat process missing for agent with pending wakes",
            component: "watchdog",
            agent_id: agent_id
          )

          restart_heartbeat(agent_id)
      end
    end)

    agent_ids
  end

  defp maybe_requeue_issue(%{issue_id: _issue_id, agent_id: agent_id}) do
    case AgentHeartbeat.trigger_heartbeat(agent_id) do
      :ok ->
        Logger.info("Watchdog: re-triggered heartbeat for agent #{agent_id} after recovery")

      {:error, :not_found} ->
        # The per-agent heartbeat process is gone (crashed, or lost across a
        # node restart). Without it the recovered issue waits on the slower
        # dispatcher poll — or forever when dispatch is disabled — so restart
        # the loop here. The heartbeat itself re-checks agent/company runtime
        # eligibility before doing any work.
        restart_heartbeat(agent_id)
    end
  end

  defp restart_heartbeat(agent_id) do
    case AgentHeartbeat.start_for_agent(agent_id) do
      {:ok, _pid} ->
        _ = AgentHeartbeat.trigger_heartbeat(agent_id)

        Logger.warning("Watchdog: restarted missing heartbeat process after recovery",
          component: "watchdog",
          agent_id: agent_id
        )

      {:error, :already_started} ->
        _ = AgentHeartbeat.trigger_heartbeat(agent_id)

      {:error, reason} ->
        Logger.error("Watchdog: failed to restart heartbeat process",
          component: "watchdog",
          agent_id: agent_id,
          error: inspect(reason)
        )
    end
  end
end
