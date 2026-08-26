defmodule Cympho.RuntimeAdmission do
  @moduledoc """
  Atomic node-local admission for agent runtimes.

  Every execution consumes one monitored total slot. Local and unknown adapters
  additionally require a local-process slot and, when enabled, a recent
  sanitized host-memory sample. Gateway adapters skip only those local checks.
  """

  use GenServer

  alias Cympho.Adapters.Adapter
  alias Cympho.RuntimeAdmission.MemoryProbe

  @default_max_local_runs 1
  @default_memory_reserve_bytes 512 * 1024 * 1024
  @default_sample_ttl_ms 5_000
  @default_sample_timeout_ms 250
  @max_sample_timeout_ms 1_000
  @recovery_state_timeout_ms 100
  @initial_recovery_retry_ms 100
  @max_recovery_retry_ms 1_000
  @recovery_candidates_per_tick 1
  @reasons [
    :total_slots_exhausted,
    :local_slots_exhausted,
    :host_memory_low,
    :host_memory_unknown,
    :admission_unavailable
  ]
  @empty_denial_counts Map.new(@reasons, &{&1, 0})

  @type reason ::
          :total_slots_exhausted
          | :local_slots_exhausted
          | :host_memory_low
          | :host_memory_unknown
          | :admission_unavailable
  @type token :: reference()

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name),
      do: GenServer.start_link(__MODULE__, opts),
      else: GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec checkout(module() | atom() | String.t(), GenServer.server()) ::
          {:ok, token()} | {:error, reason()}
  def checkout(adapter, server \\ __MODULE__) do
    safe_call(server, {:checkout, Adapter.execution_class(adapter)})
  end

  @spec available(module() | atom() | String.t(), GenServer.server()) :: :ok | {:error, reason()}
  def available(adapter, server \\ __MODULE__) do
    safe_call(server, {:available, Adapter.execution_class(adapter)})
  end

  @spec release(token(), GenServer.server()) :: :ok
  def release(token, server \\ __MODULE__)

  def release(token, server) when is_reference(token) do
    case safe_call(server, {:release, token}) do
      :ok -> :ok
      _ -> :ok
    end
  end

  def release(_token, _server), do: :ok

  @doc "Confirms that an adopted local worker has successfully opened its OS Port."
  @spec local_process_started(token(), GenServer.server()) ::
          :ok | {:error, :claim_not_found | :not_claim_holder | :not_local_process}
  def local_process_started(token, server \\ __MODULE__)

  def local_process_started(token, server) when is_reference(token),
    do: safe_call(server, {:local_process_started, token})

  def local_process_started(_token, _server), do: {:error, :claim_not_found}

  @doc "Transfers a claim's liveness monitor from its controller to an adapter worker."
  @spec adopt(token(), pid(), GenServer.server()) :: :ok | {:error, atom()}
  def adopt(token, worker_pid, server \\ __MODULE__)

  def adopt(token, worker_pid, server) when is_reference(token) and is_pid(worker_pid) do
    safe_call(server, {:adopt, token, worker_pid})
  end

  def adopt(_token, _worker_pid, _server), do: {:error, :invalid_adoption}

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    case safe_call(server, :snapshot) do
      %{} = snapshot -> snapshot
      _ -> unavailable_snapshot()
    end
  end

  @impl true
  def init(opts) do
    configured = Application.get_env(:cympho, :runtime_admission, [])

    max_total_runs =
      positive_integer(
        Keyword.get(opts, :max_total_runs, configured[:max_total_runs]),
        default_max_total_runs()
      )

    max_local_runs =
      positive_integer(
        Keyword.get(opts, :max_local_runs, configured[:max_local_runs]),
        @default_max_local_runs
      )

    state = %{
      holders: %{},
      monitors: %{},
      max_total_runs: max_total_runs,
      max_local_runs: max_local_runs,
      memory_reserve_bytes:
        positive_integer(
          Keyword.get(opts, :memory_reserve_bytes, configured[:memory_reserve_bytes]),
          @default_memory_reserve_bytes
        ),
      memory_check?: boolean(Keyword.get(opts, :memory_check?, configured[:memory_check?]), true),
      sample_ttl_ms:
        non_negative_integer(
          Keyword.get(opts, :sample_ttl_ms, configured[:sample_ttl_ms]),
          @default_sample_ttl_ms
        ),
      sample_timeout_ms:
        min(
          positive_integer(
            Keyword.get(opts, :sample_timeout_ms, configured[:sample_timeout_ms]),
            @default_sample_timeout_ms
          ),
          @max_sample_timeout_ms
        ),
      sampler: Keyword.get(opts, :sampler, &MemoryProbe.sample/0),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      sample: nil,
      sampled_at_ms: nil,
      sampling: nil,
      recovery_status: :ok,
      recovery_pending: MapSet.new(),
      recovery_queue: :queue.new(),
      recovery_retry_ms: @initial_recovery_retry_ms,
      recovery_timer: nil,
      last_denial_reason: nil,
      last_denial_at_ms: nil,
      denial_counts: @empty_denial_counts
    }

    cond do
      max_local_runs > max_total_runs ->
        {:stop, :invalid_limits}

      true ->
        recover_fun = Keyword.get(opts, :recover_fun, &default_recovery_candidates/0)

        case recover_holders(state, recover_fun) do
          {:ok, recovered} -> {:ok, schedule_recovery(recovered)}
          {:error, :recovery_failed} -> {:stop, :recovery_failed}
        end
    end
  end

  @impl true
  def handle_call({:available, execution_class}, from, state) do
    execution_class = normalize_execution_class(execution_class)
    {result, state} = availability(state, execution_class)

    case result do
      :sample_required -> start_sample(:available, execution_class, from, state)
      _ -> reply_decision(:available, execution_class, result, state)
    end
  end

  def handle_call({:checkout, execution_class}, {pid, _tag} = from, state) do
    execution_class = normalize_execution_class(execution_class)
    {result, state} = availability_for_caller(state, pid, execution_class)

    case result do
      :sample_required ->
        start_sample(:checkout, execution_class, from, state)

      :ok ->
        admit_checkout(execution_class, pid, state)

      {:error, _reason} = error ->
        reply_decision(:checkout, execution_class, error, state)
    end
  end

  def handle_call({:release, token}, {pid, _tag}, state) do
    case Map.get(state.holders, token) do
      %{controller_pid: ^pid, pid: ^pid, monitor: monitor, execution_class: execution_class} ->
        Process.demonitor(monitor, [:flush])
        state = drop_holder(state, token, monitor)
        emit(:release, execution_class, :released, nil, state)
        {:reply, :ok, state}

      %{
        controller_pid: ^pid,
        pid: holder_pid,
        monitor: monitor,
        execution_class: execution_class
      } ->
        # The controller cannot release a live worker-owned claim. Once a
        # caller has synchronously observed that worker exit, however, allow
        # it to close the claim even if the manager's independent DOWN message
        # is still queued. This keeps immediate retry/fallback from seeing its
        # own dead claim as occupied without reopening capacity early.
        if Process.alive?(holder_pid) do
          {:reply, :ok, state}
        else
          Process.demonitor(monitor, [:flush])
          state = drop_holder(state, token, monitor)
          emit(:release, execution_class, :released, nil, state)
          {:reply, :ok, state}
        end

      %{pid: ^pid, monitor: monitor, execution_class: execution_class} ->
        Process.demonitor(monitor, [:flush])
        state = drop_holder(state, token, monitor)
        emit(:release, execution_class, :released, nil, state)
        {:reply, :ok, state}

      nil ->
        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:adopt, token, worker_pid}, {controller_pid, _tag}, state) do
    case Map.get(state.holders, token) do
      %{controller_pid: ^controller_pid, pid: ^worker_pid} ->
        {:reply, :ok, state}

      %{controller_pid: ^controller_pid, monitor: old_monitor} = holder ->
        if Process.alive?(worker_pid) do
          Process.demonitor(old_monitor, [:flush])
          monitor = Process.monitor(worker_pid)

          state = %{
            state
            | holders:
                Map.put(state.holders, token, %{
                  holder
                  | pid: worker_pid,
                    monitor: monitor
                }),
              monitors:
                state.monitors
                |> Map.delete(old_monitor)
                |> Map.put(monitor, token)
          }

          {:reply, :ok, state}
        else
          {:reply, {:error, :worker_not_alive}, state}
        end

      nil ->
        {:reply, {:error, :claim_not_found}, state}

      _holder ->
        {:reply, {:error, :not_claim_controller}, state}
    end
  end

  def handle_call({:local_process_started, token}, {holder_pid, _tag}, state) do
    case Map.get(state.holders, token) do
      %{pid: ^holder_pid, execution_class: :local_process} = holder ->
        state = %{
          state
          | holders: Map.put(state.holders, token, %{holder | start_pending?: false}),
            # The prior sample preceded this child. It was a start gate, not a
            # reservation of the child process's eventual RSS.
            sampled_at_ms: nil
        }

        {:reply, :ok, state}

      %{execution_class: :local_process} ->
        {:reply, {:error, :not_claim_holder}, state}

      %{execution_class: :gateway} ->
        {:reply, {:error, :not_local_process}, state}

      nil ->
        {:reply, {:error, :claim_not_found}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {result, state} = availability(state, :local_process)
    result = if result == :sample_required, do: {:error, :host_memory_unknown}, else: result
    {:reply, public_snapshot(state, result), state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    if state.sampling && state.sampling.monitor == monitor do
      Process.cancel_timer(state.sampling.timer)
      finish_sample(nil, state)
    else
      holder_down(monitor, state)
    end
  end

  def handle_info({:memory_sample_result, request_id, sample}, state) do
    case state.sampling do
      %{request_id: ^request_id, monitor: monitor, timer: timer} ->
        Process.cancel_timer(timer)
        Process.demonitor(monitor, [:flush])
        finish_sample(sample, state)

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:memory_sample_timeout, request_id}, state) do
    case state.sampling do
      %{request_id: ^request_id, pid: pid, monitor: monitor} ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        finish_sample(nil, state)

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:retry_recovery, state) do
    state = %{state | recovery_timer: nil}

    {state, queue} =
      if :queue.is_empty(state.recovery_queue) do
        queue = Enum.reduce(state.recovery_pending, :queue.new(), &:queue.in(&1, &2))
        {%{state | recovery_pending: MapSet.new()}, queue}
      else
        {state, state.recovery_queue}
      end

    {state, queue} = retry_recovery_candidates(state, queue)
    state = %{state | recovery_queue: queue}

    {:noreply,
     if(:queue.is_empty(queue),
       do: schedule_recovery(state),
       else: schedule_recovery_continuation(state)
     )}
  end

  defp holder_down(monitor, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {token, monitors} ->
        case Map.get(state.holders, token) do
          %{monitor: ^monitor} = holder ->
            case replacement_worker(token, holder) do
              {:ok, worker_pid} ->
                worker_monitor = Process.monitor(worker_pid)

                state = %{
                  state
                  | holders:
                      Map.put(state.holders, token, %{
                        holder
                        | pid: worker_pid,
                          monitor: worker_monitor
                      }),
                    monitors: Map.put(monitors, worker_monitor, token)
                }

                {:noreply, state}

              :none ->
                execution_class = holder.execution_class
                state = %{state | holders: Map.delete(state.holders, token), monitors: monitors}
                emit(:release, execution_class, :holder_down, nil, state)
                {:noreply, state}
            end

          _stale_or_missing_holder ->
            {:noreply, %{state | monitors: monitors}}
        end
    end
  end

  defp availability_for_caller(state, pid, execution_class) do
    if Enum.any?(state.holders, fn {_token, holder} ->
         holder.pid == pid or holder.controller_pid == pid
       end) do
      {{:error, :total_slots_exhausted}, state}
    else
      availability(state, execution_class)
    end
  end

  defp availability(state, execution_class) do
    cond do
      state.recovery_status == :recovering ->
        {{:error, :admission_unavailable}, state}

      total_running(state) >= state.max_total_runs ->
        {{:error, :total_slots_exhausted}, state}

      execution_class == :gateway ->
        {:ok, state}

      local_start_pending?(state) ->
        {{:error, :local_slots_exhausted}, state}

      local_running(state) >= state.max_local_runs ->
        {{:error, :local_slots_exhausted}, state}

      not state.memory_check? ->
        {:ok, state}

      true ->
        memory_availability(state)
    end
  end

  defp memory_availability(state) do
    case current_sample(state) do
      :stale ->
        {:sample_required, state}

      %{available_bytes: available} when available <= state.memory_reserve_bytes ->
        {{:error, :host_memory_low}, state}

      %{available_bytes: available} when is_integer(available) ->
        {:ok, state}

      _ ->
        {{:error, :host_memory_unknown}, state}
    end
  end

  defp current_sample(state) do
    now = safe_clock(state.clock)

    if fresh_sample?(state, now) do
      state.sample
    else
      :stale
    end
  end

  defp fresh_sample?(%{sampled_at_ms: sampled_at, sample_ttl_ms: ttl}, now)
       when is_integer(sampled_at) and is_integer(now),
       do: now >= sampled_at and now - sampled_at <= ttl

  defp fresh_sample?(_state, _now), do: false

  defp safe_sample(sampler) do
    case sampler.() do
      {:ok, %{available_bytes: available, total_bytes: total, source: source}}
      when is_integer(available) and available >= 0 and is_integer(total) and total > 0 and
             source in [:host, :cgroup, :host_and_cgroup] ->
        %{available_bytes: min(available, total), total_bytes: total, source: source}

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp start_sample(operation, execution_class, from, %{sampling: nil} = state) do
    waiter = {operation, execution_class, from}
    {:noreply, begin_sample(state, :queue.in(waiter, :queue.new()))}
  end

  defp start_sample(operation, execution_class, from, state) do
    waiters = :queue.in({operation, execution_class, from}, state.sampling.waiters)
    {:noreply, put_in(state.sampling.waiters, waiters)}
  end

  defp finish_sample(sample, state) do
    %{waiters: waiters} = state.sampling

    state = %{
      state
      | sample: sample,
        sampled_at_ms: safe_clock(state.clock),
        sampling: nil
    }

    reply_sampled_waiters(waiters, state)
  end

  defp reply_sampled_waiters(waiters, state) do
    case :queue.out(waiters) do
      {:empty, _waiters} ->
        {:noreply, state}

      {{:value, {operation, execution_class, {pid, _tag} = from} = waiter}, rest} ->
        if operation == :checkout and not Process.alive?(pid) do
          reply_sampled_waiters(rest, state)
        else
          {result, state} =
            case operation do
              :checkout -> availability_for_caller(state, pid, execution_class)
              :available -> availability(state, execution_class)
            end

          case {operation, result} do
            {_operation, :sample_required} ->
              {:noreply, begin_sample(state, :queue.in_r(waiter, rest))}

            {:checkout, :ok} ->
              {reply, state} = admit_checkout_result(execution_class, pid, state)
              GenServer.reply(from, reply)
              reply_sampled_waiters(rest, state)

            _ ->
              state = record_denial(state, result)
              emit_decision(operation, execution_class, result, state)
              GenServer.reply(from, result)
              reply_sampled_waiters(rest, state)
          end
        end
    end
  end

  defp begin_sample(state, waiters) do
    manager = self()
    request_id = make_ref()
    sampler = state.sampler

    pid =
      spawn(fn ->
        send(manager, {:memory_sample_result, request_id, safe_sample(sampler)})
      end)

    monitor = Process.monitor(pid)
    _watcher = spawn(fn -> watch_sampler_owner(manager, pid) end)

    timer =
      Process.send_after(
        manager,
        {:memory_sample_timeout, request_id},
        state.sample_timeout_ms
      )

    %{
      state
      | sampling: %{
          request_id: request_id,
          pid: pid,
          monitor: monitor,
          timer: timer,
          waiters: waiters
        }
    }
  end

  defp watch_sampler_owner(manager, sampler_pid) do
    manager_monitor = Process.monitor(manager)
    sampler_monitor = Process.monitor(sampler_pid)

    receive do
      {:DOWN, ^sampler_monitor, :process, ^sampler_pid, _reason} ->
        Process.demonitor(manager_monitor, [:flush])

      {:DOWN, ^manager_monitor, :process, ^manager, _reason} ->
        Process.exit(sampler_pid, :kill)
    end
  end

  defp admit_checkout(execution_class, pid, state) do
    {reply, state} = admit_checkout_result(execution_class, pid, state)
    {:reply, reply, state}
  end

  defp admit_checkout_result(execution_class, pid, state) do
    token = make_ref()
    monitor = Process.monitor(pid)

    state = %{
      state
      | holders:
          Map.put(state.holders, token, %{
            pid: pid,
            controller_pid: pid,
            monitor: monitor,
            execution_class: execution_class,
            start_pending?: execution_class == :local_process and state.memory_check?,
            recovered?: false
          }),
        monitors: Map.put(state.monitors, monitor, token)
    }

    emit(:checkout, execution_class, :admitted, nil, state)
    {{:ok, token}, state}
  end

  defp reply_decision(event, execution_class, result, state) do
    state = record_denial(state, result)
    emit_decision(event, execution_class, result, state)
    {:reply, result, state}
  end

  defp safe_clock(clock) do
    case clock.() do
      value when is_integer(value) -> value
      _ -> 0
    end
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  defp recover_holders(state, recover_fun) do
    candidates = recover_fun.()
    candidates = List.wrap(candidates)

    if duplicate_recovery_token?(candidates) do
      {:error, :recovery_failed}
    else
      {recovered, queue} =
        Enum.reduce(candidates, {state, :queue.new()}, fn
          %{recovery_pid: pid}, acc when is_pid(pid) ->
            {state, queue} = acc
            {state, :queue.in(pid, queue)}

          candidate, acc ->
            {state, queue} = acc
            {recover_holder(state, candidate), queue}
        end)

      {recovered, queue} = retry_recovery_candidates(recovered, queue)
      {:ok, %{recovered | recovery_queue: queue}}
    end
  rescue
    _ -> {:error, :recovery_failed}
  catch
    _, _ -> {:error, :recovery_failed}
  end

  defp resolve_recovery_pid(state, pid) when is_pid(pid) do
    if Process.alive?(pid) do
      case recovered_execution(pid) do
        {:confirmed, token, execution_class, holder_pid, controller_pid, start_pending?} ->
          recover_confirmed_holder(state, pid, %{
            token: token,
            execution_class: execution_class,
            holder_pid: holder_pid,
            controller_pid: controller_pid,
            start_pending?: start_pending?
          })

        :skip ->
          state

        {:error, :unconfirmed} ->
          %{state | recovery_pending: MapSet.put(state.recovery_pending, pid)}
      end
    else
      state
    end
  end

  defp resolve_recovery_pid(state, _pid), do: state

  defp schedule_recovery(state) do
    cond do
      not :queue.is_empty(state.recovery_queue) ->
        schedule_recovery_continuation(state)

      MapSet.size(state.recovery_pending) == 0 ->
        %{
          state
          | recovery_status: :ok,
            recovery_retry_ms: @initial_recovery_retry_ms,
            recovery_queue: :queue.new()
        }

      true ->
        timer = Process.send_after(self(), :retry_recovery, state.recovery_retry_ms)

        %{
          state
          | recovery_status: :recovering,
            recovery_timer: timer,
            recovery_retry_ms: min(state.recovery_retry_ms * 2, @max_recovery_retry_ms)
        }
    end
  end

  defp schedule_recovery_continuation(state) do
    timer = Process.send_after(self(), :retry_recovery, 0)
    %{state | recovery_status: :recovering, recovery_timer: timer}
  end

  defp retry_recovery_candidates(state, queue) do
    Enum.reduce_while(1..@recovery_candidates_per_tick, {state, queue}, fn _, {state, queue} ->
      case :queue.out(queue) do
        {:empty, queue} -> {:halt, {state, queue}}
        {{:value, pid}, queue} -> {:cont, {resolve_recovery_pid(state, pid), queue}}
      end
    end)
  end

  defp recover_confirmed_holder(
         state,
         recovery_pid,
         %{token: token, holder_pid: holder_pid} = candidate
       ) do
    token_holder = Map.get(state.holders, token)

    pid_holder =
      Enum.find_value(state.holders, fn {existing_token, holder} ->
        if holder.pid == holder_pid, do: {existing_token, holder}
      end)

    if token_holder != nil or pid_holder != nil do
      %{state | recovery_pending: MapSet.put(state.recovery_pending, recovery_pid)}
    else
      recover_holder(state, candidate)
    end
  end

  defp recover_holder(state, candidate) do
    with {holder_pid, controller_pid, token, execution_class, start_pending?} <-
           recovery_candidate(candidate),
         true <- is_pid(holder_pid) and Process.alive?(holder_pid),
         true <- is_pid(controller_pid),
         false <- Enum.any?(state.holders, fn {_token, holder} -> holder.pid == holder_pid end) do
      monitor = Process.monitor(holder_pid)

      %{
        state
        | holders:
            Map.put(state.holders, token, %{
              pid: holder_pid,
              controller_pid: controller_pid,
              monitor: monitor,
              execution_class: execution_class,
              start_pending?:
                execution_class == :local_process and state.memory_check? and start_pending?,
              recovered?: true
            }),
          monitors: Map.put(state.monitors, monitor, token)
      }
    else
      _ -> state
    end
  end

  defp recovery_candidate(
         %{
           holder_pid: holder_pid,
           controller_pid: controller_pid,
           token: token,
           execution_class: execution_class
         } = candidate
       )
       when is_reference(token) and execution_class in [:local_process, :gateway] do
    start_pending? = Map.get(candidate, :start_pending?, execution_class == :local_process)
    {holder_pid, controller_pid, token, execution_class, start_pending?}
  end

  # Explicit test/operator recovery input can be marked adoptable without
  # knowing the prior manager's opaque token. Unmarked/bare candidates are not
  # claims and must not consume capacity.
  defp recovery_candidate(%{pid: pid, execution_class: execution_class, adoptable?: true})
       when execution_class in [:local_process, :gateway],
       do: {pid, pid, make_ref(), execution_class, false}

  defp recovery_candidate(_candidate), do: :error

  defp duplicate_recovery_token?(candidates) do
    tokens =
      Enum.flat_map(candidates, fn candidate ->
        case recovery_candidate(candidate) do
          {_holder_pid, _controller_pid, token, _execution_class, _start_pending?} -> [token]
          :error -> []
        end
      end)

    length(tokens) != MapSet.size(MapSet.new(tokens))
  end

  defp default_recovery_candidates do
    registry = Process.whereis(Cympho.OrchestratorRegistry)
    adapter_sessions = Process.whereis(Cympho.AdapterSessions)

    unless is_pid(registry) and Process.alive?(registry) and is_pid(adapter_sessions) and
             Process.alive?(adapter_sessions) do
      raise "runtime recovery registry unavailable"
    end

    adapter_claims =
      case Cympho.AdapterSessions.recovery_claims() do
        {:ok, claims} -> claims
        {:error, :not_started} -> raise "runtime recovery adapter ledger unavailable"
      end

    claimed_controllers =
      adapter_claims
      |> Enum.map(& &1.controller_pid)
      |> MapSet.new()

    orchestrators =
      Cympho.OrchestratorRegistry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$2"]}])
      |> Enum.uniq()
      |> Enum.filter(&Process.alive?/1)
      |> Enum.reject(&MapSet.member?(claimed_controllers, &1))
      |> Enum.map(&%{recovery_pid: &1})

    adapter_claims ++ orchestrators
  end

  defp recovered_execution(pid) do
    case GenServer.call(pid, :runtime_admission_state, @recovery_state_timeout_ms) do
      %{token: nil, execution_class: nil} ->
        :skip

      %{
        token: token,
        execution_class: class,
        holder_pid: holder_pid,
        controller_pid: controller_pid
      } = claim
      when is_reference(token) and class in [:local_process, :gateway] and
             is_pid(holder_pid) and is_pid(controller_pid) ->
        start_pending? = Map.get(claim, :start_pending?, class == :local_process)
        {:confirmed, token, class, holder_pid, controller_pid, start_pending?}

      _ ->
        {:error, :unconfirmed}
    end
  catch
    :exit, _reason -> {:error, :unconfirmed}
  end

  defp drop_holder(state, token, monitor) do
    %{
      state
      | holders: Map.delete(state.holders, token),
        monitors: Map.delete(state.monitors, monitor)
    }
  end

  defp public_snapshot(state, result) do
    %{
      status: if(result == :ok, do: :available, else: :unavailable),
      reason: result_reason(result),
      total_running: total_running(state),
      max_total_runs: state.max_total_runs,
      local_running: local_running(state),
      max_local_runs: state.max_local_runs,
      gateway_running: gateway_running(state),
      memory_check?: state.memory_check?,
      memory_reserve_bytes: state.memory_reserve_bytes,
      memory: state.sample,
      recovery_status: state.recovery_status,
      last_denial_reason: state.last_denial_reason,
      last_denial_age_ms: denial_age_ms(state),
      denial_counts: state.denial_counts
    }
  end

  defp unavailable_snapshot do
    %{
      status: :unavailable,
      reason: :admission_unavailable,
      total_running: nil,
      max_total_runs: nil,
      local_running: nil,
      max_local_runs: nil,
      gateway_running: nil,
      memory_check?: nil,
      memory_reserve_bytes: nil,
      memory: nil,
      recovery_status: :unavailable,
      last_denial_reason: :admission_unavailable,
      last_denial_age_ms: nil,
      denial_counts: @empty_denial_counts
    }
  end

  defp result_reason(:ok), do: nil
  defp result_reason({:error, reason}) when reason in @reasons, do: reason

  defp record_denial(state, {:error, reason}) when reason in @reasons do
    %{
      state
      | last_denial_reason: reason,
        last_denial_at_ms: safe_clock(state.clock),
        denial_counts: Map.update!(state.denial_counts, reason, &(&1 + 1))
    }
  end

  defp record_denial(state, _result), do: state

  defp denial_age_ms(%{last_denial_at_ms: nil}), do: nil

  defp denial_age_ms(state),
    do: max(safe_clock(state.clock) - state.last_denial_at_ms, 0)

  defp emit_decision(event, execution_class, result, state) do
    emit(
      event,
      execution_class,
      if(result == :ok, do: :available, else: :rejected),
      result_reason(result),
      state
    )
  end

  defp emit(event, execution_class, outcome, reason, state) do
    measurements = %{
      count: 1,
      total_running: if(state, do: total_running(state), else: 0),
      local_running: if(state, do: local_running(state), else: 0),
      gateway_running: if(state, do: gateway_running(state), else: 0)
    }

    metadata = %{
      execution_class: execution_class,
      outcome: outcome,
      reason: reason,
      max_total_runs: state && state.max_total_runs,
      max_local_runs: state && state.max_local_runs
    }

    :telemetry.execute([:cympho, :runtime_admission, event], measurements, metadata)
  end

  defp safe_call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _ -> {:error, :admission_unavailable}
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp default_max_total_runs do
    :cympho
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get(:max_concurrent_agents)
    |> positive_integer(min(max(:erlang.system_info(:schedulers_online) * 2, 4), 32))
  end

  defp total_running(state), do: map_size(state.holders)

  defp local_running(state) do
    Enum.count(state.holders, fn {_token, holder} ->
      holder.execution_class == :local_process
    end)
  end

  defp gateway_running(state) do
    Enum.count(state.holders, fn {_token, holder} -> holder.execution_class == :gateway end)
  end

  defp local_start_pending?(state) do
    Enum.any?(state.holders, fn {_token, holder} ->
      holder.execution_class == :local_process and Map.get(holder, :start_pending?, false)
    end)
  end

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default

  defp boolean(value, _default) when is_boolean(value), do: value
  defp boolean(_value, default), do: default

  defp normalize_execution_class(:gateway), do: :gateway
  defp normalize_execution_class(_unknown_or_local), do: :local_process

  defp replacement_worker(token, %{
         execution_class: :local_process,
         pid: controller_pid,
         controller_pid: controller_pid
       })
       when is_reference(token) do
    case Cympho.AdapterSessions.owner_for_claim(token) do
      {:ok, worker_pid} when is_pid(worker_pid) ->
        if Process.alive?(worker_pid), do: {:ok, worker_pid}, else: :none

      _ ->
        :none
    end
  rescue
    _ -> :none
  catch
    _, _ -> :none
  end

  defp replacement_worker(_token, _holder), do: :none
end
