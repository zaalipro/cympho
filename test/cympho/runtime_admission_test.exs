defmodule Cympho.RuntimeAdmissionTest do
  use ExUnit.Case, async: false

  alias Cympho.RuntimeAdmission

  defmodule UnknownAdapter do
  end

  defmodule InvalidClassAdapter do
    def execution_class, do: :something_else
  end

  defmodule GatewayAdapter do
    def execution_class, do: :gateway
  end

  defmodule LocalAdapter do
    def execution_class, do: :local_process
  end

  defmodule HangingAdapter do
    def execution_class do
      receive do
        :never -> :gateway
      end
    end
  end

  defmodule RecoverableOrchestrator do
    use GenServer

    def start_link({key, adapter}), do: GenServer.start_link(__MODULE__, {key, adapter})

    @impl true
    def init({key, adapter}) do
      {:ok, _} = Registry.register(Cympho.OrchestratorRegistry, key, nil)
      {:ok, %{runtime_context: %{adapter: adapter}, token: make_ref()}}
    end

    @impl true
    def handle_call(:runtime_admission_state, _from, state) do
      {:reply,
       %{
         token: state.token,
         execution_class: Cympho.Adapters.Adapter.execution_class(state.runtime_context.adapter),
         holder_pid: self(),
         controller_pid: self()
       }, state}
    end
  end

  defmodule IdleOrchestrator do
    use GenServer

    def start_link(key), do: GenServer.start_link(__MODULE__, key)

    @impl true
    def init(key) do
      {:ok, _} = Registry.register(Cympho.OrchestratorRegistry, key, nil)
      {:ok, %{runtime_context: %{adapter: LocalAdapter}}}
    end

    @impl true
    def handle_call(:runtime_admission_state, _from, state) do
      {:reply, %{token: nil, execution_class: nil}, state}
    end
  end

  defmodule UnconfirmedOrchestrator do
    use GenServer

    def start_link(key), do: GenServer.start_link(__MODULE__, key)

    @impl true
    def init(key) do
      {:ok, _} = Registry.register(Cympho.OrchestratorRegistry, key, nil)
      {:ok, %{}}
    end

    @impl true
    def handle_call(:runtime_admission_state, _from, state) do
      {:reply, %{token: :busy, execution_class: nil}, state}
    end
  end

  defmodule BusyRecoveryOrchestrator do
    use GenServer

    def start_link({key, claim}), do: GenServer.start_link(__MODULE__, {key, claim})

    @impl true
    def init({key, claim}) do
      {:ok, _} = Registry.register(Cympho.OrchestratorRegistry, key, nil)
      {:ok, {:blocked, claim}}
    end

    @impl true
    def handle_call(:runtime_admission_state, _from, {:blocked, claim}) do
      receive do
        :unblock -> {:reply, recovery_reply(claim), {:ready, claim}}
      end
    end

    def handle_call(:runtime_admission_state, _from, {:ready, claim} = state),
      do: {:reply, recovery_reply(claim), state}

    defp recovery_reply(:preclaim) do
      %{token: nil, execution_class: nil, holder_pid: self(), controller_pid: self()}
    end

    defp recovery_reply({:active, token}) do
      %{
        token: token,
        execution_class: :local_process,
        holder_pid: self(),
        controller_pid: self()
      }
    end
  end

  defmodule RecoveryClaimServer do
    use GenServer

    def start_link(claim), do: GenServer.start_link(__MODULE__, claim)

    @impl true
    def init(claim), do: {:ok, claim}

    @impl true
    def handle_call(:runtime_admission_state, _from, claim) do
      {:reply, Map.merge(claim, %{holder_pid: self(), controller_pid: self()}), claim}
    end
  end

  defmodule BlockingRecoveryCandidate do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    @impl true
    def init(parent), do: {:ok, parent}

    @impl true
    def handle_call(:runtime_admission_state, _from, parent) do
      send(parent, {:recovery_candidate_called, self()})
      Process.sleep(:infinity)
    end
  end

  test "built-ins and custom adapters classify fail-safe" do
    assert Cympho.Adapters.Adapter.execution_class(Cympho.Adapters.ClaudeCodeAdapter) ==
             :local_process

    assert Cympho.Adapters.Adapter.execution_class(Cympho.Adapters.HttpAdapter) == :gateway
    assert Cympho.Adapters.Adapter.execution_class(Cympho.Adapters.MockAdapter) == :gateway
    assert Cympho.Adapters.Adapter.execution_class(:openai_chat) == :gateway
    assert Cympho.Adapters.Adapter.execution_class("agrenting") == :gateway
    assert Cympho.Adapters.Adapter.execution_class(UnknownAdapter) == :local_process
    assert Cympho.Adapters.Adapter.execution_class(InvalidClassAdapter) == :local_process
    assert Cympho.Adapters.Adapter.execution_class("custom") == :local_process
  end

  test "a hanging custom execution-class callback fails closed within a fixed bound" do
    started_at = System.monotonic_time(:millisecond)

    assert Cympho.Adapters.Adapter.execution_class(HangingAdapter) == :local_process
    assert System.monotonic_time(:millisecond) - started_at < 1_000
  end

  test "atomically caps local holders and stale or foreign releases cannot free them" do
    server = start_limiter(max_total_runs: 2, max_local_runs: 1, memory_check?: false)
    assert {:ok, token} = RuntimeAdmission.checkout(LocalAdapter, server)

    foreign = Task.async(fn -> RuntimeAdmission.release(token, server) end)
    assert Task.await(foreign) == :ok

    assert {:error, :local_slots_exhausted} =
             Task.async(fn -> RuntimeAdmission.checkout(LocalAdapter, server) end)
             |> Task.await()

    assert :ok = RuntimeAdmission.release(make_ref(), server)
    assert {:error, :local_slots_exhausted} = RuntimeAdmission.available(LocalAdapter, server)

    assert :ok = RuntimeAdmission.release(token, server)
    assert :ok = RuntimeAdmission.available(LocalAdapter, server)
  end

  test "reclaims capacity when a holder exits" do
    server = start_limiter(max_local_runs: 1, memory_check?: false)
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:held, RuntimeAdmission.checkout(LocalAdapter, server)})
      end)

    assert_receive {:held, {:ok, _token}}
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
    assert eventually(fn -> RuntimeAdmission.available(LocalAdapter, server) == :ok end)
  end

  test "a stale monitor DOWN cannot release a live holder" do
    parent = self()
    server = start_limiter(max_local_runs: 1, memory_check?: false)

    holder =
      spawn(fn ->
        {:ok, token} = RuntimeAdmission.checkout(LocalAdapter, server)
        send(parent, {:live_holder, self(), token})

        receive do
          :release -> RuntimeAdmission.release(token, server)
        end
      end)

    assert_receive {:live_holder, ^holder, token}
    stale_monitor = make_ref()

    :sys.replace_state(server, fn state ->
      %{state | monitors: Map.put(state.monitors, stale_monitor, token)}
    end)

    send(server, {:DOWN, stale_monitor, :process, holder, :normal})
    assert eventually(fn -> not Map.has_key?(:sys.get_state(server).monitors, stale_monitor) end)
    assert RuntimeAdmission.snapshot(server).total_running == 1
    assert {:error, :local_slots_exhausted} = RuntimeAdmission.available(LocalAdapter, server)

    send(holder, :release)
    assert eventually(fn -> RuntimeAdmission.snapshot(server).total_running == 0 end)
  end

  test "a controller may release an adopted claim only after its worker is dead" do
    server = start_limiter(max_total_runs: 1, max_local_runs: 1, memory_check?: false)
    assert {:ok, token} = RuntimeAdmission.checkout(LocalAdapter, server)

    live_worker = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = RuntimeAdmission.adopt(token, live_worker, server)
    assert :ok = RuntimeAdmission.release(token, server)
    assert {:error, :total_slots_exhausted} = RuntimeAdmission.available(GatewayAdapter, server)

    dead_worker = spawn(fn -> :ok end)
    dead_monitor = Process.monitor(dead_worker)
    assert_receive {:DOWN, ^dead_monitor, :process, ^dead_worker, _reason}

    # Put the already-dead holder into state without a queued manager DOWN so
    # this deterministically exercises the controller's post-wait release path.
    :sys.replace_state(server, fn state ->
      holder = Map.fetch!(state.holders, token)
      Process.demonitor(holder.monitor, [:flush])
      replacement_monitor = make_ref()

      %{
        state
        | holders:
            Map.put(state.holders, token, %{
              holder
              | pid: dead_worker,
                monitor: replacement_monitor
            }),
          monitors:
            state.monitors
            |> Map.delete(holder.monitor)
            |> Map.put(replacement_monitor, token)
      }
    end)

    Process.exit(live_worker, :kill)
    assert :ok = RuntimeAdmission.release(token, server)
    assert :ok = RuntimeAdmission.available(GatewayAdapter, server)
  end

  test "local saturation preserves gateway capacity until the total gate fills" do
    server = start_limiter(max_total_runs: 2, max_local_runs: 1, memory_check?: false)
    assert {:ok, local_token} = RuntimeAdmission.checkout(LocalAdapter, server)

    assert :ok = RuntimeAdmission.available(GatewayAdapter, server)
    parent = self()

    gateway =
      spawn(fn ->
        {:ok, token} = RuntimeAdmission.checkout(GatewayAdapter, server)
        send(parent, {:gateway_token, token})
        receive do: (:release -> RuntimeAdmission.release(token, server))
      end)

    assert_receive {:gateway_token, gateway_token}
    assert is_reference(gateway_token)
    assert {:error, :total_slots_exhausted} = RuntimeAdmission.available(GatewayAdapter, server)
    assert {:error, :total_slots_exhausted} = RuntimeAdmission.checkout(LocalAdapter, server)

    assert %{
             total_running: 2,
             local_running: 1,
             gateway_running: 1,
             max_total_runs: 2,
             max_local_runs: 1
           } = RuntimeAdmission.snapshot(server)

    send(gateway, :release)
    assert eventually(fn -> RuntimeAdmission.available(GatewayAdapter, server) == :ok end)

    GenServer.stop(server)
    assert {:error, :admission_unavailable} = RuntimeAdmission.available(GatewayAdapter, server)
    assert {:error, :admission_unavailable} = RuntimeAdmission.checkout(GatewayAdapter, server)
    assert {:error, :admission_unavailable} = RuntimeAdmission.checkout(LocalAdapter, server)
    assert :ok = RuntimeAdmission.release(local_token, server)
  end

  test "memory reserve, unknown samples, and TTL decisions are deterministic" do
    {:ok, clock} = Agent.start_link(fn -> 10 end)
    {:ok, samples} = Agent.start_link(fn -> [{:ok, sample(900)}, {:ok, sample(50)}] end)

    sampler = fn -> Agent.get_and_update(samples, fn [next | rest] -> {next, rest} end) end
    now = fn -> Agent.get(clock, & &1) end

    server =
      start_limiter(
        sampler: sampler,
        clock: now,
        max_total_runs: 3,
        max_local_runs: 2,
        memory_check?: true,
        memory_reserve_bytes: 100,
        sample_ttl_ms: 5
      )

    assert :ok = RuntimeAdmission.available(LocalAdapter, server)
    assert :ok = RuntimeAdmission.available(LocalAdapter, server)
    Agent.update(clock, fn _ -> 16 end)
    assert {:error, :host_memory_low} = RuntimeAdmission.available(LocalAdapter, server)

    unknown =
      start_limiter(memory_check?: true, sampler: fn -> {:error, {:raw, "/path"}} end)

    assert {:error, :host_memory_unknown} = RuntimeAdmission.available(LocalAdapter, unknown)
    assert :ok = RuntimeAdmission.available(GatewayAdapter, unknown)

    assert {:ok, gateway_token} = RuntimeAdmission.checkout(GatewayAdapter, unknown)
    assert is_reference(gateway_token)
    assert :ok = RuntimeAdmission.release(gateway_token, unknown)
  end

  test "a non-returning memory sampler times out without blocking the manager" do
    parent = self()

    server =
      start_limiter(
        max_total_runs: 2,
        max_local_runs: 1,
        memory_check?: true,
        sample_timeout_ms: 25,
        sampler: fn ->
          Process.flag(:trap_exit, true)
          send(parent, {:sampler_started, self()})
          receive do: (:never -> {:error, :unexpected})
        end
      )

    checkout = Task.async(fn -> RuntimeAdmission.checkout(LocalAdapter, server) end)
    assert_receive {:sampler_started, sampler_pid}
    sampler_monitor = Process.monitor(sampler_pid)

    # The sampler is isolated: unrelated gateway admission and snapshots remain
    # responsive while the local caller waits for the bounded timeout.
    assert :ok = RuntimeAdmission.available(GatewayAdapter, server)
    assert %{reason: :host_memory_unknown} = RuntimeAdmission.snapshot(server)
    assert Task.await(checkout, 1_000) == {:error, :host_memory_unknown}
    assert_receive {:DOWN, ^sampler_monitor, :process, ^sampler_pid, _reason}, 1_000
    assert Process.alive?(server)
  end

  test "a non-returning sampler dies if its admission manager stops" do
    parent = self()

    server =
      start_limiter(
        memory_check?: true,
        sample_timeout_ms: 1_000,
        sampler: fn ->
          Process.flag(:trap_exit, true)
          send(parent, {:manager_stop_sampler, self()})
          receive do: (:never -> {:error, :unexpected})
        end
      )

    checkout = Task.async(fn -> RuntimeAdmission.checkout(LocalAdapter, server) end)
    assert_receive {:manager_stop_sampler, sampler_pid}
    sampler_monitor = Process.monitor(sampler_pid)

    Process.exit(server, :kill)
    assert_receive {:DOWN, ^sampler_monitor, :process, ^sampler_pid, _reason}, 1_000
    assert Task.await(checkout, 1_000) == {:error, :admission_unavailable}
  end

  test "concurrent memory waiters share one bounded sample" do
    parent = self()

    server =
      start_limiter(
        memory_check?: true,
        sampler: fn ->
          send(parent, {:queued_sampler, self()})
          receive do: (:sample -> {:ok, sample(900)})
        end
      )

    tasks =
      for _ <- 1..200 do
        Task.async(fn -> RuntimeAdmission.available(LocalAdapter, server) end)
      end

    assert_receive {:queued_sampler, sampler}

    assert eventually(fn ->
             %{sampling: %{waiters: waiters}} = :sys.get_state(server)
             :queue.len(waiters) == 200
           end)

    send(sampler, :sample)
    assert Enum.all?(tasks, &(Task.await(&1, 1_000) == :ok))
  end

  test "each admitted local checkout invalidates the cached start sample" do
    parent = self()
    {:ok, samples} = Agent.start_link(fn -> [{:ok, sample(900)}, {:ok, sample(50)}] end)

    server =
      start_limiter(
        max_total_runs: 3,
        max_local_runs: 2,
        memory_check?: true,
        memory_reserve_bytes: 100,
        sample_ttl_ms: 60_000,
        sampler: fn -> Agent.get_and_update(samples, fn [next | rest] -> {next, rest} end) end
      )

    first =
      spawn(fn ->
        result = RuntimeAdmission.checkout(LocalAdapter, server)
        {:ok, token} = result
        :ok = RuntimeAdmission.local_process_started(token, server)
        send(parent, {:first_checkout, result})

        receive do
          {:release, token} -> RuntimeAdmission.release(token, server)
        end
      end)

    assert_receive {:first_checkout, {:ok, first_token}}

    assert {:error, :host_memory_low} =
             Task.async(fn -> RuntimeAdmission.checkout(LocalAdapter, server) end)
             |> Task.await()

    send(first, {:release, first_token})
  end

  test "a local start handshake blocks bursts, rejects foreign marks, then resamples" do
    parent = self()
    {:ok, samples} = Agent.start_link(fn -> [{:ok, sample(900)}, {:ok, sample(50)}] end)

    server =
      start_limiter(
        max_total_runs: 3,
        max_local_runs: 2,
        memory_check?: true,
        memory_reserve_bytes: 100,
        sample_ttl_ms: 60_000,
        sampler: fn -> Agent.get_and_update(samples, fn [next | rest] -> {next, rest} end) end
      )

    holder =
      spawn(fn ->
        {:ok, token} = RuntimeAdmission.checkout(LocalAdapter, server)
        send(parent, {:pending_local_claim, self(), token})

        receive do
          {:mark_started, ^token} ->
            send(
              parent,
              {:marked_local_claim, RuntimeAdmission.local_process_started(token, server)}
            )

            receive do
              :release -> RuntimeAdmission.release(token, server)
            end
        end
      end)

    assert_receive {:pending_local_claim, ^holder, token}
    assert {:error, :local_slots_exhausted} = RuntimeAdmission.available(LocalAdapter, server)
    assert :ok = RuntimeAdmission.available(GatewayAdapter, server)

    assert {:error, :not_claim_holder} = RuntimeAdmission.local_process_started(token, server)
    assert {:error, :local_slots_exhausted} = RuntimeAdmission.available(LocalAdapter, server)

    send(holder, {:mark_started, token})
    assert_receive {:marked_local_claim, :ok}
    assert {:error, :host_memory_low} = RuntimeAdmission.available(LocalAdapter, server)

    send(holder, :release)
  end

  test "a holder that never opens its Port keeps later local starts fail-closed" do
    parent = self()

    server =
      start_limiter(
        max_total_runs: 3,
        max_local_runs: 2,
        memory_check?: true,
        memory_reserve_bytes: 100,
        sampler: fn -> {:ok, sample(900)} end
      )

    holder =
      spawn(fn ->
        {:ok, token} = RuntimeAdmission.checkout(LocalAdapter, server)
        send(parent, {:hung_pre_port, token})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:hung_pre_port, _token}
    assert {:error, :local_slots_exhausted} = RuntimeAdmission.checkout(LocalAdapter, server)
    assert :ok = RuntimeAdmission.available(GatewayAdapter, server)

    monitor = Process.monitor(holder)
    send(holder, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^holder, _reason}
    assert eventually(fn -> RuntimeAdmission.snapshot(server).local_running == 0 end)
  end

  test "recovery conservatively counts local and unknown live holders" do
    local = spawn(fn -> Process.sleep(:infinity) end)
    gateway = spawn(fn -> Process.sleep(:infinity) end)
    unknown = spawn(fn -> Process.sleep(:infinity) end)

    server =
      start_limiter(
        max_local_runs: 2,
        memory_check?: false,
        recover_fun: fn ->
          [
            %{pid: local, execution_class: :local_process, adoptable?: true},
            %{pid: gateway, execution_class: :gateway, adoptable?: true},
            %{pid: unknown, execution_class: :local_process, adoptable?: true}
          ]
        end
      )

    assert %{total_running: 3, local_running: 2, gateway_running: 1, recovery_status: :ok} =
             RuntimeAdmission.snapshot(server)

    assert {:error, :total_slots_exhausted} = RuntimeAdmission.available(LocalAdapter, server)
    assert {:error, :total_slots_exhausted} = RuntimeAdmission.available(GatewayAdapter, server)

    Process.exit(local, :kill)
    assert eventually(fn -> RuntimeAdmission.available(LocalAdapter, server) == :ok end)
    Process.exit(gateway, :kill)
    Process.exit(unknown, :kill)
  end

  test "failed recovery prevents the limiter from starting" do
    assert_start_error(:recovery_failed,
      name: nil,
      memory_check?: false,
      recover_fun: fn -> raise "database detail" end
    )
  end

  test "rejects incoherent total and local limits at startup" do
    assert_start_error(:invalid_limits,
      name: nil,
      max_total_runs: 1,
      max_local_runs: 2,
      recover_fun: fn -> [] end
    )
  end

  test "a recovered claim requires both its exact token and holder caller to release" do
    parent = self()
    token = make_ref()

    holder =
      spawn(fn ->
        loop = fn loop ->
          receive do
            {:release, supplied_token, server} ->
              send(parent, {:released, RuntimeAdmission.release(supplied_token, server)})
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    server =
      start_limiter(
        max_total_runs: 1,
        max_local_runs: 1,
        memory_check?: false,
        recover_fun: fn ->
          [
            %{
              holder_pid: holder,
              controller_pid: holder,
              token: token,
              execution_class: :local_process
            }
          ]
        end
      )

    assert :ok = RuntimeAdmission.release(token, server)
    assert :ok = RuntimeAdmission.release(make_ref(), server)
    assert {:error, :total_slots_exhausted} = RuntimeAdmission.available(LocalAdapter, server)

    send(holder, {:release, make_ref(), server})
    assert_receive {:released, :ok}
    assert {:error, :total_slots_exhausted} = RuntimeAdmission.available(LocalAdapter, server)

    send(holder, {:release, token, server})
    assert_receive {:released, :ok}
    assert eventually(fn -> RuntimeAdmission.available(LocalAdapter, server) == :ok end)
    Process.exit(holder, :kill)
  end

  test "duplicate explicit recovery tokens fail startup closed" do
    token = make_ref()
    first = spawn(fn -> Process.sleep(:infinity) end)
    second = spawn(fn -> Process.sleep(:infinity) end)

    candidates =
      Enum.map([first, second], fn pid ->
        %{
          holder_pid: pid,
          controller_pid: pid,
          token: token,
          execution_class: :gateway
        }
      end)

    assert_start_error(:recovery_failed,
      name: nil,
      memory_check?: false,
      recover_fun: fn -> candidates end
    )

    Process.exit(first, :kill)
    Process.exit(second, :kill)
  end

  test "duplicate tokens discovered during recovery keep admission fail-closed" do
    token = make_ref()

    {:ok, first} =
      GenServer.start(RecoveryClaimServer, %{token: token, execution_class: :gateway})

    {:ok, second} =
      GenServer.start(RecoveryClaimServer, %{token: token, execution_class: :gateway})

    on_exit(fn ->
      if Process.alive?(first), do: Process.exit(first, :kill)
      if Process.alive?(second), do: Process.exit(second, :kill)
    end)

    server =
      start_limiter(
        max_total_runs: 2,
        max_local_runs: 1,
        memory_check?: false,
        recover_fun: fn -> [%{recovery_pid: first}, %{recovery_pid: second}] end
      )

    assert eventually(
             fn ->
               match?(
                 %{recovery_status: :recovering, total_running: 1},
                 RuntimeAdmission.snapshot(server)
               )
             end,
             200
           )

    assert {:error, :admission_unavailable} = RuntimeAdmission.available(GatewayAdapter, server)
  end

  test "many busy recovery candidates cannot block the manager for a whole pass" do
    candidates =
      for _ <- 1..12 do
        {:ok, pid} = GenServer.start(BlockingRecoveryCandidate, self())
        pid
      end

    on_exit(fn ->
      Enum.each(candidates, fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)
    end)

    started_at = System.monotonic_time(:millisecond)

    server =
      start_limiter(
        max_total_runs: 12,
        max_local_runs: 1,
        memory_check?: false,
        recover_fun: fn -> Enum.map(candidates, &%{recovery_pid: &1}) end
      )

    assert System.monotonic_time(:millisecond) - started_at < 300
    assert %{recovery_status: :recovering} = RuntimeAdmission.snapshot(server)
    assert_receive {:recovery_candidate_called, _pid}, 500

    snapshot_started_at = System.monotonic_time(:millisecond)

    assert %{recovery_status: :recovering, reason: :admission_unavailable} =
             RuntimeAdmission.snapshot(server)

    assert System.monotonic_time(:millisecond) - snapshot_started_at < 300
  end

  test "denial counters and monotonic denial age are bounded snapshot fields" do
    {:ok, clock} = Agent.start_link(fn -> 40 end)

    server =
      start_limiter(
        clock: fn -> Agent.get(clock, & &1) end,
        sampler: fn -> {:ok, sample(100)} end,
        memory_check?: true,
        memory_reserve_bytes: 100
      )

    assert {:error, :host_memory_low} = RuntimeAdmission.available(LocalAdapter, server)
    Agent.update(clock, &(&1 + 7))

    assert %{
             last_denial_reason: :host_memory_low,
             last_denial_age_ms: 7,
             denial_counts: %{
               total_slots_exhausted: 0,
               host_memory_low: 1,
               host_memory_unknown: 0,
               local_slots_exhausted: 0,
               admission_unavailable: 0
             }
           } = RuntimeAdmission.snapshot(server)
  end

  test "the supervised limiter is ordered after the registry and default recovery finds sessions" do
    assert is_pid(Process.whereis(RuntimeAdmission))
    assert is_pid(Process.whereis(Cympho.OrchestratorRegistry))

    key = "runtime-admission-recovery-#{System.unique_integer([:positive])}"
    orchestrator = start_supervised!({RecoverableOrchestrator, {key, LocalAdapter}})
    idle_key = "runtime-admission-idle-#{System.unique_integer([:positive])}"
    idle = start_supervised!({IdleOrchestrator, idle_key})
    server = start_limiter(max_total_runs: 1, max_local_runs: 1, memory_check?: false)

    assert eventually(fn -> RuntimeAdmission.snapshot(server).recovery_status == :ok end, 100)
    assert %{local_running: running, recovery_status: :ok} = RuntimeAdmission.snapshot(server)
    assert running >= 1
    assert {:error, :total_slots_exhausted} = RuntimeAdmission.available(LocalAdapter, server)
    assert Process.alive?(orchestrator)
    assert Process.alive?(idle)
  end

  test "default recovery retains an adopted worker after its controller disappears" do
    old_manager = start_limiter(max_total_runs: 1, max_local_runs: 1, memory_check?: false)
    parent = self()
    session_id = make_ref()

    controller =
      spawn(fn ->
        {:ok, token} = RuntimeAdmission.checkout(LocalAdapter, old_manager)

        worker =
          Cympho.AdapterSessions.spawn_registered(
            session_id,
            [runtime_admission_claim: {token, old_manager, :local_process}],
            fn ->
              send(parent, {:adopted_recovery_worker, self(), token})

              receive do
                :stop -> :ok
              end
            end
          )

        send(parent, {:adopted_from_controller, worker})
      end)

    controller_monitor = Process.monitor(controller)
    assert_receive {:adopted_recovery_worker, worker, old_token}
    assert_receive {:adopted_from_controller, ^worker}
    assert_receive {:DOWN, ^controller_monitor, :process, ^controller, _reason}
    assert Process.alive?(worker)

    GenServer.stop(old_manager)
    restarted = start_limiter(max_total_runs: 1, max_local_runs: 1, memory_check?: false)

    assert %{recovery_status: :ok, total_running: 1, local_running: 1} =
             RuntimeAdmission.snapshot(restarted)

    assert {:error, :total_slots_exhausted} = RuntimeAdmission.available(LocalAdapter, restarted)
    assert :ok = RuntimeAdmission.release(old_token, restarted)
    assert RuntimeAdmission.snapshot(restarted).total_running == 1

    send(worker, :stop)
    assert eventually(fn -> RuntimeAdmission.snapshot(restarted).total_running == 0 end)
  end

  test "restart preserves a gated pre-Port worker until its start handshake" do
    old_manager =
      start_limiter(
        max_total_runs: 3,
        max_local_runs: 2,
        memory_check?: true,
        memory_reserve_bytes: 100,
        sampler: fn -> {:ok, sample(900)} end
      )

    parent = self()
    session_id = make_ref()

    controller =
      spawn(fn ->
        {:ok, token} = RuntimeAdmission.checkout(LocalAdapter, old_manager)

        worker =
          Cympho.AdapterSessions.spawn_registered(
            session_id,
            [runtime_admission_claim: {token, old_manager, :local_process}],
            fn ->
              send(parent, {:gated_restart_worker, self(), token})

              receive do
                {:port_opened, restarted} ->
                  :ok = Cympho.AdapterSessions.local_process_started(session_id)
                  result = RuntimeAdmission.local_process_started(token, restarted)
                  send(parent, {:gated_restart_marked, result})

                  receive do
                    :stop -> :ok
                  end
              end
            end
          )

        send(parent, {:gated_restart_adopted, worker})
      end)

    controller_monitor = Process.monitor(controller)
    assert_receive {:gated_restart_worker, worker, token}
    assert_receive {:gated_restart_adopted, ^worker}
    assert_receive {:DOWN, ^controller_monitor, :process, ^controller, _reason}

    GenServer.stop(old_manager)

    restarted =
      start_limiter(
        max_total_runs: 3,
        max_local_runs: 2,
        memory_check?: true,
        memory_reserve_bytes: 100,
        sampler: fn -> {:ok, sample(900)} end
      )

    assert %{total_running: 1, local_running: 1} = RuntimeAdmission.snapshot(restarted)
    assert {:error, :local_slots_exhausted} = RuntimeAdmission.available(LocalAdapter, restarted)
    assert :ok = RuntimeAdmission.available(GatewayAdapter, restarted)

    send(worker, {:port_opened, restarted})
    assert_receive {:gated_restart_marked, :ok}
    assert :ok = RuntimeAdmission.available(LocalAdapter, restarted)

    # The old token remains worker-owned after the restart handshake.
    assert :ok = RuntimeAdmission.release(token, restarted)
    assert RuntimeAdmission.snapshot(restarted).total_running == 1
    send(worker, :stop)
    assert eventually(fn -> RuntimeAdmission.snapshot(restarted).total_running == 0 end)
  end

  test "unconfirmed and preclaim recovery candidates do not invent holders" do
    busy = spawn(fn -> Process.sleep(:infinity) end)

    server =
      start_limiter(
        max_total_runs: 1,
        max_local_runs: 1,
        memory_check?: false,
        recover_fun: fn -> [busy, {busy, LocalAdapter}, %{pid: busy, adapter: LocalAdapter}] end
      )

    assert %{total_running: 0, local_running: 0, gateway_running: 0} =
             RuntimeAdmission.snapshot(server)

    assert {:ok, token} =
             Task.async(fn -> RuntimeAdmission.checkout(LocalAdapter, server) end)
             |> Task.await()

    assert is_reference(token)
    Process.exit(busy, :kill)
  end

  test "default recovery fails closed when a live orchestrator claim cannot be confirmed" do
    key = "runtime-admission-unconfirmed-#{System.unique_integer([:positive])}"
    orchestrator = start_supervised!({UnconfirmedOrchestrator, key})

    server = start_limiter(max_total_runs: 1, max_local_runs: 1, memory_check?: false)

    assert %{recovery_status: :recovering, reason: :admission_unavailable} =
             RuntimeAdmission.snapshot(server)

    assert {:error, :admission_unavailable} = RuntimeAdmission.available(LocalAdapter, server)
    assert {:error, :admission_unavailable} = RuntimeAdmission.available(GatewayAdapter, server)

    assert Process.alive?(orchestrator)
  end

  test "busy preclaim recovery fails closed, then skips only after explicit confirmation" do
    key = "runtime-admission-busy-preclaim-#{System.unique_integer([:positive])}"
    orchestrator = start_supervised!({BusyRecoveryOrchestrator, {key, :preclaim}})

    server = start_limiter(max_total_runs: 1, max_local_runs: 1, memory_check?: false)
    assert %{recovery_status: :recovering} = RuntimeAdmission.snapshot(server)
    assert {:error, :admission_unavailable} = RuntimeAdmission.checkout(LocalAdapter, server)

    send(orchestrator, :unblock)

    assert eventually(fn ->
             case GenServer.call(orchestrator, :runtime_admission_state, 200) do
               %{token: nil, execution_class: nil} -> true
               _ -> false
             end
           end)

    assert eventually(
             fn ->
               match?(
                 %{recovery_status: :ok, total_running: 0},
                 RuntimeAdmission.snapshot(server)
               )
             end,
             700
           )

    assert {:ok, token} = RuntimeAdmission.checkout(LocalAdapter, server)
    assert :ok = RuntimeAdmission.release(token, server)
  end

  test "busy active recovery fails closed until its claim can be confirmed" do
    key = "runtime-admission-busy-active-#{System.unique_integer([:positive])}"
    old_token = make_ref()
    orchestrator = start_supervised!({BusyRecoveryOrchestrator, {key, {:active, old_token}}})

    server = start_limiter(max_total_runs: 1, max_local_runs: 1, memory_check?: false)
    assert %{recovery_status: :recovering} = RuntimeAdmission.snapshot(server)
    assert {:error, :admission_unavailable} = RuntimeAdmission.checkout(GatewayAdapter, server)

    Process.send_after(self(), :busy_long_enough, 1_100)
    assert_receive :busy_long_enough, 1_300
    assert %{recovery_status: :recovering} = RuntimeAdmission.snapshot(server)

    send(orchestrator, :unblock)

    assert eventually(fn ->
             case GenServer.call(orchestrator, :runtime_admission_state, 200) do
               %{token: ^old_token, execution_class: :local_process} -> true
               _ -> false
             end
           end)

    assert eventually(
             fn ->
               match?(
                 %{recovery_status: :ok, total_running: 1, local_running: 1},
                 RuntimeAdmission.snapshot(server)
               )
             end,
             800
           )

    assert {:error, :total_slots_exhausted} = RuntimeAdmission.available(LocalAdapter, server)
  end

  test "telemetry exposes only bounded admission metadata and declared metrics" do
    handler = "runtime-admission-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:cympho, :runtime_admission, :available],
        fn event, measurements, metadata, _config ->
          send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    server = start_limiter(max_total_runs: 1, max_local_runs: 1, memory_check?: false)
    assert :ok = RuntimeAdmission.available(LocalAdapter, server)

    assert_receive {[:cympho, :runtime_admission, :available],
                    %{count: 1, total_running: 0, local_running: 0, gateway_running: 0}, metadata}

    assert Map.keys(metadata) |> Enum.sort() ==
             [:execution_class, :max_local_runs, :max_total_runs, :outcome, :reason]

    assert metadata == %{
             execution_class: :local_process,
             max_local_runs: 1,
             max_total_runs: 1,
             outcome: :available,
             reason: nil
           }

    metric_names = Enum.map(Cympho.Telemetry.Metrics.metrics(), & &1.name)
    assert [:cympho, :runtime_admission, :available, :count] in metric_names
    assert [:cympho, :runtime_admission, :checkout, :local_running] in metric_names
    assert [:cympho, :runtime_admission, :release, :count] in metric_names
  end

  test "the manager normalizes direct malformed execution classes before telemetry or storage" do
    handler = "runtime-admission-normalization-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:cympho, :runtime_admission, :checkout],
        fn _event, _measurements, metadata, _config -> send(test_pid, metadata) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    server = start_limiter(max_total_runs: 1, max_local_runs: 1, memory_check?: false)

    assert {:ok, token} = GenServer.call(server, {:checkout, {:custom, "unbounded"}})
    assert_receive %{execution_class: :local_process, outcome: :admitted}
    assert RuntimeAdmission.snapshot(server).local_running == 1
    assert :ok = RuntimeAdmission.release(token, server)
  end

  defp start_limiter(opts) do
    spec =
      Supervisor.child_spec(
        {RuntimeAdmission, Keyword.put(opts, :name, nil)},
        id: {RuntimeAdmission, make_ref()}
      )

    start_supervised!(spec)
  end

  defp assert_start_error(reason, opts) do
    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        RuntimeAdmission.start_link(opts)
      end)

    assert {:error, ^reason} = Task.await(task)
  end

  defp sample(available) do
    %{available_bytes: available, total_bytes: 1_000, source: :host}
  end

  defp eventually(fun, attempts \\ 30)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(2)
      eventually(fun, attempts - 1)
    end
  end
end
