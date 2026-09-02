defmodule Cympho.Orchestrator.Dispatcher do
  @moduledoc """
  Polls the DB for runnable issues and dispatches agent sessions.

  Configuration (app env):
    - :poll_interval          — ms between polls (default 30_000)
    - :max_concurrent_agents — max simultaneous dispatches (default: scales
      with `:erlang.system_info(:schedulers_online)`, see `max_concurrent/0`)
    - :active_states         — issue states considered runnable (default [:todo, :in_review])
    - :terminal_states       — issue states that stop reconciliation (default [:done, :cancelled])
    - :only_issue_id          — optional issue UUID for focused dispatch

  The dispatcher finds assigned or unassigned issues in active states, checks
  each one out for a company-scoped eligible agent, then starts an Orchestrator
  session.
  """

  # `shutdown: 10_000` gives terminate/2 enough time to release in-flight
  # issues back to :todo before the supervisor brutally kills the process.
  # Default 5s was too tight under load.
  use GenServer, restart: :permanent, shutdown: 10_000
  require Logger
  import Ecto.Query
  alias Cympho.Orchestrator.Dispatcher.State
  alias Cympho.Orchestrator.Dispatcher.Router
  alias Cympho.Orchestrator
  alias Cympho.Issues
  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.HeartbeatEngine
  alias Cympho.Runtime
  alias Cympho.HeartbeatEngine.WakeupQueue
  alias Cympho.Companies.Company
  alias Cympho.Agents.Agent
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue
  alias Cympho.Wakes.AgentWake
  alias Cympho.Workspaces

  @poll_interval Application.compile_env(:cympho, [:orchestrator, :poll_interval], 30_000)
  @active_states Application.compile_env(:cympho, [:orchestrator, :active_states], [
                   :todo,
                   :in_review
                 ])
  @terminal_states Application.compile_env(:cympho, [:orchestrator, :terminal_states], [
                     :done,
                     :cancelled
                   ])
  @max_retries Application.compile_env(:cympho, [:orchestrator, :max_retries], 5)
  @base_backoff_ms Application.compile_env(:cympho, [:orchestrator, :base_backoff_ms], 30_000)
  @max_backoff_ms Application.compile_env(:cympho, [:orchestrator, :max_backoff_ms], 600_000)
  @adapter_stop_confirm_attempts 10
  @adapter_stop_confirm_sleep_ms 25
  @adapter_ledger_retry_ms 250
  @default_company_stop_deadline_ms 12_000
  @default_company_stop_max_concurrency 8
  @dispatcher_snapshot_timeout_ms 1_000
  @orphan_checkout_grace_seconds 15 * 60
  @low_power_priorities [:critical, :high]
  # Delivery roles the CTO both manages and outranks, so it can staff them
  # itself. See `staffing_owner/2`.
  @cto_staffed_roles Cympho.Agents.Agent.pr_delivery_roles()

  # Client

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current set of running issue ids."
  def running_issue_ids do
    GenServer.call(__MODULE__, :running_issue_ids)
  end

  @doc "Returns the dispatcher's current state snapshot for debugging."
  def state do
    GenServer.call(__MODULE__, :state)
  end

  @doc "Requests an immediate poll when the dispatcher is running."
  def poll_now do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_started}

      pid ->
        send(pid, :poll)
        :ok
    end
  end

  @doc "Returns whether autonomous dispatch is enabled for this runtime."
  def enabled? do
    :cympho
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get(:enabled, true)
  end

  @doc """
  Returns whether an issue may be selected by the automatic dispatcher poll.

  Blocked issues are intentionally parked unless a subordinate explicitly
  escalated the issue to a manager. Operators can relaunch ordinary blocked
  issues through the issue page, which reopens the issue to `:todo`, and
  blocker-resolution flows also reopen dependents explicitly. Keeping this rule
  here prevents a broad `:active_states` override from making blocked work
  runnable again.
  """
  def runnable_candidate?(%Issue{status: status} = issue) when status in [:blocked, "blocked"] do
    not Issues.issue_runtime_paused?(issue) and
      not Issues.is_blocked?(issue) and
      runtime_mode_allows_issue?(issue) and
      pending_blocked_resume_wake?(issue.id)
  end

  def runnable_candidate?(%Issue{} = issue) do
    not Issues.issue_runtime_paused?(issue) and
      not Issues.is_blocked?(issue) and
      runtime_mode_allows_issue?(issue)
  end

  @doc "Requests an immediate poll scoped to one company."
  def poll_company(company_id) when is_binary(company_id) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_started}

      pid ->
        send(pid, {:poll_company, company_id})
        :ok
    end
  end

  @doc """
  Stops active orchestrator sessions for a company and releases in-progress
  issues so operators can regain control immediately.
  """
  def stop_company(company_id, reason \\ :operator_stop)

  def stop_company(company_id, reason) when is_binary(company_id) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:ok, stop_company_runtime(company_id, reason, MapSet.new())}

      pid ->
        running_issue_ids = dispatcher_running_issue_ids(pid)
        result = stop_company_runtime(company_id, reason, running_issue_ids, self())
        send(pid, {:company_stop_finished, result.issue_ids -- result.deferred_issue_ids})
        {:ok, result}
    end
  end

  def stop_company(_company_id, _reason), do: {:error, :invalid_company_id}

  @doc """
  Stops active orchestrator/runtime work for one issue and releases its checkout.
  """
  def stop_issue(issue_id, reason \\ :operator_issue_pause)

  def stop_issue(issue_id, reason) when is_binary(issue_id) do
    result =
      issue_id
      |> issue_runtime_issues()
      |> Enum.reduce(empty_stop_result(reason), &stop_runtime_issue/2)
      |> Map.update!(:issue_ids, &Enum.reverse/1)

    {:ok, result}
  end

  def stop_issue(_issue_id, _reason), do: {:error, :invalid_issue_id}

  @doc """
  Enqueues a wake for an issue's current assignee, or polls for assignment when
  the issue is unassigned.
  """
  def enqueue_wake(issue_id, reason, metadata \\ %{}) when is_binary(issue_id) do
    with {:ok, issue} <- Issues.get_issue(issue_id) do
      cond do
        Issues.issue_runtime_paused?(issue) ->
          {:error, :issue_runtime_paused}

        company_paused?(issue.company_id) ->
          {:error, :company_paused}

        issue.assignee_id ->
          result =
            WakeupQueue.enqueue(%{
              agent_id: issue.assignee_id,
              issue_id: issue.id,
              reason: to_string(reason),
              triggered_by_type: "system",
              metadata: metadata
            })

          _ = Cympho.AgentHeartbeat.trigger_heartbeat(issue.assignee_id)
          _ = poll_now()
          result

        true ->
          _ = poll_now()
          {:ok, :queued_for_dispatch}
      end
    end
  end

  defp company_paused?(nil), do: false

  defp company_paused?(company_id) do
    case Cympho.Repo.get(Company, company_id) do
      %Company{} = company -> not Companies.active?(company)
      nil -> false
    end
  end

  # Server

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    # Always recover orphans once on boot — even when the orchestrator is
    # disabled — so live-node strands and non-dispatcher checkouts do not
    # wait for a manual Ops pass or a full restart. Polling only runs when
    # dispatch is enabled.
    state = if enabled?(), do: schedule_poll(State.new()), else: State.new()

    # Hand recovery off to handle_continue so init/1 returns fast even if
    # the recovery scan hits a slow DB. Without this, a stuck Repo blocks
    # the whole supervisor boot.
    #
    # In test env there is no Ecto sandbox connection for this process, so the
    # scan would fail on every boot and log an ownership error that buries real
    # failures. Recovery tests call handle_continue/2 and the recover_* helpers
    # directly, which is the same code path.
    # Orchestrators are deliberately unlinked and survive a Dispatcher crash.
    # Rebuild their slot accounting in a continue before the first mailbox
    # message can dispatch more work. This must run even when orphan recovery
    # is disabled (notably in tests), because it is normal restart state rather
    # than repair work.
    {:ok, state, {:continue, :rebuild_live_sessions}}
  end

  defp recover_on_boot?, do: Application.get_env(:cympho, :dispatcher_recover_on_boot?, true)

  @impl true
  def handle_continue(:rebuild_live_sessions, %State{} = state) do
    state = rebuild_live_sessions(state)

    if recover_on_boot?() do
      recover_orphans()
    end

    {:noreply, state}
  end

  # Backward-compatible direct entry used by recovery tests and operators.
  def handle_continue(:recover_orphans, %State{} = state) do
    state = rebuild_live_sessions(state)
    recover_orphans()
    {:noreply, state}
  end

  defp recover_orphans do
    recover_orphaned_runs()
    _ = recover_orphaned_in_progress()
    _ = recover_stale_checkouts()
    :ok
  end

  @doc false
  @spec rebuild_live_sessions(State.t()) :: State.t()
  def rebuild_live_sessions(%State{} = state) do
    # This is normally called once with a fresh State after Dispatcher restart.
    # Clearing any supplied monitors makes the helper idempotent in tests and
    # prevents a second rebuild from accumulating duplicate DOWN messages.
    Enum.each(Map.keys(state.monitors), &Process.demonitor(&1, [:flush]))

    entries = live_registry_entries()
    valid_issue_ids = valid_live_session_issue_ids(entries)

    {running_issue_ids, monitors} =
      Enum.reduce(entries, {MapSet.new(), %{}}, fn {issue_id, pid}, {running, monitors} ->
        if MapSet.member?(valid_issue_ids, issue_id) do
          ref = Process.monitor(pid)
          {MapSet.put(running, issue_id), Map.put(monitors, ref, issue_id)}
        else
          {running, monitors}
        end
      end)

    live_controller_pids = entries |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    adapter_sessions =
      case Cympho.AdapterSessions.active_sessions() do
        {:ok, sessions} -> sessions
        {:error, :not_started} -> raise "adapter session ledger unavailable"
      end

    {running_issue_ids, monitors} =
      adapter_sessions
      |> Enum.reduce({running_issue_ids, monitors}, fn session, {running, monitors} ->
        if orphan_cleanup_session?(session, live_controller_pids) do
          ref = Process.monitor(session.pid)

          {
            MapSet.put(running, session.issue_id),
            Map.put(
              monitors,
              ref,
              {:adapter_cleanup, session.issue_id, :dispatcher_restart, :crash}
            )
          }
        else
          {running, monitors}
        end
      end)

    if MapSet.size(running_issue_ids) > 0 do
      Logger.info(
        "[Dispatcher] restored #{MapSet.size(running_issue_ids)} live orchestrator slot(s) after restart"
      )
    end

    %{state | running_issue_ids: running_issue_ids, monitors: monitors}
  end

  defp orphan_cleanup_session?(
         %{pid: pid, controller_pid: controller_pid, issue_id: issue_id},
         live_controller_pids
       )
       when is_pid(pid) and is_binary(issue_id) do
    Process.alive?(pid) and
      not MapSet.member?(live_controller_pids, controller_pid) and
      (not is_pid(controller_pid) or not Process.alive?(controller_pid))
  end

  defp orphan_cleanup_session?(_session, _live_controller_pids), do: false

  defp live_registry_entries do
    Cympho.OrchestratorRegistry
    |> Registry.select([
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.filter(fn
      {issue_id, pid} when is_binary(issue_id) and is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end)
    |> Enum.uniq_by(fn {issue_id, _pid} -> issue_id end)
  rescue
    error ->
      Logger.error("[Dispatcher] failed to enumerate live orchestrators: #{inspect(error)}")
      []
  end

  defp valid_live_session_issue_ids([]), do: MapSet.new()

  defp valid_live_session_issue_ids(entries) do
    issue_ids = Enum.map(entries, &elem(&1, 0))

    # Registry cleanup is asynchronous relative to process death. Requiring an
    # authoritative in-progress issue prevents a stale key (or a process that
    # registered but failed before checkout) from pinning capacity forever.
    from(i in Issue,
      left_join: r in Run,
      on: r.id == i.checkout_run_id,
      where:
        i.id in ^issue_ids and i.status == :in_progress and
          (is_nil(i.checkout_run_id) or
             (r.status in ["pending", "queued", "running"] and r.issue_id == i.id and
                r.agent_id == i.assignee_id)),
      select: i.id
    )
    |> Cympho.Repo.all()
    |> MapSet.new()
  rescue
    error ->
      # DB-backed dispatch cannot safely proceed during the same outage. Keep
      # live registry entries counted conservatively rather than reopening all
      # slots and oversubscribing the host as connectivity returns.
      Logger.error(
        "[Dispatcher] failed to validate live orchestrators; retaining their slots: #{inspect(error)}"
      )

      entries |> Enum.map(&elem(&1, 0)) |> MapSet.new()
  end

  defp recover_orphaned_runs do
    Cympho.HeartbeatEngine.find_orphaned_runs()
    |> Enum.each(fn run ->
      unless live_orchestrator?(run.issue_id) do
        case Cympho.Recovery.recover_orphaned_run(run) do
          {:ok, %{run: recovered, outcome: outcome}} ->
            level = if outcome == :recovered, do: :warning, else: :info

            Logger.log(
              level,
              "[Dispatcher] orphaned run #{run.id} (issue=#{run.issue_id}, status=#{run.status}) → #{recovered.status} (#{outcome})"
            )

          {:error, reason} ->
            Logger.error(
              "[Dispatcher] failed to recover orphaned run #{run.id}: #{inspect(reason)}"
            )
        end
      end
    end)
  rescue
    error ->
      Logger.error("[Dispatcher] orphan run recovery failed: #{inspect(error)}")
      :ok
  end

  @doc """
  Reclaims stranded `:in_progress` issues that have no live Orchestrator and
  no non-terminal run.

  Uses `Issues.clear_checkout_lock/2` so the intended assignee is preserved
  for the next dispatch. Safe to call from boot, dispatcher poll, and the
  heartbeat watchdog tick.

  Returns `%{checked: n, recovered: n, skipped: n, exhausted: n}`.
  """
  @spec recover_orphaned_in_progress() :: %{
          checked: non_neg_integer(),
          recovered: non_neg_integer(),
          skipped: non_neg_integer(),
          exhausted: non_neg_integer()
        }
  def recover_orphaned_in_progress do
    {result, _telemetry} = recover_orphaned_in_progress_with_telemetry()
    result
  end

  @doc false
  @spec recover_orphaned_in_progress_with_telemetry() ::
          {%{
             checked: non_neg_integer(),
             recovered: non_neg_integer(),
             skipped: non_neg_integer(),
             exhausted: non_neg_integer()
           }, %{cases_created: non_neg_integer(), attempts: non_neg_integer()}}
  def recover_orphaned_in_progress_with_telemetry do
    stale_before =
      DateTime.utc_now()
      |> DateTime.add(-@orphan_checkout_grace_seconds, :second)

    in_progress =
      from(i in Issue,
        where:
          i.status == :in_progress and
            fragment("COALESCE(?, ?) < ?", i.checked_out_at, i.updated_at, ^stale_before),
        select: %{id: i.id, assignee_id: i.assignee_id}
      )
      |> Cympho.Repo.all()

    issue_ids = Enum.map(in_progress, & &1.id)
    active_run_issue_ids = issue_ids_with_active_runs(issue_ids)
    existing_sources = recovery_source_keys("issue_checkout")

    {result, telemetry, _seen_sources} =
      Enum.reduce(
        in_progress,
        {%{checked: 0, recovered: 0, skipped: 0, exhausted: 0}, %{cases_created: 0, attempts: 0},
         existing_sources},
        fn %{id: issue_id, assignee_id: assignee_id}, {acc, telemetry, seen_sources} ->
          acc = %{acc | checked: acc.checked + 1}

          cond do
            live_orchestrator?(issue_id) ->
              {Map.update!(acc, :skipped, &(&1 + 1)), telemetry, seen_sources}

            MapSet.member?(active_run_issue_ids, issue_id) ->
              {Map.update!(acc, :skipped, &(&1 + 1)), telemetry, seen_sources}

            true ->
              {status, recovery_case} = reclaim_orphaned_issue_with_case(issue_id, assignee_id)
              acc = update_orphan_result(acc, status)

              {telemetry, seen_sources} =
                update_recovery_telemetry(telemetry, seen_sources, recovery_case)

              {acc, telemetry, seen_sources}
          end
        end
      )

    {result, telemetry}
  rescue
    # Recovery is best-effort; never let a transient DB issue block boot/poll.
    error ->
      Logger.error("[Dispatcher] orphan recovery failed: #{inspect(error)}")
      {%{checked: 0, recovered: 0, skipped: 0, exhausted: 0}, %{cases_created: 0, attempts: 0}}
  end

  defp update_orphan_result(acc, :recovered), do: %{acc | recovered: acc.recovered + 1}
  defp update_orphan_result(acc, :exhausted), do: %{acc | exhausted: acc.exhausted + 1}
  defp update_orphan_result(acc, _), do: %{acc | skipped: acc.skipped + 1}

  defp reclaim_orphaned_issue_with_case(issue_id, assignee_id) do
    case Issues.get_issue(issue_id) do
      {:ok, %Issue{} = issue} ->
        case Cympho.Recovery.recover_orphaned_issue(issue) do
          {:ok, %{outcome: :recovered, case: recovery_case}} ->
            Logger.warning(
              "[Dispatcher] recovered orphaned issue #{issue_id} (assignee=#{assignee_id || "none"}) → :todo"
            )

            {:recovered, recovery_case}

          {:ok, %{outcome: :exhausted, case: recovery_case}} ->
            {:exhausted, recovery_case}

          {:ok, %{outcome: _outcome, case: recovery_case}} ->
            {:skipped, recovery_case}

          {:error, reason} ->
            Logger.error(
              "[Dispatcher] failed to release orphaned issue #{issue_id}: #{inspect(reason)}"
            )

            {:skipped, nil}
        end

      _ ->
        {:skipped, nil}
    end
  end

  defp recovery_source_keys(source_type) do
    from(c in Cympho.Recovery.RecoveryCase,
      where:
        c.source_type == ^source_type and c.state in ^Cympho.Recovery.RecoveryCase.active_states(),
      select: {c.source_type, c.source_id}
    )
    |> Cympho.Repo.all()
    |> MapSet.new()
  end

  defp update_recovery_telemetry(telemetry, seen_sources, nil), do: {telemetry, seen_sources}

  defp update_recovery_telemetry(telemetry, seen_sources, %{source_type: type, source_id: id}) do
    source = {type, id}
    attempts = telemetry.attempts + 1

    if MapSet.member?(seen_sources, source) do
      {%{telemetry | attempts: attempts}, seen_sources}
    else
      {%{telemetry | attempts: attempts, cases_created: telemetry.cases_created + 1},
       MapSet.put(seen_sources, source)}
    end
  end

  defp live_orchestrator?(issue_id) do
    case Orchestrator.whereis(issue_id) do
      nil -> live_adapter_worker?(issue_id)
      pid -> Process.alive?(pid) or live_adapter_worker?(issue_id)
    end
  end

  defp live_adapter_worker?(issue_id) do
    case Cympho.AdapterSessions.owners_for_issue(issue_id) do
      {:ok, []} -> false
      {:ok, [_ | _]} -> true
      {:error, :not_started} -> true
    end
  end

  defp issue_ids_with_active_runs([]), do: MapSet.new()

  defp issue_ids_with_active_runs(issue_ids) do
    from(r in Run,
      where: r.issue_id in ^issue_ids and r.status in ["pending", "queued", "running"],
      select: r.issue_id,
      distinct: true
    )
    |> Cympho.Repo.all()
    |> MapSet.new()
  end

  @doc """
  Sweeps stale checked-out issues (age threshold) back to `:todo` while
  preserving assignee. Reuses `RuntimeOperations` company-agnostic recovery.
  """
  @spec recover_stale_checkouts() :: %{
          checked: non_neg_integer(),
          released: non_neg_integer(),
          failed: non_neg_integer(),
          exhausted: non_neg_integer()
        }
  def recover_stale_checkouts do
    {result, _telemetry} = recover_stale_checkouts_with_telemetry()
    result
  end

  @doc false
  def recover_stale_checkouts_with_telemetry do
    Cympho.Recovery.recover_stale_checkouts_with_telemetry()
  rescue
    error ->
      Logger.error("[Dispatcher] stale checkout recovery failed: #{inspect(error)}")
      {%{checked: 0, released: 0, failed: 0, exhausted: 0}, %{cases_created: 0, attempts: 0}}
  end

  @impl true
  def handle_call(:running_issue_ids, _from, %State{} = state) do
    {:reply, MapSet.to_list(state.running_issue_ids), state}
  end

  @impl true
  def handle_call(:state, _from, %State{} = state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:stop_company, company_id, reason}, {requester, _tag} = from, %State{} = state) do
    # Backward-compatible message handling for callers that bypass stop_company/2.
    # Cleanup must never execute inside this single global GenServer.
    dispatcher = self()

    {:ok, _pid} =
      Task.start(fn ->
        result = stop_company_runtime(company_id, reason, state.running_issue_ids, requester)
        GenServer.reply(from, {:ok, result})
        send(dispatcher, {:company_stop_finished, result.issue_ids -- result.deferred_issue_ids})
      end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    if enabled?() do
      # `poll_now/0` delivers `:poll` too. Rescheduling unconditionally would
      # start a second self-perpetuating timer chain for every on-demand poll,
      # and `poll_now/0` runs on issue launch, dashboard actions, and event
      # heartbeats — so the poll rate grew without bound over a node's life.
      # schedule_poll/1 cancels the pending timer, leaving exactly one.
      state = state |> do_poll() |> schedule_poll()
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:poll_company, company_id}, %State{} = state) do
    if enabled?() do
      state = do_poll(state, company_id)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:session_ended, issue_id, _reason}, %State{} = state) do
    running_issue_ids =
      if live_orchestrator?(issue_id),
        do: MapSet.put(state.running_issue_ids, issue_id),
        else: MapSet.delete(state.running_issue_ids, issue_id)

    new_state = %{state | running_issue_ids: running_issue_ids}
    {:noreply, new_state}
  end

  def handle_info({:company_stop_finished, issue_ids}, %State{} = state)
      when is_list(issue_ids) do
    removable_issue_ids =
      Enum.reject(issue_ids, fn issue_id ->
        live_orchestrator?(issue_id) or adapter_cleanup_pending?(state.monitors, issue_id)
      end)

    new_state = %{
      state
      | running_issue_ids:
          MapSet.difference(state.running_issue_ids, MapSet.new(removable_issue_ids))
    }

    {:noreply, new_state}
  end

  def handle_info({:defer_adapter_cleanup, issue_id, worker_pid, reason}, %State{} = state)
      when is_binary(issue_id) and is_pid(worker_pid) do
    {:noreply, monitor_adapter_workers(state, issue_id, [worker_pid], reason, :stop)}
  end

  def handle_info({:retry_issue_cleanup, issue_id, reason}, %State{} = state) do
    case Cympho.AdapterSessions.cancel_for_issue(issue_id, reason) do
      {:ok, []} ->
        case safe_stop_issue_for_retry(issue_id, reason) do
          {:ok, %{deferred_issue_ids: deferred}} ->
            running_issue_ids =
              if issue_id in deferred,
                do: MapSet.put(state.running_issue_ids, issue_id),
                else: MapSet.delete(state.running_issue_ids, issue_id)

            {:noreply, %{state | running_issue_ids: running_issue_ids}}

          {:error, :retry} ->
            Process.send_after(
              self(),
              {:retry_issue_cleanup, issue_id, reason},
              @adapter_ledger_retry_ms
            )

            {:noreply,
             %{state | running_issue_ids: MapSet.put(state.running_issue_ids, issue_id)}}

          _completed ->
            {:noreply,
             %{state | running_issue_ids: MapSet.delete(state.running_issue_ids, issue_id)}}
        end

      {:ok, workers} ->
        {:noreply, monitor_adapter_workers(state, issue_id, workers, reason, :stop)}

      {:error, :not_started} ->
        Process.send_after(
          self(),
          {:retry_issue_cleanup, issue_id, reason},
          @adapter_ledger_retry_ms
        )

        {:noreply, %{state | running_issue_ids: MapSet.put(state.running_issue_ids, issue_id)}}
    end
  end

  def handle_info({:retry_controller_cleanup, issue_id, controller_pid, reason}, %State{} = state) do
    case Cympho.AdapterSessions.owners_for_controller(controller_pid) do
      {:ok, []} ->
        if live_orchestrator?(issue_id) do
          {:noreply, %{state | running_issue_ids: MapSet.put(state.running_issue_ids, issue_id)}}
        else
          unless graceful_down_reason?(reason),
            do: release_crashed_session_issue(issue_id, reason)

          {:noreply,
           %{state | running_issue_ids: MapSet.delete(state.running_issue_ids, issue_id)}}
        end

      {:ok, workers} ->
        action = if(graceful_down_reason?(reason), do: :stop, else: :crash)
        {:noreply, monitor_adapter_workers(state, issue_id, workers, reason, action)}

      {:error, :not_started} ->
        Process.send_after(
          self(),
          {:retry_controller_cleanup, issue_id, controller_pid, reason},
          @adapter_ledger_retry_ms
        )

        {:noreply, %{state | running_issue_ids: MapSet.put(state.running_issue_ids, issue_id)}}
    end
  end

  # Orchestrator process went down. Normal terminations already sent
  # :session_ended from terminate/2; this covers brutal kills (exit signals
  # that skip terminate) so the concurrency slot is freed and a stranded
  # :in_progress issue is released for re-dispatch instead of waiting for
  # the next watchdog sweep.
  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, %State{} = state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {{:adapter_cleanup, issue_id, orchestrator_reason, action}, monitors} ->
        if adapter_cleanup_pending?(monitors, issue_id) do
          {:noreply, %{state | monitors: monitors}}
        else
          finish_adapter_cleanup(state, monitors, issue_id, orchestrator_reason, action)
        end

      {issue_id, monitors} ->
        state = %{state | monitors: monitors}

        case Cympho.AdapterSessions.owners_for_controller(pid) do
          {:ok, [_ | _] = workers} ->
            action = if(graceful_down_reason?(reason), do: :stop, else: :crash)
            {:noreply, monitor_adapter_workers(state, issue_id, workers, reason, action)}

          {:ok, []} ->
            if live_orchestrator?(issue_id) do
              {:noreply,
               %{state | running_issue_ids: MapSet.put(state.running_issue_ids, issue_id)}}
            else
              unless graceful_down_reason?(reason) do
                release_crashed_session_issue(issue_id, reason)
              end

              {:noreply,
               %{state | running_issue_ids: MapSet.delete(state.running_issue_ids, issue_id)}}
            end

          {:error, :not_started} ->
            Process.send_after(
              self(),
              {:retry_controller_cleanup, issue_id, pid, reason},
              @adapter_ledger_retry_ms
            )

            {:noreply,
             %{state | running_issue_ids: MapSet.put(state.running_issue_ids, issue_id)}}
        end
    end
  end

  @impl true
  def handle_info({:EXIT, _from, _reason}, %State{} = state) do
    {:noreply, state}
  end

  # Orchestrators are deliberately unlinked and may register a worker at any
  # point while this process terminates. There is no atomic snapshot spanning
  # the Orchestrator registry, adapter ledger, and database, so releasing here
  # has an unavoidable check/use race. Fail closed and let the replacement
  # Dispatcher's authoritative boot reconciliation release only proven orphans.
  @impl true
  def terminate(reason, %State{running_issue_ids: running}) do
    Logger.info(
      "[Dispatcher] terminating (reason=#{inspect(reason)}); preserving #{MapSet.size(running)} in-flight issue fence(s) for restart reconciliation"
    )

    :ok
  end

  # Internal

  # Keeps exactly one pending periodic poll, cancelling any timer already
  # armed. Stale `:poll` messages already in the mailbox are harmless: each one
  # just polls and re-arms this same single timer.
  defp schedule_poll(%State{} = state) do
    if is_reference(state.poll_timer), do: Process.cancel_timer(state.poll_timer)
    %{state | poll_timer: Process.send_after(self(), :poll, @poll_interval)}
  end

  # Reasons where terminate/2 ran (or nothing abnormal happened), so the
  # orchestrator already finalized its run and released its checkout. The
  # runtime-stop shapes come from `Orchestrator.stop/2` callers, which go
  # through GenServer.stop and therefore always run terminate/2.
  defp graceful_down_reason?(:normal), do: true
  defp graceful_down_reason?(:shutdown), do: true
  defp graceful_down_reason?({:shutdown, _detail}), do: true
  defp graceful_down_reason?({:runtime_stop, _detail}), do: true
  defp graceful_down_reason?(:operator_stop), do: true
  defp graceful_down_reason?(:issue_terminal), do: true
  defp graceful_down_reason?(:issue_deleted), do: true
  defp graceful_down_reason?(_reason), do: false

  defp monitor_adapter_workers(state, issue_id, workers, reason, action) do
    {reason, action} = cleanup_precedence(state.monitors, issue_id, reason, action)

    monitors =
      Enum.into(state.monitors, %{}, fn
        {ref, {:adapter_cleanup, ^issue_id, _old_reason, _old_action}} ->
          {ref, {:adapter_cleanup, issue_id, reason, action}}

        entry ->
          entry
      end)

    monitors =
      workers
      |> Enum.uniq()
      |> Enum.reduce(monitors, fn worker, monitors ->
        Map.put(monitors, Process.monitor(worker), {:adapter_cleanup, issue_id, reason, action})
      end)

    %{
      state
      | running_issue_ids: MapSet.put(state.running_issue_ids, issue_id),
        monitors: monitors
    }
  end

  defp cleanup_precedence(monitors, issue_id, reason, :crash) do
    Enum.find_value(monitors, {reason, :crash}, fn
      {_ref, {:adapter_cleanup, ^issue_id, stop_reason, :stop}} -> {stop_reason, :stop}
      _ -> nil
    end)
  end

  defp cleanup_precedence(_monitors, _issue_id, reason, :stop), do: {reason, :stop}

  defp adapter_cleanup_pending?(monitors, issue_id) do
    Enum.any?(monitors, fn
      {_ref, {:adapter_cleanup, ^issue_id, _reason, _action}} -> true
      _ -> false
    end)
  end

  defp finish_adapter_cleanup(state, monitors, issue_id, reason, :stop) do
    case safe_stop_issue_for_retry(issue_id, reason) do
      {:ok, %{deferred_issue_ids: deferred}} ->
        running_issue_ids =
          if issue_id in deferred,
            do: MapSet.put(state.running_issue_ids, issue_id),
            else: MapSet.delete(state.running_issue_ids, issue_id)

        {:noreply, %{state | monitors: monitors, running_issue_ids: running_issue_ids}}

      {:error, :retry} ->
        Process.send_after(
          self(),
          {:retry_issue_cleanup, issue_id, reason},
          @adapter_ledger_retry_ms
        )

        {:noreply,
         %{
           state
           | monitors: monitors,
             running_issue_ids: MapSet.put(state.running_issue_ids, issue_id)
         }}

      _completed ->
        {:noreply,
         %{
           state
           | monitors: monitors,
             running_issue_ids: MapSet.delete(state.running_issue_ids, issue_id)
         }}
    end
  end

  defp finish_adapter_cleanup(state, monitors, issue_id, reason, :crash) do
    release_crashed_session_issue(issue_id, reason)

    running_issue_ids =
      if live_orchestrator?(issue_id),
        do: MapSet.put(state.running_issue_ids, issue_id),
        else: MapSet.delete(state.running_issue_ids, issue_id)

    {:noreply,
     %{
       state
       | monitors: monitors,
         running_issue_ids: running_issue_ids
     }}
  end

  defp safe_stop_issue_for_retry(issue_id, reason) do
    stop_issue(issue_id, reason)
  rescue
    error ->
      Logger.warning("[Dispatcher] deferred issue cleanup will retry",
        component: "dispatcher",
        issue_id: issue_id,
        error: Exception.message(error)
      )

      {:error, :retry}
  catch
    :exit, exit_reason ->
      Logger.warning("[Dispatcher] deferred issue cleanup exited and will retry",
        component: "dispatcher",
        issue_id: issue_id,
        error: inspect(exit_reason)
      )

      {:error, :retry}
  end

  defp release_crashed_session_issue(issue_id, reason) do
    Logger.warning(
      "[Dispatcher] orchestrator for issue #{issue_id} went down (#{inspect(reason)}); checking for stranded checkout"
    )

    # Only clean up when the crashed session actually stranded the issue —
    # a replacement orchestrator means someone else owns it now. Registry
    # cleanup is async relative to our DOWN message, so a still-listed-but-
    # dead pid counts as "no orchestrator".
    if live_orchestrator?(issue_id) do
      :ok
    else
      # Snapshot active runs once. Never call cancel_active_runs_for_issue —
      # that terminalizes *every* active run for the issue (including a
      # successor that raced in after the first live check) and can unlock a
      # successor-bound checkout via clear_checkout_lock_for_run.
      pre_crash_runs = active_runs_for_issue(issue_id)

      # Unbound stranded checkout only. A bound checkout_run_id may be a
      # successor that claimed ownership before this DOWN handler ran — a
      # fresh clear_checkout_lock would load that bind and wipe it. Bound
      # dead-session runs are terminalized by recover_orphaned_runs (poll/boot)
      # which clears via clear_checkout_lock_for_run.
      unless live_orchestrator?(issue_id) do
        case Issues.get_issue(issue_id) do
          {:ok, %Issue{status: :in_progress, checkout_run_id: nil} = issue} ->
            case Issues.clear_checkout_lock(issue, :todo) do
              {:ok, _released} ->
                Logger.warning(
                  "[Dispatcher] released issue #{issue_id} after orchestrator crash (assignee preserved)"
                )

              {:error, :checkout_conflict} ->
                Logger.info(
                  "[Dispatcher] skipped crash release for issue #{issue_id}: checkout already claimed by successor"
                )

              {:error, release_reason} ->
                Logger.error(
                  "[Dispatcher] failed to release issue #{issue_id} after orchestrator crash: #{inspect(release_reason)}"
                )
            end

          {:ok, %Issue{status: :in_progress, checkout_run_id: bound}} when is_binary(bound) ->
            Logger.info(
              "[Dispatcher] skipped crash checkout clear for issue #{issue_id}: run #{bound} still bound (successor or in-flight session)"
            )

          _ ->
            :ok
        end
      end

      # Recover only runs that cannot belong to a successor: re-check live orch
      # before each cancel, and never terminalize the currently-bound checkout
      # run (cancel_run → clear_checkout_lock_for_run would unlock it).
      Enum.each(pre_crash_runs, fn run ->
        recover_crashed_session_run(issue_id, run)
      end)
    end
  rescue
    error ->
      Logger.error("[Dispatcher] crash-release failed for issue #{issue_id}: #{inspect(error)}")

      :ok
  end

  defp recover_crashed_session_run(issue_id, run) do
    cond do
      live_orchestrator?(issue_id) ->
        :ok

      current_checkout_run?(issue_id, run) ->
        :ok

      true ->
        case Cympho.Recovery.recover_orphaned_run(run) do
          {:ok, %{run: recovered, outcome: :recovered}} ->
            Logger.warning(
              "[Dispatcher] recovered crashed-session run #{run.id} (issue=#{issue_id}) → #{recovered.status}"
            )

          {:ok, %{outcome: :superseded}} ->
            Logger.info("[Dispatcher] crashed-session run #{run.id} superseded before recovery")

          {:ok, %{outcome: outcome}} when outcome in [:scheduled, :exhausted] ->
            Logger.info("[Dispatcher] crashed-session run #{run.id} recovery #{outcome}")

          {:error, :company_scope_required} ->
            Logger.warning(
              "[Dispatcher] skipped crashed-session run #{run.id} due to company scope validation"
            )

          {:error, recover_reason} ->
            Logger.error(
              "[Dispatcher] failed to recover crashed-session run #{run.id}: #{inspect(recover_reason)}"
            )
        end
    end
  end

  defp current_checkout_run?(issue_id, run) do
    case Issues.get_issue(issue_id) do
      {:ok, %Issue{checkout_run_id: bound}} when is_binary(bound) and bound == run.id ->
        true

      _ ->
        false
    end
  end

  defp active_runs_for_issue(issue_id) when is_binary(issue_id) do
    from(r in Run,
      where: r.issue_id == ^issue_id and r.status in ["pending", "queued", "running"],
      order_by: [asc: r.inserted_at]
    )
    |> Cympho.Repo.all()
  end

  defp active_runs_for_issue(_issue_id), do: []

  defp stop_company_runtime(company_id, reason, running_issue_ids, requester \\ self()) do
    issues = company_runtime_issues(company_id, running_issue_ids)
    deadline_ms = company_stop_deadline_ms()

    task =
      Task.async(fn ->
        stop_runtime_issues_parallel(issues, reason, requester, deadline_ms)
      end)

    # The task is monitored by Task.yield/2; unlink it so an unexpected worker
    # failure cannot take down an orchestrator caller or runtime-control request.
    Process.unlink(task.pid)

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, exit_reason} ->
        defer_company_stop_retry(issues, reason, requester)
        |> add_stop_error(nil, {:company_stop_worker_failed, exit_reason})

      nil ->
        defer_company_stop_retry(issues, reason, requester)
        |> add_stop_error(nil, {:company_stop_deadline_exceeded, deadline_ms})
    end
  end

  defp stop_runtime_issues_parallel([], reason, requester, _deadline_ms),
    do: empty_stop_result(reason, requester)

  defp stop_runtime_issues_parallel(issues, reason, requester, deadline_ms) do
    max_concurrency = min(length(issues), company_stop_max_concurrency())

    issues
    |> Task.async_stream(
      fn issue -> stop_runtime_issue(issue, empty_stop_result(reason, requester)) end,
      max_concurrency: max_concurrency,
      ordered: true,
      timeout: deadline_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce(empty_stop_result(reason, requester), fn
      {:ok, result}, acc -> merge_stop_results(acc, result)
      {:exit, task_reason}, acc -> add_stop_error(acc, nil, {:issue_stop_failed, task_reason})
    end)
  end

  defp defer_company_stop_retry(issues, reason, requester) do
    issue_ids = Enum.map(issues, & &1.id)

    if dispatcher = Process.whereis(__MODULE__) do
      Enum.each(issue_ids, &send(dispatcher, {:retry_issue_cleanup, &1, reason}))
    end

    %{
      empty_stop_result(reason, requester)
      | issue_ids: issue_ids,
        deferred_issue_ids: issue_ids
    }
  end

  defp company_stop_deadline_ms do
    :cympho
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get(:company_stop_deadline_ms, @default_company_stop_deadline_ms)
    |> positive_integer_or(@default_company_stop_deadline_ms)
  end

  defp company_stop_max_concurrency do
    :cympho
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get(:company_stop_max_concurrency, @default_company_stop_max_concurrency)
    |> positive_integer_or(@default_company_stop_max_concurrency)
  end

  defp positive_integer_or(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer_or(_value, default), do: default

  defp merge_stop_results(acc, result) do
    numeric_keys = [
      :orchestrators_stopped,
      :adapter_sessions_cancel_requested,
      :adapter_sessions_cancel_confirmed,
      :adapter_sessions_still_registered,
      :issues_released,
      :runs_cancelled,
      :agents_idled
    ]

    acc =
      Enum.reduce(numeric_keys, acc, fn key, merged ->
        Map.update!(merged, key, &(&1 + Map.fetch!(result, key)))
      end)

    %{
      acc
      | issue_ids: acc.issue_ids ++ result.issue_ids,
        deferred_issue_ids: acc.deferred_issue_ids ++ result.deferred_issue_ids,
        errors: acc.errors ++ result.errors
    }
  end

  defp dispatcher_running_issue_ids(pid) do
    pid
    |> GenServer.call(:running_issue_ids, @dispatcher_snapshot_timeout_ms)
    |> MapSet.new()
  catch
    :exit, reason ->
      Logger.warning("[Dispatcher] could not snapshot running issues before company stop",
        component: "dispatcher",
        error: inspect(reason)
      )

      MapSet.new()
  end

  # `requester` is the process that asked for the stop. When it turns out to be
  # one of the orchestrators being stopped, that orchestrator is blocked waiting
  # on this very call and must be signalled asynchronously instead.
  defp empty_stop_result(reason, requester \\ self()) do
    %{
      reason: to_string(reason),
      requester: requester,
      issue_ids: [],
      orchestrators_stopped: 0,
      adapter_sessions_cancel_requested: 0,
      adapter_sessions_cancel_confirmed: 0,
      adapter_sessions_still_registered: 0,
      issues_released: 0,
      runs_cancelled: 0,
      agents_idled: 0,
      errors: [],
      deferred_issue_ids: []
    }
  end

  defp company_runtime_issues(company_id, running_issue_ids) do
    tracked_ids = MapSet.to_list(running_issue_ids)

    query =
      case tracked_ids do
        [] ->
          from i in Issue,
            where: i.company_id == ^company_id and i.status == ^:in_progress,
            order_by: [asc: i.updated_at, asc: i.id]

        ids ->
          from i in Issue,
            where: i.company_id == ^company_id and (i.status == ^:in_progress or i.id in ^ids),
            order_by: [asc: i.updated_at, asc: i.id]
      end

    Cympho.Repo.all(query)
  end

  defp issue_runtime_issues(issue_id) do
    Cympho.Repo.all(
      from i in Issue,
        where: i.id == ^issue_id,
        order_by: [asc: i.updated_at, asc: i.id]
    )
  end

  defp stop_runtime_issue(%Issue{} = issue, acc) do
    acc =
      acc
      |> track_issue(issue.id)
      |> maybe_stop_orchestrator(issue.id, {:runtime_stop, acc.reason})

    acc =
      if issue.id not in acc.deferred_issue_ids do
        defer_issue_adapter_workers(acc, issue.id, {:runtime_stop, acc.reason})
      else
        acc
      end

    if issue.id in acc.deferred_issue_ids do
      acc
    else
      acc
      |> maybe_release_issue(issue)
      |> cancel_issue_runs(issue.id)
      |> release_issue_environment(issue)
      |> idle_agent(issue.assignee_id)
    end
  end

  defp release_issue_environment(acc, %Issue{} = issue) do
    _ =
      Workspaces.cancel_and_release_for_issue(issue, %{
        reason: "dispatcher_stop_#{acc.reason}",
        company_id: issue.company_id
      })

    acc
  rescue
    error ->
      Logger.warning(
        "[Dispatcher] environment cancel/release failed during issue stop",
        component: "dispatcher",
        issue_id: issue.id,
        company_id: issue.company_id,
        error: Exception.message(error)
      )

      acc
  end

  defp track_issue(acc, issue_id), do: %{acc | issue_ids: [issue_id | acc.issue_ids]}

  defp maybe_stop_orchestrator(acc, issue_id, reason) do
    case Orchestrator.whereis(issue_id) do
      nil ->
        acc

      pid when pid == acc.requester ->
        # Re-entrant stop. A budget hard-stop is recorded at the end of an agent
        # turn, inside the orchestrator process, and reaches
        # `Companies.stop_company_runtime/2` → `Dispatcher.stop_company/2`. Stopping
        # that orchestrator synchronously here would block the global Dispatcher
        # against the very process waiting on it: `get_session_state/1` burns its
        # 5s timeout, `GenServer.stop/2` waits `:infinity`, and every other tenant's
        # dispatch stalls until the caller's own 15s timeout fires. The
        # orchestrator handles `{:stop_orchestrator, reason}` as soon as its call
        # returns, which is the same shutdown path with no mutual wait.
        send(pid, {:stop_orchestrator, reason})

        acc
        |> Map.update!(:orchestrators_stopped, &(&1 + 1))
        |> defer_issue_adapter_workers(issue_id, reason)

      _pid ->
        session_id = issue_id |> Orchestrator.get_session_state() |> adapter_session_id()
        registered_before_stop? = adapter_session_registered?(session_id)

        try do
          :ok = Orchestrator.stop(issue_id, reason)

          acc =
            acc
            |> Map.update!(:orchestrators_stopped, &(&1 + 1))
            |> record_adapter_session_stop(issue_id, session_id, registered_before_stop?)

          if issue_id in acc.deferred_issue_ids,
            do: acc,
            else: defer_issue_adapter_workers(acc, issue_id, reason)
        catch
          :exit, reason ->
            add_stop_error(acc, issue_id, {:orchestrator_stop_failed, reason})
        end
    end
  end

  defp adapter_session_id(%{session_id: session_id}), do: session_id
  defp adapter_session_id(_state), do: nil

  defp adapter_session_registered?(nil), do: false
  defp adapter_session_registered?(session_id), do: Cympho.AdapterSessions.registered?(session_id)

  defp record_adapter_session_stop(acc, _issue_id, _session_id, false), do: acc

  defp record_adapter_session_stop(acc, issue_id, session_id, true) do
    if adapter_session_cleared?(session_id) do
      acc
      |> Map.update!(:adapter_sessions_cancel_requested, &(&1 + 1))
      |> Map.update!(:adapter_sessions_cancel_confirmed, &(&1 + 1))
    else
      defer_issue_adapter_workers(acc, issue_id, {:runtime_stop, acc.reason})
      |> add_stop_error(issue_id, {:adapter_session_still_registered, inspect(session_id)})
    end
  end

  defp adapter_session_cleared?(session_id, attempts \\ @adapter_stop_confirm_attempts)

  defp adapter_session_cleared?(session_id, 0),
    do: not Cympho.AdapterSessions.registered?(session_id)

  defp adapter_session_cleared?(session_id, attempts) do
    if Cympho.AdapterSessions.registered?(session_id) do
      Process.sleep(@adapter_stop_confirm_sleep_ms)
      adapter_session_cleared?(session_id, attempts - 1)
    else
      true
    end
  end

  defp maybe_defer_adapter_cleanup_for_worker(issue_id, worker_pid, reason) do
    if dispatcher = Process.whereis(__MODULE__) do
      send(dispatcher, {:defer_adapter_cleanup, issue_id, worker_pid, reason})
    end

    :ok
  end

  defp defer_issue_adapter_workers(acc, issue_id, reason) do
    case Cympho.AdapterSessions.cancel_for_issue(issue_id, reason) do
      {:ok, []} ->
        acc

      {:ok, workers} ->
        Enum.each(workers, &maybe_defer_adapter_cleanup_for_worker(issue_id, &1, reason))

        acc
        |> Map.update!(:adapter_sessions_cancel_requested, &(&1 + length(workers)))
        |> Map.update!(:adapter_sessions_still_registered, &(&1 + length(workers)))
        |> Map.update!(:deferred_issue_ids, fn ids -> Enum.uniq([issue_id | ids]) end)

      {:error, :not_started} ->
        if dispatcher = Process.whereis(__MODULE__) do
          send(dispatcher, {:retry_issue_cleanup, issue_id, reason})
        end

        Map.update!(acc, :deferred_issue_ids, fn ids -> Enum.uniq([issue_id | ids]) end)
    end
  end

  defp maybe_release_issue(acc, %Issue{status: :in_progress} = issue) do
    case Issues.force_release_issue(issue, :todo) do
      {:ok, _updated} ->
        %{acc | issues_released: acc.issues_released + 1}

      {:error, reason} ->
        add_stop_error(acc, issue.id, {:issue_release_failed, reason})
    end
  end

  defp maybe_release_issue(acc, _issue), do: acc

  defp cancel_issue_runs(acc, issue_id) do
    runs =
      Cympho.Repo.all(
        from r in Run,
          where: r.issue_id == ^issue_id and r.status in ["pending", "queued", "running"],
          order_by: [asc: r.inserted_at]
      )

    Enum.reduce(runs, acc, fn run, acc ->
      case HeartbeatEngine.cancel_run(run) do
        {:ok, _updated} ->
          %{acc | runs_cancelled: acc.runs_cancelled + 1}

        {:error, reason} ->
          add_stop_error(acc, issue_id, {:run_cancel_failed, run.id, reason})
      end
    end)
  end

  defp idle_agent(acc, nil), do: acc

  defp idle_agent(acc, agent_id) do
    case Agents.get_agent(agent_id) do
      {:ok, %{status: :terminated}} ->
        acc

      {:ok, agent} ->
        case Agents.update_agent(agent, %{status: :idle}) do
          {:ok, _updated} -> %{acc | agents_idled: acc.agents_idled + 1}
          {:error, reason} -> add_stop_error(acc, nil, {:agent_idle_failed, agent_id, reason})
        end

      {:error, reason} ->
        add_stop_error(acc, nil, {:agent_lookup_failed, agent_id, reason})
    end
  end

  defp add_stop_error(acc, issue_id, reason) do
    error = %{issue_id: issue_id, reason: inspect(reason)}
    %{acc | errors: [error | acc.errors]}
  end

  defp do_poll(%State{} = state, company_id \\ nil) do
    # Periodic reclaim: boot-only recovery left live-node strands until restart.
    # Same helpers the watchdog tick / handle_continue(:recover_orphans) use so
    # either cadence covers the other — including zombie runs that pin issues
    # out of reclaim when recover_orphaned_runs is skipped.
    recover_orphaned_runs()
    _ = recover_orphaned_in_progress()
    _ = recover_stale_checkouts()

    state
    |> prune_stale_retries()
    |> reconcile_running()
    |> fetch_and_dispatch(company_id)
  end

  # Retry entries are deleted on successful dispatch, but issues that get
  # cancelled/completed/deleted while backing off would leave their entries
  # in the map forever. An entry whose retry window elapsed more than two
  # max-backoff periods ago means the issue stopped being a candidate —
  # drop it. If it becomes runnable again it simply restarts at attempt 1.
  defp prune_stale_retries(%State{retry_attempts: retries} = state)
       when map_size(retries) == 0,
       do: state

  defp prune_stale_retries(%State{retry_attempts: retries} = state) do
    cutoff = :os.system_time(:millisecond) - 2 * @max_backoff_ms

    %{
      state
      | retry_attempts: Map.filter(retries, fn {_id, entry} -> entry.next_retry_at > cutoff end)
    }
  end

  defp reconcile_running(%State{running_issue_ids: running} = state) do
    if MapSet.size(running) == 0 do
      state
    else
      do_reconcile_running(state)
    end
  end

  defp do_reconcile_running(%State{running_issue_ids: running} = state) do
    # One lightweight id-only query instead of a fully-preloaded get_issue
    # per running issue per poll.
    stopped_ids =
      Cympho.Repo.all(
        from i in Issue,
          where: i.id in ^MapSet.to_list(running) and i.status in ^@terminal_states,
          select: i.id
      )

    Enum.each(stopped_ids, &Orchestrator.stop(&1, :issue_terminal))

    case stopped_ids do
      [] ->
        state

      ids ->
        new_running = MapSet.difference(state.running_issue_ids, MapSet.new(ids))
        %{state | running_issue_ids: new_running}
    end
  end

  defp fetch_and_dispatch(
         %State{running_issue_ids: running, retry_attempts: retries} = state,
         company_id
       ) do
    available_slots = max_concurrent() - MapSet.size(running)

    if available_slots <= 0 do
      state
    else
      candidates = fetch_candidate_issues(available_slots * 4, company_id, state.poll_cursor)
      state = %{state | poll_cursor: state.poll_cursor + 1}
      now = :os.system_time(:millisecond)

      # Per-company cap: count how many running issues belong to each
      # company, then drop candidates whose company has hit its
      # `max_concurrent_runs` limit. The count is updated as dispatches
      # succeed within this poll so a single poll cannot burst a company past
      # its cap.
      running_by_company = running_issues_by_company(running)

      ready_candidates =
        Enum.reject(candidates, fn issue ->
          MapSet.member?(running, issue.id) ||
            (retries[issue.id] && retries[issue.id].next_retry_at > now)
        end)

      {state, _by_company, _slots} =
        Enum.reduce_while(
          ready_candidates,
          {state, running_by_company, available_slots},
          fn
            _issue, {state, by_co, 0} ->
              {:halt, {state, by_co, 0}}

            issue, {state, by_co, slots} ->
              if company_at_capacity?(issue, by_co) do
                {:cont, {state, by_co, slots}}
              else
                new_state = dispatch_issue(issue, state)

                if MapSet.member?(new_state.running_issue_ids, issue.id) do
                  {:cont,
                   {new_state, Map.update(by_co, issue.company_id, 1, &(&1 + 1)), slots - 1}}
                else
                  {:cont, {new_state, by_co, slots}}
                end
              end
          end
        )

      state
    end
  end

  defp running_issues_by_company(running_set) do
    case MapSet.to_list(running_set) do
      [] ->
        %{}

      ids ->
        Cympho.Repo.all(
          from i in Cympho.Issues.Issue,
            where: i.id in ^ids and not is_nil(i.company_id),
            group_by: i.company_id,
            select: {i.company_id, count(i.id)}
        )
        |> Map.new()
    end
  end

  defp company_at_capacity?(%Cympho.Issues.Issue{company_id: nil}, _by_co), do: false

  defp company_at_capacity?(%Cympho.Issues.Issue{company_id: company_id}, by_co) do
    cap = Cympho.Companies.runtime_limit(company_id, "max_concurrent_runs", default_company_cap())
    Map.get(by_co, company_id, 0) >= cap
  end

  # The per-company default used to be the *global* cap, which made the check
  # dead code: fetch_and_dispatch/2 returns early once no slots remain, so a
  # company could never be seen holding all of them while candidates were still
  # being considered. Half the global cap leaves room for a second tenant by
  # default, and a company can still be given a different limit through its
  # governance config.
  defp default_company_cap do
    max(1, div(max_concurrent(), 2))
  end

  # How many candidates one company may contribute to a poll's window.
  defp per_company_window(limit), do: max(1, div(limit, 3))

  @doc """
  Maximum concurrent agent sessions this node will dispatch.

  Reads `config :cympho, :orchestrator, max_concurrent_agents: n` at runtime.
  With nothing configured it scales with the schedulers actually available
  rather than sitting at a compiled-in 3 for every install: agent runs spend
  their time waiting on an external CLI or API, not on CPU, so the useful
  number is a small multiple of the scheduler count.
  """
  def max_concurrent do
    :cympho
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get(:max_concurrent_agents)
    |> case do
      value when is_integer(value) and value > 0 -> value
      _ -> default_max_concurrent()
    end
  end

  defp default_max_concurrent do
    schedulers = :erlang.system_info(:schedulers_online)
    min(max(schedulers * 2, 4), 32)
  end

  # Runnability — issue-level runtime pause, an unresolved blocker, low-power
  # mode — cannot be expressed in the SQL where clause, so it is filtered in
  # Elixir after the LIMIT. Fetching a single page therefore lets non-runnable
  # issues at the head of the *global* priority order starve dispatch for every
  # tenant, indefinitely: nothing clears a runtime pause on a timer, and a
  # budget hard stop sets that flag automatically, so this is not only operator
  # error. Walking a bounded number of pages makes a run of non-runnable issues
  # cost a few more rows instead of all dispatch.
  @candidate_pages 5

  # How many tenants one global poll will look at. Bounded so a large install
  # does not run a query per company on every tick; the rotation cursor makes
  # sure the ones skipped this poll lead the next one.
  @companies_per_poll 25

  # A company-scoped poll has one tenant by definition, so it keeps the plain
  # globally-ordered scan.
  defp fetch_candidate_issues(limit, company_id, _cursor) when is_binary(company_id) do
    fetch_runnable(candidate_query(company_id), limit)
  end

  # Candidates were selected from one globally priority-ordered window. A tenant
  # holding the top rows of that window starved every other tenant outright:
  # nobody else's issues were even loaded, so rejecting the busy tenant's
  # candidates admitted no one and the slots went unused. Companies are now
  # discovered independently of that order and drawn from round-robin, so one
  # backlog cannot consume the window. Priority order is preserved *within* a
  # company; across companies the policy is fair share, which is the point.
  defp fetch_candidate_issues(limit, nil, cursor) do
    per_company = per_company_window(limit)

    limit
    |> candidate_company_ids(cursor)
    |> Enum.map(fn company_id ->
      fetch_runnable(candidate_query(company_id), per_company)
    end)
    |> interleave()
    |> Enum.take(limit)
  end

  defp fetch_runnable(query, limit) do
    Enum.reduce_while(0..(@candidate_pages - 1), [], fn page, acc ->
      rows =
        query
        |> limit(^limit)
        |> offset(^(page * limit))
        |> Cympho.Repo.all()

      runnable =
        (acc ++ Enum.filter(rows, &runnable_candidate?/1))
        |> Enum.uniq_by(& &1.id)

      cond do
        # Enough to fill the slots this poll can use.
        length(runnable) >= limit -> {:halt, Enum.take(runnable, limit)}
        # Short page means the candidate set is exhausted.
        length(rows) < limit -> {:halt, runnable}
        true -> {:cont, runnable}
      end
    end)
  end

  # Every company with work that could dispatch, found without consulting the
  # global priority order. Ordered by id and rotated by a per-poll cursor so a
  # bounded slice still gives every tenant a turn.
  defp candidate_company_ids(limit, cursor) do
    ids =
      candidate_query(nil)
      |> exclude(:preload)
      |> exclude(:order_by)
      |> distinct(true)
      |> select([i], i.company_id)
      |> order_by([i], asc: i.company_id)
      |> Cympho.Repo.all()

    ids
    |> rotate(cursor)
    |> Enum.take(max(@companies_per_poll, limit))
  end

  defp rotate([], _cursor), do: []

  defp rotate(list, cursor) do
    offset = rem(cursor, length(list))
    Enum.drop(list, offset) ++ Enum.take(list, offset)
  end

  # Round-robin so the dispatch reduce alternates tenants instead of spending
  # every slot on whichever company happened to sort first.
  defp interleave(groups) do
    groups = Enum.reject(groups, &(&1 == []))

    case groups do
      [] ->
        []

      _ ->
        heads = Enum.map(groups, &hd/1)
        tails = groups |> Enum.map(&tl/1) |> Enum.reject(&(&1 == []))
        heads ++ interleave(tails)
    end
  end

  defp candidate_query(company_id) do
    active_states = @active_states

    query =
      from i in Cympho.Issues.Issue,
        as: :issue,
        left_join: c in Company,
        on: c.id == i.company_id,
        where:
          i.status in ^active_states or
            (i.status == ^:blocked and
               exists(
                 from w in AgentWake,
                   where:
                     w.issue_id == parent_as(:issue).id and
                       w.status == "pending" and
                       w.reason in ^["escalation_from_subordinate", "issue_children_completed"]
               )),
        where: not is_nil(i.company_id) and c.status == "active"

    query =
      if company_id do
        where(query, [i, _c], i.company_id == ^company_id)
      else
        query
      end

    query =
      case dispatch_only_issue_id() do
        issue_id when is_binary(issue_id) and issue_id != "" ->
          where(query, [i, _c], i.id == ^issue_id)

        _ ->
          query
      end

    query
    |> preload([:blocked_by, :assignee, :company])
    |> Issues.order_for_dispatch()
  end

  # Unscoped issues are never dispatchable (fail-closed tenancy).
  defp runtime_mode_allows_issue?(%Issue{company_id: nil}), do: false

  defp runtime_mode_allows_issue?(%Issue{company: %Company{} = company, priority: priority}) do
    not Companies.low_power?(company) or priority in @low_power_priorities
  end

  defp runtime_mode_allows_issue?(%Issue{company_id: company_id}) when is_binary(company_id),
    do: true

  defp runtime_mode_allows_issue?(_issue), do: false

  # Blocked issues are only dispatcher-eligible when a resume wake is pending
  # (escalation to a manager, or children-completed after soft-park).
  # Do not include runtime_retry here — those issues are released to :todo.
  defp pending_blocked_resume_wake?(issue_id) when is_binary(issue_id) do
    Cympho.Repo.exists?(
      from w in AgentWake,
        where:
          w.issue_id == ^issue_id and
            w.status == "pending" and
            w.reason in ^["escalation_from_subordinate", "issue_children_completed"]
    )
  end

  defp pending_blocked_resume_wake?(_issue_id), do: false

  defp dispatch_only_issue_id do
    :cympho
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get(:only_issue_id)
  end

  # Anything older than this with an `assigned_role` is a stalled wakeup —
  # the wakeup queue should have caused us to pick it up far sooner.
  @stalled_wakeup_threshold_ms 60_000

  defp dispatch_issue(%Cympho.Issues.Issue{} = issue, %State{} = state) do
    if MapSet.member?(state.running_issue_ids, issue.id) do
      state
    else
      maybe_emit_stalled_wakeup(issue)

      case agent_for_issue(issue) do
        {:ok, agent} ->
          required_role = Router.infer_role(issue)

          case Runtime.dispatchable?(issue, agent) do
            :ok ->
              checkout_and_start(issue, agent, required_role, state)

            {:error, reason} ->
              Logger.warning(
                "[Dispatcher] Runtime preflight blocked issue #{issue.id}: #{inspect(reason)}"
              )

              record_dispatch_failure(issue, state, {:preflight_failed, reason})
          end

        {:error, :no_agent_available} ->
          Logger.info("[Dispatcher] No eligible agent available for issue #{issue.id}")
          record_dispatch_failure(issue, state, :no_agent)
      end
    end
  end

  defp checkout_and_start(issue, agent, required_role, %State{} = state) do
    case Issues.checkout_issue(issue, agent, required_role) do
      {:ok, checked_out} ->
        case Orchestrator.start_and_run(checked_out, agent.id) do
          {:ok, pid} ->
            # Monitor the orchestrator so a brutal kill (which skips
            # terminate/2 and therefore never sends :session_ended) still
            # frees the concurrency slot and releases the issue.
            ref = Process.monitor(pid)
            Cympho.Telemetry.dispatch_started(checked_out, agent.id, required_role)
            # Bind stamp: roster last_heartbeat_at must advance on real
            # dispatch, not only on PATCH status.
            _ = Agents.touch_heartbeat(agent)

            %{
              state
              | running_issue_ids: MapSet.put(state.running_issue_ids, issue.id),
                retry_attempts: Map.delete(state.retry_attempts, issue.id),
                monitors: Map.put(state.monitors, ref, issue.id)
            }

          {:error, reason} ->
            Logger.warning(
              "[Dispatcher] Failed to start orchestrator for issue #{issue.id}: #{inspect(reason)}"
            )

            # Undo only the checkout snapshot we started from. Orchestrator
            # creation can lose a checkout_run_id bind race after another run
            # has become the legitimate owner; unconditional release here
            # would clear that successor's lock and double-dispatch the issue.
            _ = Issues.release_unbound_checkout(checked_out, :todo)

            record_dispatch_failure(issue, state, :orchestrator_start_failed)
        end

      {:error, :already_assigned} ->
        Logger.info(
          "[Dispatcher] Issue #{issue.id} already assigned by another process (race condition handled)"
        )

        state

      {:error, reason} ->
        Logger.warning("[Dispatcher] Failed to checkout issue #{issue.id}: #{inspect(reason)}")

        record_dispatch_failure(issue, state, :checkout_failed)
    end
  end

  # If an issue carries `assigned_role` it was placed there by a handoff or
  # submit_review and should have been woken via the WakeupQueue. By the time
  # the dispatcher poll picks it up, more than `@stalled_wakeup_threshold_ms`
  # since `updated_at` means the wake never fired (or fired and was lost).
  # Emit a telemetry event so operators can alert on it.
  defp maybe_emit_stalled_wakeup(%Cympho.Issues.Issue{
         assigned_role: role,
         status: :todo,
         updated_at: updated_at,
         id: issue_id,
         company_id: company_id
       })
       when not is_nil(role) and not is_nil(updated_at) do
    age_ms = DateTime.diff(DateTime.utc_now(), updated_at, :millisecond)

    if age_ms >= @stalled_wakeup_threshold_ms do
      :telemetry.execute(
        [:cympho, :dispatcher, :stalled_wakeup],
        %{age_ms: age_ms},
        %{issue_id: issue_id, company_id: company_id, role: role}
      )

      Logger.warning(
        "[Dispatcher] stalled wakeup: issue=#{issue_id} role=#{inspect(role)} age_ms=#{age_ms}"
      )
    end

    :ok
  end

  defp maybe_emit_stalled_wakeup(_issue), do: :ok

  @doc false
  # Public for testing — bounded exponential backoff for the retry scheduler.
  def backoff_ms_for_attempt(attempts) when attempts >= 0 do
    min(round(@base_backoff_ms * :math.pow(2, attempts)), @max_backoff_ms)
  end

  @doc """
  Resolves the agent the dispatcher would use for an issue without checking it out.

  This is read-only and mirrors the dispatch path's explicit-assignee and
  fallback-chain routing rules so operator previews do not drift from runtime
  behavior.
  """
  @spec preview_agent_for_issue(Cympho.Issues.Issue.t()) ::
          {:ok, Cympho.Agents.Agent.t()} | {:error, :no_agent_available}
  def preview_agent_for_issue(%Cympho.Issues.Issue{} = issue), do: agent_for_issue(issue)

  @doc false
  # Public for testing — retry bookkeeping for failed dispatches.
  def record_dispatch_failure(%Cympho.Issues.Issue{} = issue, %State{} = state, reason) do
    # When the fallback chain has nothing to assign — every role from the
    # issue's primary role through every fallback is empty or busy — wake
    # the CEO so they can decide between hiring a new agent (`spawn_agent`),
    # re-decomposing the issue, or cancelling. Without this signal, the
    # dispatcher silently backs off for up to 10 minutes.
    if reason == :no_agent do
      escalate_no_agent_for_role(issue)
    end

    current_entry = state.retry_attempts[issue.id]
    attempts = if current_entry, do: current_entry.attempts, else: 0

    # Attempts past @max_retries keep retrying at the max backoff interval
    # rather than giving up: permanently abandoning a :todo issue would be a
    # silent stuck state, while the old "stop tracking" behavior actually
    # retried on EVERY poll with an error log each time. Cap the counter so
    # the backoff math stays bounded.
    next_attempts = min(attempts + 1, @max_retries)
    backoff_ms = backoff_ms_for_attempt(attempts)
    next_retry_at = :os.system_time(:millisecond) + backoff_ms

    Cympho.Telemetry.dispatch_retry_scheduled(issue, next_attempts, backoff_ms)

    new_retry_entry = %{attempts: next_attempts, next_retry_at: next_retry_at}
    new_retries = Map.put(state.retry_attempts, issue.id, new_retry_entry)

    Logger.info(
      "[Dispatcher] Scheduling retry #{next_attempts}/#{@max_retries} for issue #{issue.id} in #{backoff_ms}ms (reason: #{inspect(reason)})"
    )

    %{state | retry_attempts: new_retries}
  end

  # Best-effort escalation. If the company has no staffing owner this no-ops;
  # the issue will continue to back off and will be retried when the next agent
  # goes idle (which won't help, but at least nothing crashes).
  defp escalate_no_agent_for_role(%Cympho.Issues.Issue{company_id: nil}), do: :ok

  defp escalate_no_agent_for_role(%Cympho.Issues.Issue{
         id: issue_id,
         company_id: company_id,
         assigned_role: role
       }) do
    case staffing_owner(company_id, role) do
      {:ok, %Cympho.Agents.Agent{id: owner_id}} ->
        # Coalesce: don't spam if a recent no_agent_for_role already exists
        # for this issue. The wake queue dedups on agent+issue+reason, so
        # this is more of a logging guard than a correctness one.
        _ =
          Cympho.Wakes.wake_for_no_agent_for_role(owner_id, issue_id, %{
            "company_id" => company_id,
            "missing_role" => role && to_string(role)
          })

        :ok

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "[Dispatcher] no_agent escalation failed for issue #{issue_id}: #{Exception.message(e)}"
      )

      :ok
  end

  # Engineering staffing belongs to the CTO, who outranks every delivery role
  # and can hire them directly. Routing every gap to the CEO cost a turn and an
  # extra hop, and left the CTO holding a plan it could not staff. Falls back to
  # the CEO when the company has no CTO.
  defp staffing_owner(company_id, role) do
    with true <- Cympho.Agents.Agent.normalize_role(role) in @cto_staffed_roles,
         {:ok, cto} <- Cympho.Agents.get_company_cto(company_id) do
      {:ok, cto}
    else
      _ -> Cympho.Agents.get_company_ceo(company_id)
    end
  end

  defp agent_for_issue(%Cympho.Issues.Issue{} = issue) do
    case assigned_agent_for_issue(issue) do
      {:ok, agent} ->
        {:ok, agent}

      :unassigned ->
        routed_agent_for_issue(issue)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assigned_agent_for_issue(%Cympho.Issues.Issue{assignee_id: nil}), do: :unassigned

  defp assigned_agent_for_issue(%Cympho.Issues.Issue{} = issue) do
    case Agents.get_agent(issue.assignee_id) do
      {:ok, %Agent{} = agent} ->
        case maybe_recover_error_agent(agent) do
          {:ok, agent} ->
            evaluate_assigned_agent(issue, agent)

          {:error, _} ->
            {:error, :no_agent_available}
        end

      {:error, _} ->
        {:error, :no_agent_available}
    end
  end

  # Transient :error must self-heal under the dispatcher path — AgentHeartbeat
  # skips do_heartbeat (and maybe_recover_error_status) when
  # delegate_to_dispatcher is true (the default).
  defp maybe_recover_error_agent(%Agent{status: :error} = agent) do
    Logger.info("[Dispatcher] recovering agent from error status",
      agent_id: agent.id,
      company_id: agent.company_id,
      component: "dispatcher"
    )

    Agents.recover_error_status(agent)
  end

  defp maybe_recover_error_agent(%Agent{} = agent), do: {:ok, agent}

  defp evaluate_assigned_agent(%Cympho.Issues.Issue{} = issue, %Agent{} = agent) do
    required_role = Router.infer_role(issue)

    cond do
      agent.status != :idle ->
        {:error, :no_agent_available}

      # `list_eligible_agents/2` filters governance on the routed path; the
      # explicit-assignee path bypassed it entirely. Since governance
      # termination/pause leaves `status` untouched, a stopped agent kept
      # receiving every issue already pinned to it — which is exactly what a
      # manager's `delegate` produces.
      not Agents.governance_active?(agent) ->
        Logger.info("[Dispatcher] assignee blocked by governance",
          agent_id: agent.id,
          issue_id: issue.id,
          company_id: issue.company_id,
          status: agent.governance_status,
          component: "dispatcher"
        )

        {:error, :no_agent_available}

      Agents.is_agent_at_capacity?(agent) ->
        {:error, :no_agent_available}

      not same_company?(issue, agent) ->
        {:error, :no_agent_available}

      not Cympho.Issues.Issue.role_authorized?(agent.role, required_role) ->
        {:error, :no_agent_available}

      true ->
        {:ok, agent}
    end
  end

  defp routed_agent_for_issue(%Cympho.Issues.Issue{} = issue) do
    primary_role = Router.infer_role(issue)
    fallback_roles = Router.fallback_chain(primary_role)
    all_roles = [primary_role | fallback_roles]

    # Fail-closed: never fall back to an unscoped agent list when company_id is nil.
    case issue.company_id do
      company_id when is_binary(company_id) ->
        Enum.each(all_roles, fn role ->
          eligible = Agents.list_eligible_agents(role, company_id)

          case Router.select_agent(role, eligible) do
            {:ok, agent} -> throw({:found, agent})
            {:error, _} -> :continue
          end
        end)

        {:error, :no_agent_available}

      _ ->
        {:error, :no_agent_available}
    end
  catch
    {:found, agent} -> {:ok, agent}
  end

  # Fail-closed: both sides must share a non-nil company_id.
  defp same_company?(
         %Cympho.Issues.Issue{company_id: company_id},
         %Agent{company_id: company_id}
       )
       when is_binary(company_id) and company_id != "",
       do: true

  defp same_company?(_issue, _agent), do: false
end
