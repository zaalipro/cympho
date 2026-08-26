defmodule Cympho.AdapterSessions do
  @moduledoc """
  Tracks live adapter worker processes by session id.

  Orchestrators only know the adapter-level session id returned by
  `Adapter.run/4`. This registry gives operator stop paths a small, shared
  way to ask the worker that owns the runtime port to shut down.
  """

  use GenServer

  @registration_timeout_ms 1_000

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  defp register_worker(session_id, pid, metadata) when is_pid(pid) do
    call_if_started({:register, session_id, pid, metadata})
  end

  @doc "Spawns a worker that cannot execute until registration and admission adoption complete."
  def spawn_registered(session_id, opts \\ [], fun)

  def spawn_registered(session_id, opts, fun) when is_list(opts) and is_function(fun, 0) do
    controller = self()
    start_ref = make_ref()
    metadata = Map.put(ledger_metadata(opts), :controller_pid, controller)

    {worker, worker_monitor} =
      spawn_monitor(fn ->
        controller_monitor = Process.monitor(controller)
        worker = self()
        keeper_ref = make_ref()

        keeper =
          spawn(fn ->
            registry_keeper(
              worker,
              session_id,
              Map.put(metadata, :worker_pid, worker),
              keeper_ref
            )
          end)

        receive do
          {__MODULE__, :registry_keeper_ready, ^keeper_ref, ^keeper} ->
            send(controller, {__MODULE__, :worker_registered, start_ref, self(), keeper})

          {:DOWN, ^controller_monitor, :process, ^controller, _reason} ->
            Process.exit(keeper, :kill)
            exit(:normal)
        end

        receive do
          {__MODULE__, :start_registered, ^start_ref} ->
            Process.demonitor(controller_monitor, [:flush])
            fun.()

          {:DOWN, ^controller_monitor, :process, ^controller, _reason} ->
            :ok
        end
      end)

    receive do
      {__MODULE__, :worker_registered, ^start_ref, ^worker, keeper} ->
        Process.demonitor(worker_monitor, [:flush])

        metadata = Map.put(metadata, :registry_keeper, keeper)

        case register_worker(session_id, worker, metadata) do
          :ok ->
            case adopt_runtime_claim(opts, worker) do
              :ok ->
                watcher_ref = make_ref()
                caller = self()

                _watcher =
                  spawn(fn ->
                    watch_controller(controller, worker, session_id, caller, watcher_ref)
                  end)

                receive do
                  {__MODULE__, :controller_watcher_ready, ^watcher_ref} -> :ok
                end

                send(worker, {__MODULE__, :start_registered, start_ref})
                worker

              {:error, reason} ->
                Process.exit(worker, :kill)
                raise "failed to adopt runtime admission claim: #{inspect(reason)}"
            end

          {:error, reason} ->
            Process.exit(worker, :kill)
            raise "failed to register adapter worker: #{inspect(reason)}"
        end

      {:DOWN, ^worker_monitor, :process, ^worker, reason} ->
        raise "failed to register adapter worker: #{inspect(reason)}"
    after
      @registration_timeout_ms ->
        Process.exit(worker, :kill)
        raise "failed to register adapter worker: registry unavailable"
    end
  end

  def unregister(session_id) do
    case call_if_started({:unregister, session_id}) do
      {:error, :not_started} -> :ok
      result -> result
    end
  end

  def cancel(session_id, reason \\ :operator_stop) do
    call_if_started({:cancel, session_id, reason})
  end

  @doc "Returns the live worker registered for a session."
  def owner(session_id), do: call_if_started({:owner, session_id})

  @doc false
  def owner_for_controller(controller_pid) when is_pid(controller_pid) do
    case owners_for_controller(controller_pid) do
      {:ok, [pid | _]} -> {:ok, pid}
      {:ok, []} -> {:error, :not_found}
      error -> error
    end
  end

  @doc false
  def owners_for_controller(controller_pid) when is_pid(controller_pid) do
    call_if_started({:owners_for, :controller_pid, controller_pid})
  end

  @doc false
  def owners_for_issue(issue_id) when is_binary(issue_id) do
    call_if_started({:owners_for, :issue_id, issue_id})
  end

  @doc false
  def owner_for_claim(token) when is_reference(token) do
    call_if_started({:owner_for_claim, token})
  end

  @doc false
  def recovery_claims do
    case active_sessions() do
      {:ok, sessions} ->
        claims =
          Enum.flat_map(sessions, fn
            %{
              pid: holder_pid,
              controller_pid: controller_pid,
              recovery_claim: %{token: token, execution_class: execution_class} = claim
            } ->
              start_pending? = Map.get(claim, :start_pending?, execution_class == :local_process)

              [
                %{
                  token: token,
                  execution_class: execution_class,
                  holder_pid: holder_pid,
                  controller_pid: controller_pid,
                  start_pending?: start_pending?
                }
              ]

            _entry ->
              []
          end)

        {:ok, claims}

      {:error, :not_started} = error ->
        error
    end
  end

  @doc false
  def active_sessions do
    case call_if_started(:active_sessions) do
      sessions when is_list(sessions) -> {:ok, sessions}
      {:error, :not_started} = error -> error
    end
  end

  @doc false
  def cancel_for_issue(issue_id, reason) when is_binary(issue_id) do
    call_if_started({:cancel_for_issue, issue_id, reason})
  end

  @doc "Requests cancellation and waits until the registered worker exits."
  def cancel_and_wait(session_id, reason, timeout \\ 10_000) do
    case cancel_owner(session_id, reason) do
      {:ok, pid} -> await_worker(pid, timeout)
      {:error, :not_found} -> :ok
      {:error, :not_started} = error -> error
    end
  end

  @doc "Waits until the registered worker exits without requesting cancellation."
  def wait_for_exit(session_id, timeout \\ 10_000) do
    case owner(session_id) do
      {:ok, pid} -> await_worker(pid, timeout)
      {:error, :not_found} -> :ok
      {:error, :not_started} = error -> error
    end
  end

  def registered?(session_id) do
    case owner(session_id) do
      {:ok, _pid} -> true
      {:error, :not_found} -> false
      {:error, :not_started} -> true
    end
  end

  @doc false
  def local_process_started(session_id) do
    call_if_started({:local_process_started, session_id, self()})
  end

  def run_cancellable(session_id, fun) when is_function(fun, 0) do
    caller = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(caller, {__MODULE__, :cancellable_result, self(), fun.()})
      end)

    receive do
      {__MODULE__, :cancellable_result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:cancel_session, ^session_id, reason} ->
        Process.exit(pid, :kill)
        flush_request_down(ref, pid)
        {:error, {:cancelled, reason}}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:request_process_exit, reason}}
    end
  end

  defp flush_request_down(ref, pid) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      100 -> :ok
    end
  end

  ## Server

  @impl true
  def init(_opts) do
    {:ok, rebuild_from_registry()}
  end

  @impl true
  def handle_call({:owner, session_id}, _from, state) do
    reply =
      case Map.get(state.sessions, session_id) do
        %{pid: pid} when is_pid(pid) -> live_owner(pid)
        nil -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:owners_for, field, value}, _from, state) do
    owners =
      state.sessions
      |> Map.values()
      |> Enum.filter(&(Map.get(&1, field) == value and Process.alive?(&1.pid)))
      |> Enum.map(& &1.pid)
      |> Enum.uniq()

    {:reply, {:ok, owners}, state}
  end

  def handle_call({:owner_for_claim, token}, _from, state) do
    owner =
      Enum.find_value(state.sessions, fn
        {_session_id, %{pid: pid, recovery_claim: %{token: ^token}}} ->
          if Process.alive?(pid), do: pid

        _ ->
          nil
      end)

    {:reply, if(owner, do: {:ok, owner}, else: {:error, :not_found}), state}
  end

  def handle_call(:active_sessions, _from, state) do
    sessions =
      state.sessions
      |> Enum.flat_map(fn {session_id, session} ->
        if Process.alive?(session.pid) do
          [
            %{
              session_id: session_id,
              pid: session.pid,
              controller_pid: session.controller_pid,
              recovery_claim: session.recovery_claim,
              issue_id: session.issue_id
            }
          ]
        else
          []
        end
      end)

    {:reply, sessions, state}
  end

  def handle_call({:cancel_for_issue, issue_id, reason}, _from, state) do
    workers =
      state.sessions
      |> Enum.flat_map(fn
        {session_id, %{pid: pid, issue_id: ^issue_id}} when is_pid(pid) ->
          if Process.alive?(pid) do
            send(pid, {:cancel_session, session_id, reason})
            [pid]
          else
            []
          end

        _ ->
          []
      end)
      |> Enum.uniq()

    {:reply, {:ok, workers}, state}
  end

  def handle_call({:local_process_started, session_id, caller}, _from, state) do
    case Map.get(state.sessions, session_id) do
      %{pid: ^caller} = session ->
        claim =
          case session.recovery_claim do
            %{} = claim -> Map.put(claim, :start_pending?, false)
            nil -> nil
          end

        session = %{session | recovery_claim: claim}

        case update_registry_metadata(session) do
          :ok -> {:reply, :ok, put_in(state.sessions[session_id], session)}
          {:error, _reason} = error -> {:reply, error, state}
        end

      %{pid: _other} ->
        {:reply, {:error, :not_owner}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(
        {:register, session_id, pid, metadata},
        {controller_pid, _tag},
        state
      ) do
    metadata = metadata || %{recovery_claim: nil, issue_id: nil}

    cond do
      match?(%{pid: ^pid}, Map.get(state.sessions, session_id)) ->
        {:reply, :ok, state}

      Map.has_key?(state.sessions, session_id) ->
        {:reply, {:error, :session_already_registered}, state}

      Process.alive?(pid) ->
        ref = Process.monitor(pid)
        keeper_ref = Process.monitor(metadata.registry_keeper)

        {:reply, :ok,
         %{
           state
           | sessions:
               Map.put(state.sessions, session_id, %{
                 pid: pid,
                 ref: ref,
                 keeper_ref: keeper_ref,
                 controller_pid: controller_pid,
                 recovery_claim: metadata.recovery_claim,
                 issue_id: metadata.issue_id,
                 registry_keeper: metadata.registry_keeper
               }),
             monitors:
               state.monitors
               |> Map.put(ref, {:worker, session_id})
               |> Map.put(keeper_ref, {:keeper, session_id})
         }}

      true ->
        {:reply, {:error, :worker_not_alive}, state}
    end
  end

  def handle_call({:keeper_registered, session_id, pid, keeper, metadata}, _from, state) do
    case Map.get(state.sessions, session_id) do
      %{pid: ^pid} = session ->
        old_keeper_ref = session.keeper_ref
        Process.demonitor(old_keeper_ref, [:flush])
        keeper_ref = Process.monitor(keeper)
        session = %{session | registry_keeper: keeper, keeper_ref: keeper_ref}

        monitors =
          state.monitors
          |> Map.delete(old_keeper_ref)
          |> Map.put(keeper_ref, {:keeper, session_id})

        {:reply, :ok,
         %{state | sessions: Map.put(state.sessions, session_id, session), monitors: monitors}}

      nil ->
        if Process.alive?(pid) do
          ref = Process.monitor(pid)
          keeper_ref = Process.monitor(keeper)

          session = %{
            pid: pid,
            ref: ref,
            keeper_ref: keeper_ref,
            controller_pid: metadata.controller_pid,
            recovery_claim: metadata.recovery_claim,
            issue_id: metadata.issue_id,
            registry_keeper: keeper
          }

          monitors =
            state.monitors
            |> Map.put(ref, {:worker, session_id})
            |> Map.put(keeper_ref, {:keeper, session_id})

          {:reply, :ok,
           %{state | sessions: Map.put(state.sessions, session_id, session), monitors: monitors}}
        else
          {:reply, {:error, :worker_not_alive}, state}
        end

      _other ->
        {:reply, {:error, :session_already_registered}, state}
    end
  end

  def handle_call({:unregister, session_id}, {caller_pid, _tag}, state) do
    case Map.get(state.sessions, session_id) do
      # Adapter workers unregister from their `after` block immediately before
      # exiting. Keep the entry until the monitor observes that exit so callers
      # can never confuse "cleanup started" with "worker is gone".
      %{pid: ^caller_pid} -> {:reply, :ok, state}
      _other -> {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:cancel, session_id, reason}, _from, state) do
    case Map.get(state.sessions, session_id) do
      %{pid: pid} ->
        send(pid, {:cancel_session, session_id, reason})
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:cancel_owner, session_id, reason}, _from, state) do
    case Map.get(state.sessions, session_id) do
      %{pid: pid} ->
        send(pid, {:cancel_session, session_id, reason})
        {:reply, {:ok, pid}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:registered?, session_id}, _from, state) do
    {:reply, Map.has_key?(state.sessions, session_id), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {{:worker, session_id}, monitors} ->
        if session = Map.get(state.sessions, session_id) do
          Process.demonitor(session.keeper_ref, [:flush])
          Process.exit(session.registry_keeper, :kill)
        end

        {:noreply,
         %{
           state
           | sessions: Map.delete(state.sessions, session_id),
             monitors: Map.delete(monitors, session && session.keeper_ref)
         }}

      {{:keeper, session_id}, monitors} ->
        case Map.get(state.sessions, session_id) do
          %{pid: worker} = session when is_pid(worker) ->
            if Process.alive?(worker) do
              keeper = spawn_registry_keeper(worker, session_id, session_metadata(session), nil)
              keeper_ref = Process.monitor(keeper)
              session = %{session | registry_keeper: keeper, keeper_ref: keeper_ref}

              {:noreply,
               %{
                 state
                 | sessions: Map.put(state.sessions, session_id, session),
                   monitors: Map.put(monitors, keeper_ref, {:keeper, session_id})
               }}
            else
              {:noreply,
               %{
                 state
                 | sessions: Map.delete(state.sessions, session_id),
                   monitors: Map.delete(monitors, session.ref)
               }}
            end

          nil ->
            {:noreply, %{state | monitors: monitors}}
        end
    end
  end

  defp cancel_owner(session_id, reason) do
    call_if_started({:cancel_owner, session_id, reason})
  end

  defp await_worker(pid, timeout) do
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, :worker_exit_timeout}
    end
  end

  defp adopt_runtime_claim(opts, worker) do
    case Keyword.get(opts, :runtime_admission_claim) do
      {token, server, _execution_class} when is_reference(token) ->
        Cympho.RuntimeAdmission.adopt(token, worker, server)

      {token, server} when is_reference(token) ->
        Cympho.RuntimeAdmission.adopt(token, worker, server)

      _none ->
        :ok
    end
  end

  defp recovery_claim(opts) do
    case Keyword.get(opts, :runtime_admission_claim) do
      {token, _server, execution_class}
      when is_reference(token) and execution_class in [:local_process, :gateway] ->
        %{
          token: token,
          execution_class: execution_class,
          start_pending?: execution_class == :local_process
        }

      _none ->
        nil
    end
  end

  defp ledger_metadata(opts) do
    %{
      recovery_claim: recovery_claim(opts),
      issue_id: Keyword.get(opts, :runtime_issue_id) || runtime_context_issue_id(opts)
    }
  end

  defp runtime_context_issue_id(opts) do
    case Keyword.get(opts, :runtime_context) do
      %{issue_id: issue_id} when is_binary(issue_id) -> issue_id
      _ -> nil
    end
  end

  defp watch_controller(controller, worker, session_id, caller, ready_ref) do
    controller_monitor = Process.monitor(controller)
    worker_monitor = Process.monitor(worker)
    send(caller, {__MODULE__, :controller_watcher_ready, ready_ref})

    receive do
      {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
        Process.demonitor(controller_monitor, [:flush])
        :ok

      {:DOWN, ^controller_monitor, :process, ^controller, _reason} ->
        send(worker, {:cancel_session, session_id, :owner_down})
        await_watched_worker(worker_monitor, worker)
    end
  end

  defp await_watched_worker(worker_monitor, worker) do
    receive do
      {:DOWN, ^worker_monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp rebuild_from_registry do
    Enum.reduce(registry_entries(), %{sessions: %{}, monitors: %{}}, fn
      {session_id, keeper, %{worker_pid: pid} = value}, state when is_pid(pid) ->
        ref = Process.monitor(pid)
        keeper_ref = Process.monitor(keeper)

        session = %{
          pid: pid,
          ref: ref,
          keeper_ref: keeper_ref,
          controller_pid: Map.get(value, :controller_pid),
          recovery_claim: Map.get(value, :recovery_claim),
          issue_id: Map.get(value, :issue_id),
          registry_keeper: keeper
        }

        %{
          state
          | sessions: Map.put(state.sessions, session_id, session),
            monitors:
              state.monitors
              |> Map.put(ref, {:worker, session_id})
              |> Map.put(keeper_ref, {:keeper, session_id})
        }

      _entry, state ->
        state
    end)
  end

  defp registry_entries do
    Registry.select(__MODULE__.Registry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
    ])
  end

  defp live_owner(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_found}
  end

  defp call_if_started(message) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      server -> GenServer.call(server, message)
    end
  catch
    :exit, _ -> {:error, :not_started}
  end

  defp registry_keeper(worker, session_id, metadata, ready_ref) do
    worker_monitor = Process.monitor(worker)
    register_keeper(worker, worker_monitor, session_id, metadata, ready_ref, true)
  end

  defp spawn_registry_keeper(worker, session_id, metadata, ready_ref) do
    spawn(fn -> registry_keeper(worker, session_id, metadata, ready_ref) end)
  end

  defp register_keeper(worker, worker_monitor, session_id, metadata, ready_ref, notify?) do
    case Process.whereis(__MODULE__.Registry) do
      registry when is_pid(registry) ->
        registry_monitor = Process.monitor(registry)

        case safe_registry_register(session_id, metadata) do
          {:ok, _} ->
            case register_keeper_with_ledger(session_id, worker, metadata) do
              :ok ->
                if notify?,
                  do: send(worker, {__MODULE__, :registry_keeper_ready, ready_ref, self()})

                keeper_loop(
                  worker,
                  worker_monitor,
                  registry,
                  registry_monitor,
                  session_id,
                  metadata
                )

              {:error, _reason} ->
                Process.demonitor(registry_monitor, [:flush])

                wait_for_registry(
                  worker,
                  worker_monitor,
                  session_id,
                  metadata,
                  ready_ref,
                  notify?
                )
            end

          {:error, {:already_registered, owner}} when owner == self() ->
            case register_keeper_with_ledger(session_id, worker, metadata) do
              :ok ->
                if notify?,
                  do: send(worker, {__MODULE__, :registry_keeper_ready, ready_ref, self()})

                keeper_loop(
                  worker,
                  worker_monitor,
                  registry,
                  registry_monitor,
                  session_id,
                  metadata
                )

              {:error, _reason} ->
                Process.demonitor(registry_monitor, [:flush])

                wait_for_registry(
                  worker,
                  worker_monitor,
                  session_id,
                  metadata,
                  ready_ref,
                  notify?
                )
            end

          {:error, {:already_registered, _other_owner}} ->
            Process.demonitor(registry_monitor, [:flush])
            wait_for_registry(worker, worker_monitor, session_id, metadata, ready_ref, notify?)

          {:error, :unavailable} ->
            Process.demonitor(registry_monitor, [:flush])
            wait_for_registry(worker, worker_monitor, session_id, metadata, ready_ref, notify?)
        end

      nil ->
        wait_for_registry(worker, worker_monitor, session_id, metadata, ready_ref, notify?)
    end
  end

  defp wait_for_registry(worker, worker_monitor, session_id, metadata, ready_ref, notify?) do
    receive do
      {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
        :ok

      {__MODULE__, :update_metadata, new_metadata, caller, ref} ->
        send(caller, {ref, :ok})
        wait_for_registry(worker, worker_monitor, session_id, new_metadata, ready_ref, notify?)
    after
      10 -> register_keeper(worker, worker_monitor, session_id, metadata, ready_ref, notify?)
    end
  end

  defp keeper_loop(worker, worker_monitor, registry, registry_monitor, session_id, metadata) do
    receive do
      {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
        :ok

      {:DOWN, ^registry_monitor, :process, ^registry, _reason} ->
        register_keeper(worker, worker_monitor, session_id, metadata, nil, false)

      {__MODULE__, :update_metadata, new_metadata, caller, ref} ->
        case safe_registry_update(session_id, new_metadata) do
          :ok ->
            send(caller, {ref, :ok})

            keeper_loop(
              worker,
              worker_monitor,
              registry,
              registry_monitor,
              session_id,
              new_metadata
            )

          {:error, :unavailable} ->
            Process.demonitor(registry_monitor, [:flush])
            send(caller, {ref, :ok})
            register_keeper(worker, worker_monitor, session_id, new_metadata, nil, false)
        end
    end
  end

  defp update_registry_metadata(%{registry_keeper: keeper} = session) when is_pid(keeper) do
    metadata = %{
      worker_pid: session.pid,
      controller_pid: session.controller_pid,
      recovery_claim: session.recovery_claim,
      issue_id: session.issue_id
    }

    ref = make_ref()
    send(keeper, {__MODULE__, :update_metadata, metadata, self(), ref})

    receive do
      {^ref, :ok} -> :ok
    after
      1_000 -> {:error, :registry_update_timeout}
    end
  end

  defp update_registry_metadata(_session), do: :ok

  defp register_keeper_with_ledger(session_id, worker, metadata) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_started}

      _ledger ->
        GenServer.call(__MODULE__, {:keeper_registered, session_id, worker, self(), metadata})
    end
  catch
    :exit, _ -> {:error, :not_started}
  end

  defp safe_registry_register(session_id, metadata) do
    Registry.register(__MODULE__.Registry, session_id, metadata)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp safe_registry_update(session_id, metadata) do
    case Registry.update_value(__MODULE__.Registry, session_id, fn _ -> metadata end) do
      {new_value, _old_value} when new_value == metadata -> :ok
      :error -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp session_metadata(session) do
    %{
      worker_pid: session.pid,
      controller_pid: session.controller_pid,
      recovery_claim: session.recovery_claim,
      issue_id: session.issue_id
    }
  end
end
