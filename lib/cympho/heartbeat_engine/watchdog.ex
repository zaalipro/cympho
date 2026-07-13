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

  alias Cympho.HeartbeatEngine
  alias Cympho.HeartbeatEngine.WakeupQueue
  alias Cympho.AgentHeartbeat
  require Logger

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
    stale_runs = HeartbeatEngine.find_stale_runs(@stale_threshold)
    stale_run_ids = MapSet.new(stale_runs, & &1.id)

    orphaned_runs =
      HeartbeatEngine.find_orphaned_runs()
      |> Enum.reject(&MapSet.member?(stale_run_ids, &1.id))

    stale_recovered =
      Enum.flat_map(stale_runs, fn run ->
        case HeartbeatEngine.recover_stale_run(run) do
          {:ok, recovered} ->
            Logger.warning("Watchdog: recovered stale run #{run.id} for agent #{run.agent_id}")
            maybe_requeue_issue(recovered)
            [recovered]

          {:error, {:invalid_status, status}} ->
            # Benign race: the run reached a terminal state between the scan
            # and the recovery write. Nothing to fix.
            Logger.info("Watchdog: stale run finished before recovery",
              component: "watchdog",
              agent_id: run.agent_id,
              issue_id: run.issue_id,
              run_id: run.id,
              status: status
            )

            []

          {:error, reason} ->
            Logger.error("Watchdog: failed to recover stale run #{run.id}: #{inspect(reason)}")
            []
        end
      end)

    orphaned_recovered =
      Enum.flat_map(orphaned_runs, fn run ->
        case HeartbeatEngine.recover_orphaned_run(run) do
          {:ok, recovered} ->
            Logger.warning("Watchdog: recovered orphaned run #{run.id} for agent #{run.agent_id}")
            maybe_requeue_issue(recovered)
            [recovered]

          {:error, {:invalid_status, status}} ->
            Logger.info("Watchdog: orphaned run finished before recovery",
              component: "watchdog",
              agent_id: run.agent_id,
              issue_id: run.issue_id,
              run_id: run.id,
              status: status
            )

            []

          {:error, reason} ->
            Logger.error("Watchdog: failed to recover orphaned run #{run.id}: #{inspect(reason)}")

            []
        end
      end)

    stranded_wake_agents = rewake_stranded_agents()

    results = %{
      stale_found: length(stale_runs),
      stale_recovered: length(stale_recovered),
      orphaned_found: length(orphaned_runs),
      orphaned_recovered: length(orphaned_recovered),
      stranded_wake_agents: length(stranded_wake_agents),
      checked_at: DateTime.utc_now()
    }

    if results.stale_found > 0 or results.orphaned_found > 0 or
         results.stranded_wake_agents > 0 do
      Logger.info("Watchdog: #{inspect(results)}")
    end

    %{state | last_results: results, check_count: state.check_count + 1}
  end

  # A wake row is durable but its delivery is a fire-and-forget PubSub
  # broadcast. When the target heartbeat process was dead (crash, node
  # restart, never started), the wake stays "pending" forever and the agent
  # sleeps through it. Sweep for old pending wakes and re-trigger — or
  # restart — the owning heartbeat loop.
  defp rewake_stranded_agents do
    agent_ids = WakeupQueue.agent_ids_with_stale_pending(@stale_threshold)

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
