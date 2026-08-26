defmodule Cympho.AdapterSessionsTest do
  use ExUnit.Case, async: false

  import Cympho.WaitHelpers

  alias Cympho.AdapterSessions

  test "cancel sends the cancellation message to the registered worker" do
    session_id = make_ref()
    parent = self()

    _worker =
      AdapterSessions.spawn_registered(session_id, fn ->
        receive do
          {:cancel_session, ^session_id, reason} ->
            send(parent, {:cancelled, reason})
        end
      end)

    assert :ok = AdapterSessions.cancel(session_id, :operator_stop)
    assert_receive {:cancelled, :operator_stop}, 1_000
  end

  test "register is visible before it returns and exposes its controller" do
    session_id = make_ref()
    worker = AdapterSessions.spawn_registered(session_id, fn -> Process.sleep(:infinity) end)
    assert {:ok, ^worker} = AdapterSessions.owner(session_id)
    assert {:ok, ^worker} = AdapterSessions.owner_for_controller(self())

    Process.exit(worker, :kill)
  end

  test "all workers for one controller and issue remain discoverable" do
    issue_id = Ecto.UUID.generate()

    workers =
      for session_id <- [make_ref(), make_ref()] do
        AdapterSessions.spawn_registered(
          session_id,
          [runtime_issue_id: issue_id],
          fn -> Process.sleep(:infinity) end
        )
      end

    assert {:ok, controller_workers} = AdapterSessions.owners_for_controller(self())
    assert MapSet.new(controller_workers) == MapSet.new(workers)
    assert {:ok, issue_workers} = AdapterSessions.owners_for_issue(issue_id)
    assert MapSet.new(issue_workers) == MapSet.new(workers)

    Enum.each(workers, &Process.exit(&1, :kill))
  end

  test "spawn_registered makes registration visible before worker code starts" do
    session_id = make_ref()
    parent = self()

    worker =
      AdapterSessions.spawn_registered(session_id, fn ->
        send(parent, {:worker_started, self(), AdapterSessions.owner(session_id)})
      end)

    assert_receive {:worker_started, ^worker, {:ok, ^worker}}, 1_000
  end

  test "controller watcher is installed before registered worker code starts" do
    parent = self()

    controller =
      spawn(fn ->
        AdapterSessions.spawn_registered(make_ref(), fn ->
          {:monitored_by, monitors} = Process.info(self(), :monitored_by)
          send(parent, {:worker_monitors, monitors})
          Process.sleep(:infinity)
        end)
      end)

    assert_receive {:worker_monitors, monitors}, 1_000
    assert length(monitors) >= 3
    Process.exit(controller, :kill)
  end

  test "spawn_registered fails closed when the authoritative ledger is unavailable" do
    ledger = Process.whereis(AdapterSessions)
    Process.unregister(AdapterSessions)
    on_exit(fn -> Process.register(ledger, AdapterSessions) end)

    assert_raise RuntimeError, ~r/failed to register adapter worker/, fn ->
      AdapterSessions.spawn_registered(make_ref(), fn -> Process.sleep(:infinity) end)
    end
  end

  test "gateway adapter workers do not start provider work if their controller dies before registration" do
    server = Process.whereis(AdapterSessions)
    parent = self()

    :sys.suspend(server)

    try do
      controllers =
        for adapter <- [
              Cympho.Adapters.AgrentingAdapter,
              Cympho.Adapters.HttpAdapter,
              Cympho.Adapters.MockAdapter,
              Cympho.Adapters.OpenAIChatAdapter,
              Cympho.Adapters.OpenClawAdapter
            ] do
          controller =
            spawn(fn ->
              adapter.run(
                %{id: Ecto.UUID.generate(), title: "Registration barrier"},
                Ecto.UUID.generate(),
                parent,
                []
              )
            end)

          wait_until(fn ->
            assert match?({:status, :waiting}, Process.info(controller, :status))
          end)

          controller
        end

      Enum.each(controllers, &Process.exit(&1, :kill))
      Enum.each(controllers, fn controller -> refute Process.alive?(controller) end)
    after
      :sys.resume(server)
    end

    refute_receive {:session_started, _session_id}, 200
    refute_receive {:turn_completed, _session_id, _result}, 0
    refute_receive {:turn_ended_with_error, _session_id, _reason}, 0
  end

  test "cancel_and_wait does not return until the worker exits" do
    session_id = make_ref()
    parent = self()

    worker =
      AdapterSessions.spawn_registered(session_id, fn ->
        receive do
          {:cancel_session, ^session_id, _reason} ->
            send(parent, {:cancel_received, self()})

            receive do
              :finish_cleanup -> :ok
            end
        end
      end)

    task =
      Task.async(fn -> AdapterSessions.cancel_and_wait(session_id, :operator_stop, 1_000) end)

    assert_receive {:cancel_received, ^worker}, 1_000
    refute Task.yield(task, 0)

    send(worker, :finish_cleanup)
    assert Task.await(task) == :ok
  end

  test "dead workers are removed from the registry" do
    session_id = make_ref()

    worker =
      AdapterSessions.spawn_registered(session_id, fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert AdapterSessions.registered?(session_id)

    send(worker, :stop)

    wait_until(fn -> refute AdapterSessions.registered?(session_id) end)
  end

  test "run_cancellable returns the request result" do
    assert {:ok, :done} =
             AdapterSessions.run_cancellable(make_ref(), fn ->
               {:ok, :done}
             end)
  end

  test "run_cancellable kills blocking request work when the session is cancelled" do
    session_id = make_ref()
    parent = self()

    worker =
      spawn(fn ->
        result =
          AdapterSessions.run_cancellable(session_id, fn ->
            send(parent, {:request_started, self()})

            receive do
              :finish -> {:ok, :late}
            end
          end)

        send(parent, {:request_result, result})
      end)

    assert_receive {:request_started, request_pid}, 1_000
    assert Process.alive?(request_pid)

    send(worker, {:cancel_session, session_id, :operator_stop})

    assert_receive {:request_result, {:error, {:cancelled, :operator_stop}}}, 1_000
    refute Process.alive?(request_pid)
  end

  test "controller death cancels registered blocking provider work and ends its worker" do
    session_id = make_ref()
    parent = self()

    controller =
      spawn(fn ->
        worker =
          AdapterSessions.spawn_registered(session_id, fn ->
            result =
              AdapterSessions.run_cancellable(session_id, fn ->
                send(parent, {:provider_task_started, self()})

                receive do
                  :finish -> {:ok, :late}
                end
              end)

            send(parent, {:provider_worker_result, self(), result})
            AdapterSessions.unregister(session_id)
          end)

        send(parent, {:provider_worker_started, self(), worker})
        Process.sleep(:infinity)
      end)

    assert_receive {:provider_worker_started, ^controller, worker}, 1_000
    assert_receive {:provider_task_started, provider_task}, 1_000
    assert Process.alive?(worker)
    assert Process.alive?(provider_task)

    controller_monitor = Process.monitor(controller)
    worker_monitor = Process.monitor(worker)
    Process.exit(controller, :kill)

    assert_receive {:DOWN, ^controller_monitor, :process, ^controller, :killed}, 1_000

    assert_receive {:provider_worker_result, ^worker, {:error, {:cancelled, :owner_down}}},
                   1_000

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 1_000
    refute Process.alive?(provider_task)
    refute AdapterSessions.registered?(session_id)
  end

  test "a tracker restart rebuilds live owner and recovery inventory from the ledger" do
    session_id = make_ref()
    controller = self()
    assert {:ok, token} = Cympho.RuntimeAdmission.checkout(:http)

    worker =
      AdapterSessions.spawn_registered(
        session_id,
        [
          runtime_issue_id: Ecto.UUID.generate(),
          runtime_admission_claim: {token, Cympho.RuntimeAdmission, :gateway}
        ],
        fn ->
          receive do
            {:cancel_session, ^session_id, :tracker_restart_test} -> :ok
          end

          AdapterSessions.unregister(session_id)
        end
      )

    old_tracker = Process.whereis(AdapterSessions)
    Process.exit(old_tracker, :kill)

    wait_until(fn ->
      tracker = Process.whereis(AdapterSessions)
      assert is_pid(tracker) and tracker != old_tracker
    end)

    assert {:ok, ^worker} = AdapterSessions.owner(session_id)
    assert {:ok, ^worker} = AdapterSessions.owner_for_controller(controller)

    assert {:ok, claims} = AdapterSessions.recovery_claims()
    assert [claim] = Enum.filter(claims, &(&1.token == token))

    assert claim.holder_pid == worker
    assert claim.controller_pid == controller
    assert claim.execution_class == :gateway

    assert :ok = AdapterSessions.cancel_and_wait(session_id, :tracker_restart_test, 1_000)
    refute AdapterSessions.registered?(session_id)
    assert Cympho.RuntimeAdmission.release(token) == :ok
  end

  test "registry restart and controller death retain the worker and admission fences until cleanup" do
    admission =
      start_supervised!({
        Cympho.RuntimeAdmission,
        name: nil,
        max_total_runs: 1,
        max_local_runs: 1,
        memory_check?: false,
        recover_fun: fn -> [] end
      })

    parent = self()
    issue_id = Ecto.UUID.generate()
    session_id = make_ref()

    controller =
      spawn(fn ->
        assert {:ok, token} = Cympho.RuntimeAdmission.checkout(:process, admission)

        worker =
          AdapterSessions.spawn_registered(
            session_id,
            [
              runtime_issue_id: issue_id,
              runtime_admission_claim: {token, admission, :local_process}
            ],
            fn ->
              receive do
                {:cancel_session, ^session_id, :owner_down} ->
                  send(parent, {:owner_down_cleanup, self()})

                  receive do
                    :finish_cleanup -> :ok
                  end
              end
            end
          )

        send(parent, {:registered_worker, worker})
        Process.sleep(:infinity)
      end)

    assert_receive {:registered_worker, worker}, 1_000
    assert {:error, :total_slots_exhausted} = Cympho.RuntimeAdmission.available(:http, admission)

    old_registry = Process.whereis(AdapterSessions.Registry)
    assert :ok = Supervisor.terminate_child(Cympho.Supervisor, AdapterSessions.Registry)
    assert is_nil(Process.whereis(AdapterSessions.Registry))

    assert {:ok, _registry} =
             Supervisor.restart_child(Cympho.Supervisor, AdapterSessions.Registry)

    wait_until(fn ->
      registry = Process.whereis(AdapterSessions.Registry)
      assert is_pid(registry) and registry != old_registry
    end)

    wait_until(fn ->
      assert [{_keeper, %{worker_pid: ^worker}}] =
               Registry.lookup(AdapterSessions.Registry, session_id)
    end)

    assert {:ok, ^worker} = AdapterSessions.owner(session_id)

    Process.exit(controller, :kill)
    assert_receive {:owner_down_cleanup, ^worker}, 1_000
    assert {:ok, [^worker]} = AdapterSessions.owners_for_issue(issue_id)
    assert {:error, :total_slots_exhausted} = Cympho.RuntimeAdmission.available(:http, admission)

    send(worker, :finish_cleanup)
    wait_until(fn -> refute Process.alive?(worker) end)
    assert :ok = Cympho.RuntimeAdmission.available(:http, admission)
  end

  test "a dead registry keeper is replaced while its worker remains authoritative" do
    session_id = make_ref()
    worker = AdapterSessions.spawn_registered(session_id, fn -> Process.sleep(:infinity) end)

    %{sessions: %{^session_id => session}} = :sys.get_state(AdapterSessions)
    old_keeper = session.registry_keeper
    Process.exit(old_keeper, :kill)

    wait_until(fn ->
      %{sessions: %{^session_id => current}} = :sys.get_state(AdapterSessions)
      assert is_pid(current.registry_keeper)
      assert current.registry_keeper != old_keeper
      assert Process.alive?(current.registry_keeper)
    end)

    assert {:ok, ^worker} = AdapterSessions.owner(session_id)

    old_tracker = Process.whereis(AdapterSessions)
    Process.exit(old_tracker, :kill)

    wait_until(fn ->
      tracker = Process.whereis(AdapterSessions)
      assert is_pid(tracker) and tracker != old_tracker
    end)

    assert {:ok, ^worker} = AdapterSessions.owner(session_id)
    Process.exit(worker, :kill)
  end

  test "overlapping registry and ledger restarts heal a live worker inventory" do
    session_id = make_ref()
    worker = AdapterSessions.spawn_registered(session_id, fn -> Process.sleep(:infinity) end)

    assert :ok = Supervisor.terminate_child(Cympho.Supervisor, AdapterSessions.Registry)
    assert :ok = Supervisor.terminate_child(Cympho.Supervisor, AdapterSessions)

    assert {:ok, _registry} =
             Supervisor.restart_child(Cympho.Supervisor, AdapterSessions.Registry)

    assert {:ok, _ledger} = Supervisor.restart_child(Cympho.Supervisor, AdapterSessions)

    wait_until(fn ->
      assert {:ok, ^worker} = AdapterSessions.owner(session_id)

      assert [{_keeper, %{worker_pid: ^worker}}] =
               Registry.lookup(AdapterSessions.Registry, session_id)
    end)

    Process.exit(worker, :kill)
  end
end
