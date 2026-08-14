defmodule Cympho.Orchestrator.Dispatcher do
  @moduledoc """
  Polls the DB for runnable issues and dispatches agent sessions.

  Configuration (app env):
    - :poll_interval          — ms between polls (default 30_000)
    - :max_concurrent_agents — max simultaneous dispatches (default 3)
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
  @max_concurrent Application.compile_env(:cympho, [:orchestrator, :max_concurrent_agents], 3)
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
  @low_power_priorities [:critical, :high]

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
        GenServer.call(pid, {:stop_company, company_id, reason}, 15_000)
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
    if recover_on_boot?() do
      {:ok, state, {:continue, :recover_orphans}}
    else
      {:ok, state}
    end
  end

  defp recover_on_boot?, do: Application.get_env(:cympho, :dispatcher_recover_on_boot?, true)

  @impl true
  def handle_continue(:recover_orphans, %State{} = state) do
    recover_orphaned_runs()
    _ = recover_orphaned_in_progress()
    _ = recover_stale_checkouts()
    {:noreply, state}
  end

  defp recover_orphaned_runs do
    Cympho.HeartbeatEngine.find_orphaned_runs()
    |> Enum.each(fn run ->
      case Cympho.HeartbeatEngine.recover_orphaned_run(run) do
        {:ok, recovered} ->
          Logger.warning(
            "[Dispatcher] recovered orphaned run #{run.id} (issue=#{run.issue_id}, status=#{run.status}) → #{recovered.status}"
          )

        {:error, reason} ->
          Logger.error(
            "[Dispatcher] failed to recover orphaned run #{run.id}: #{inspect(reason)}"
          )
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

  Returns `%{checked: n, recovered: n, skipped: n}`.
  """
  @spec recover_orphaned_in_progress() :: %{
          checked: non_neg_integer(),
          recovered: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def recover_orphaned_in_progress do
    in_progress =
      from(i in Issue,
        where: i.status == :in_progress,
        select: %{id: i.id, assignee_id: i.assignee_id}
      )
      |> Cympho.Repo.all()

    issue_ids = Enum.map(in_progress, & &1.id)
    active_run_issue_ids = issue_ids_with_active_runs(issue_ids)

    Enum.reduce(in_progress, %{checked: 0, recovered: 0, skipped: 0}, fn
      %{id: issue_id, assignee_id: assignee_id}, acc ->
        acc = %{acc | checked: acc.checked + 1}

        cond do
          live_orchestrator?(issue_id) ->
            %{acc | skipped: acc.skipped + 1}

          MapSet.member?(active_run_issue_ids, issue_id) ->
            %{acc | skipped: acc.skipped + 1}

          true ->
            case reclaim_orphaned_issue(issue_id, assignee_id) do
              :recovered -> %{acc | recovered: acc.recovered + 1}
              :skipped -> %{acc | skipped: acc.skipped + 1}
            end
        end
    end)
  rescue
    # Recovery is best-effort; never let a transient DB issue block boot/poll.
    error ->
      Logger.error("[Dispatcher] orphan recovery failed: #{inspect(error)}")
      %{checked: 0, recovered: 0, skipped: 0}
  end

  defp reclaim_orphaned_issue(issue_id, assignee_id) do
    case Issues.get_issue(issue_id) do
      {:ok, %Issue{status: :in_progress} = issue} ->
        # Re-check immediately before destructive work. A successor orchestrator
        # can register after the outer recover_orphaned_in_progress cond and
        # before cancel_and_release / clear_checkout_lock.
        if live_orchestrator?(issue_id) do
          :skipped
        else
          # Release any remote env first so orphan recovery cannot leak sandbox spend.
          _ =
            Workspaces.cancel_and_release_for_issue(issue, %{
              reason: "orphan_issue_reclaim",
              company_id: issue.company_id
            })

          # Final live check before checkout clear — env cancel is best-effort
          # and must not unlock under a session that became live mid-reclaim.
          if live_orchestrator?(issue_id) do
            :skipped
          else
            # Prefer clear_checkout_lock so ownership routing survives recovery.
            case Issues.clear_checkout_lock(issue, :todo) do
              {:ok, _} ->
                Logger.warning(
                  "[Dispatcher] recovered orphaned issue #{issue_id} (assignee=#{assignee_id || "none"}) → :todo"
                )

                :recovered

              {:error, reason} ->
                Logger.error(
                  "[Dispatcher] failed to release orphaned issue #{issue_id}: #{inspect(reason)}"
                )

                :skipped
            end
          end
        end

      _ ->
        :skipped
    end
  end

  defp live_orchestrator?(issue_id) do
    case Orchestrator.whereis(issue_id) do
      nil -> false
      pid -> Process.alive?(pid)
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
          failed: non_neg_integer()
        }
  def recover_stale_checkouts do
    case Cympho.RuntimeOperations.recover_stale_checked_out_issues_all() do
      {:ok, result} -> result
      _ -> %{checked: 0, released: 0, failed: 0}
    end
  rescue
    error ->
      Logger.error("[Dispatcher] stale checkout recovery failed: #{inspect(error)}")
      %{checked: 0, released: 0, failed: 0}
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
  def handle_call({:stop_company, company_id, reason}, _from, %State{} = state) do
    result = stop_company_runtime(company_id, reason, state.running_issue_ids)

    new_state = %{
      state
      | running_issue_ids:
          MapSet.difference(state.running_issue_ids, MapSet.new(result.issue_ids))
    }

    {:reply, {:ok, result}, new_state}
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
    new_state = %{state | running_issue_ids: MapSet.delete(state.running_issue_ids, issue_id)}
    {:noreply, new_state}
  end

  # Orchestrator process went down. Normal terminations already sent
  # :session_ended from terminate/2; this covers brutal kills (exit signals
  # that skip terminate) so the concurrency slot is freed and a stranded
  # :in_progress issue is released for re-dispatch instead of waiting for
  # the next watchdog sweep.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{} = state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {issue_id, monitors} ->
        unless graceful_down_reason?(reason) do
          release_crashed_session_issue(issue_id, reason)
        end

        {:noreply,
         %{
           state
           | monitors: monitors,
             running_issue_ids: MapSet.delete(state.running_issue_ids, issue_id)
         }}
    end
  end

  @impl true
  def handle_info({:EXIT, _from, _reason}, %State{} = state) do
    {:noreply, state}
  end

  # Graceful shutdown: release issues stranded by dead sessions back to
  # :todo so this node on next boot can pick them up cleanly. Orchestrators
  # are deliberately not linked to the dispatcher, so a session may still be
  # live here — releasing its issue out from under it would double-dispatch
  # the same work, so those are skipped (boot-time orphan recovery catches
  # them if the whole node is going down).
  @impl true
  def terminate(reason, %State{running_issue_ids: running}) do
    Logger.info(
      "[Dispatcher] terminating (reason=#{inspect(reason)}); reconciling #{MapSet.size(running)} in-flight issues"
    )

    Enum.each(MapSet.to_list(running), fn issue_id ->
      try do
        with nil <- Orchestrator.whereis(issue_id),
             {:ok, %{status: :in_progress} = issue} <- Cympho.Issues.get_issue(issue_id) do
          _ = Cympho.Issues.force_release_issue(issue, :todo)
        else
          _ -> :ok
        end
      rescue
        # Best-effort: never raise from terminate or we delay supervisor shutdown.
        _ -> :ok
      end
    end)

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
        case HeartbeatEngine.recover_orphaned_run(run) do
          {:ok, recovered} ->
            Logger.warning(
              "[Dispatcher] recovered crashed-session run #{run.id} (issue=#{issue_id}) → #{recovered.status}"
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

  defp stop_company_runtime(company_id, reason, running_issue_ids) do
    company_runtime_issues(company_id, running_issue_ids)
    |> Enum.reduce(empty_stop_result(reason), &stop_runtime_issue/2)
    |> Map.update!(:issue_ids, &Enum.reverse/1)
  end

  defp empty_stop_result(reason) do
    %{
      reason: to_string(reason),
      issue_ids: [],
      orchestrators_stopped: 0,
      adapter_sessions_cancel_requested: 0,
      adapter_sessions_cancel_confirmed: 0,
      adapter_sessions_still_registered: 0,
      issues_released: 0,
      runs_cancelled: 0,
      agents_idled: 0,
      errors: []
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
    acc
    |> track_issue(issue.id)
    |> maybe_stop_orchestrator(issue.id, {:runtime_stop, acc.reason})
    |> maybe_release_issue(issue)
    |> cancel_issue_runs(issue.id)
    |> release_issue_environment(issue)
    |> idle_agent(issue.assignee_id)
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

      _pid ->
        session_id = issue_id |> Orchestrator.get_session_state() |> adapter_session_id()
        registered_before_stop? = adapter_session_registered?(session_id)

        try do
          :ok = Orchestrator.stop(issue_id, reason)

          acc
          |> Map.update!(:orchestrators_stopped, &(&1 + 1))
          |> record_adapter_session_stop(issue_id, session_id, registered_before_stop?)
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
    acc = Map.update!(acc, :adapter_sessions_cancel_requested, &(&1 + 1))

    if adapter_session_cleared?(session_id) do
      Map.update!(acc, :adapter_sessions_cancel_confirmed, &(&1 + 1))
    else
      acc
      |> Map.update!(:adapter_sessions_still_registered, &(&1 + 1))
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
    available_slots = @max_concurrent - MapSet.size(running)

    if available_slots <= 0 do
      state
    else
      candidates = fetch_candidate_issues(available_slots * 4, company_id)
      now = :os.system_time(:millisecond)

      # Per-company cap: count how many running issues belong to each
      # company, then drop candidates whose company has hit its
      # `max_concurrent_runs` limit. Companies without a configured limit
      # use the global default (`@max_concurrent`). The count is updated as
      # dispatches succeed within this poll so a single poll cannot burst a
      # company past its cap.
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
    cap = Cympho.Companies.runtime_limit(company_id, "max_concurrent_runs", @max_concurrent)
    Map.get(by_co, company_id, 0) >= cap
  end

  defp fetch_candidate_issues(limit, company_id) do
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
    |> limit(^limit)
    |> Cympho.Repo.all()
    |> Enum.filter(&runnable_candidate?/1)
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

  # Best-effort escalation. If the company has no CEO this no-ops; the issue
  # will continue to back off and will be retried when the next agent goes
  # idle (which won't help, but at least nothing crashes).
  defp escalate_no_agent_for_role(%Cympho.Issues.Issue{company_id: nil}), do: :ok

  defp escalate_no_agent_for_role(%Cympho.Issues.Issue{
         id: issue_id,
         company_id: company_id,
         assigned_role: role
       }) do
    case Cympho.Agents.get_company_ceo(company_id) do
      {:ok, %Cympho.Agents.Agent{id: ceo_id}} ->
        # Coalesce: don't spam if a recent no_agent_for_role already exists
        # for this issue. The wake queue dedups on agent+issue+reason, so
        # this is more of a logging guard than a correctness one.
        _ =
          Cympho.Wakes.wake_for_no_agent_for_role(ceo_id, issue_id, %{
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
