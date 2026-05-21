defmodule Cympho.HeartbeatEngine.Watchdog do
  @moduledoc """
  Periodically checks for stale and orphaned runs, recovering them.

  The watchdog:
    - Finds runs with no heartbeat within the stale threshold
    - Finds orphaned runs (running but with no active orchestrator process)
    - Recovers them by marking as failed
    - Optionally re-queues the associated issue for another agent
  """

  use GenServer, restart: :permanent

  alias Cympho.HeartbeatEngine
  alias Cympho.AgentHeartbeat
  require Logger

  @default_check_interval :timer.minutes(5)
  @default_stale_threshold 15

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
    schedule_check()
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

  defp do_check(state) do
    stale_runs = HeartbeatEngine.find_stale_runs(@stale_threshold)
    orphaned_runs = HeartbeatEngine.find_orphaned_runs()

    stale_recovered =
      Enum.flat_map(stale_runs, fn run ->
        case HeartbeatEngine.recover_stale_run(run) do
          {:ok, recovered} ->
            Logger.warning("Watchdog: recovered stale run #{run.id} for agent #{run.agent_id}")
            maybe_requeue_issue(recovered)
            [recovered]

          {:error, reason} ->
            Logger.error("Watchdog: failed to recover stale run #{run.id}: #{inspect(reason)}")
            []
        end
      end)

    orphaned_recovered =
      Enum.flat_map(orphaned_runs, fn run ->
        case HeartbeatEngine.recover_stale_run(run) do
          {:ok, recovered} ->
            Logger.warning("Watchdog: recovered orphaned run #{run.id} for agent #{run.agent_id}")
            maybe_requeue_issue(recovered)
            [recovered]

          {:error, reason} ->
            Logger.error("Watchdog: failed to recover orphaned run #{run.id}: #{inspect(reason)}")

            []
        end
      end)

    results = %{
      stale_found: length(stale_runs),
      stale_recovered: length(stale_recovered),
      orphaned_found: length(orphaned_runs),
      orphaned_recovered: length(orphaned_recovered),
      checked_at: DateTime.utc_now()
    }

    if results.stale_found > 0 or results.orphaned_found > 0 do
      Logger.info("Watchdog: #{inspect(results)}")
    end

    %{state | last_results: results, check_count: state.check_count + 1}
  end

  defp maybe_requeue_issue(%{issue_id: _issue_id, agent_id: agent_id}) do
    case AgentHeartbeat.trigger_heartbeat(agent_id) do
      :ok ->
        Logger.info("Watchdog: re-triggered heartbeat for agent #{agent_id} after recovery")

      {:error, :not_found} ->
        Logger.info("Watchdog: agent #{agent_id} heartbeat process not found for re-trigger")
    end
  end
end
