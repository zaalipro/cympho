defmodule Cympho.Orchestrator.DispatcherTest do
  use ExUnit.Case, async: false

  import Cympho.WaitHelpers

  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Orchestrator.Dispatcher.State
  alias Cympho.Issues.Issue

  setup do
    # Ensure registries are started (they may already be started by the app supervisor)
    for {name, keys} <- [
          {Cympho.OrchestratorRegistry, :unique},
          {Cympho.AgentHeartbeat.Registry, :unique}
        ] do
      unless Process.whereis(name) do
        start_supervised!({Registry, keys: keys, name: name})
      end
    end

    :ok
  end

  describe "State struct" do
    test "new/0 creates empty running_issue_ids and retry_attempts" do
      state = State.new()
      assert state.running_issue_ids == MapSet.new()
      assert state.retry_attempts == %{}
    end
  end

  describe "handle_info(:session_ended, ...)" do
    @tag :capture_log
    test "removes issue_id from running set" do
      # Dispatcher may already be started by app supervisor - use it directly
      ensure_dispatcher_running()
      send(Dispatcher, {:session_ended, "any-issue-id", :normal})
      # Dispatcher.state() is a GenServer call, so it returns only after the
      # :session_ended message has been handled — no sleep needed.
      state = Dispatcher.state()
      refute MapSet.member?(state.running_issue_ids, "any-issue-id")
    end

    @tag :capture_log
    test "a stale company-stop completion cannot erase a live worker fence" do
      ensure_dispatcher_running()
      issue_id = Ecto.UUID.generate()
      session_id = make_ref()

      worker =
        Cympho.AdapterSessions.spawn_registered(
          session_id,
          [runtime_issue_id: issue_id],
          fn -> Process.sleep(:infinity) end
        )

      :sys.replace_state(Process.whereis(Dispatcher), fn %State{} = state ->
        %{state | running_issue_ids: MapSet.put(state.running_issue_ids, issue_id)}
      end)

      send(Dispatcher, {:company_stop_finished, [issue_id]})
      assert MapSet.member?(Dispatcher.state().running_issue_ids, issue_id)

      Process.exit(worker, :kill)
    end

    @tag :capture_log
    test "a dead stale orchestrator registry row cannot hide a live worker" do
      ensure_dispatcher_running()
      issue_id = Ecto.UUID.generate()
      parent = self()

      worker =
        Cympho.AdapterSessions.spawn_registered(
          make_ref(),
          [runtime_issue_id: issue_id],
          fn -> Process.sleep(:infinity) end
        )

      stale =
        spawn(fn ->
          {:ok, _} = Registry.register(Cympho.OrchestratorRegistry, issue_id, nil)
          send(parent, {:stale_registered, self()})
          Process.sleep(:infinity)
        end)

      assert_receive {:stale_registered, ^stale}, 1_000
      pid_partition = Module.concat(Cympho.OrchestratorRegistry, "PIDPartition0")
      :sys.suspend(pid_partition)

      try do
        Process.exit(stale, :kill)
        wait_until(fn -> refute Process.alive?(stale) end)
        assert Cympho.Orchestrator.whereis(issue_id) == stale

        :sys.replace_state(Process.whereis(Dispatcher), fn %State{} = state ->
          %{state | running_issue_ids: MapSet.put(state.running_issue_ids, issue_id)}
        end)

        send(Dispatcher, {:session_ended, issue_id, :normal})
        assert MapSet.member?(Dispatcher.state().running_issue_ids, issue_id)
      after
        :sys.resume(pid_partition)
        Process.exit(worker, :kill)
      end
    end

    @tag :capture_log
    test "a stale session_ended event cannot erase a successor fence" do
      ensure_dispatcher_running()
      issue_id = Ecto.UUID.generate()
      successor = start_registered_orchestrator(issue_id)

      :sys.replace_state(Process.whereis(Dispatcher), fn %State{} = state ->
        %{state | running_issue_ids: MapSet.put(state.running_issue_ids, issue_id)}
      end)

      send(Dispatcher, {:session_ended, issue_id, :normal})
      assert MapSet.member?(Dispatcher.state().running_issue_ids, issue_id)

      stop_registered_orchestrator(successor, issue_id)
    end
  end

  describe "start_link/1" do
    @tag :capture_log
    test "starts linked to calling process" do
      ensure_dispatcher_running()
      pid = Process.whereis(Dispatcher)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "backoff_ms_for_attempt/1" do
    test "monotonically increases for the first few attempts" do
      assert Dispatcher.backoff_ms_for_attempt(0) <= Dispatcher.backoff_ms_for_attempt(1)
      assert Dispatcher.backoff_ms_for_attempt(1) <= Dispatcher.backoff_ms_for_attempt(2)
      assert Dispatcher.backoff_ms_for_attempt(2) <= Dispatcher.backoff_ms_for_attempt(3)
    end

    test "is capped — large attempt counts don't push retries into hours" do
      # Attempt 100 would naively be base * 2^100 ms (vastly more than years).
      # Confirm we top out at the same value as a much-smaller attempt count.
      capped = Dispatcher.backoff_ms_for_attempt(50)
      really_capped = Dispatcher.backoff_ms_for_attempt(500)
      assert capped == really_capped

      # Cap should be at most an hour — the configured @max_backoff_ms is 10
      # minutes by default. Use a generous bound to avoid coupling the test
      # to the exact constant.
      assert capped <= 3_600_000
    end
  end

  describe "record_dispatch_failure/3 retry bookkeeping" do
    test "tuple reasons do not crash retry bookkeeping" do
      issue = %Issue{id: Ecto.UUID.generate(), company_id: nil}

      # `{:preflight_failed, reason}` used to be string-interpolated and
      # raised Protocol.UndefinedError, taking the whole dispatcher down.
      state =
        Dispatcher.record_dispatch_failure(
          issue,
          State.new(),
          {:preflight_failed, {:workspace_error, :enoent}}
        )

      assert %{attempts: 1} = state.retry_attempts[issue.id]
    end

    test "attempts cap at max instead of abandoning the issue" do
      issue = %Issue{id: Ecto.UUID.generate(), company_id: nil}

      state =
        Enum.reduce(1..10, State.new(), fn _n, state ->
          Dispatcher.record_dispatch_failure(issue, state, :no_agent)
        end)

      entry = state.retry_attempts[issue.id]

      # The entry survives past max retries (still tracked, still backing
      # off at the cap) rather than being dropped — dropping it meant the
      # issue was retried on EVERY poll with an error log each time.
      assert entry.attempts == 5
      assert entry.next_retry_at > :os.system_time(:millisecond)
    end
  end

  describe "orchestrator DOWN handling" do
    test "explicit stop dominates crash across all cleanup monitors for an issue" do
      issue_id = Ecto.UUID.generate()
      old_worker = spawn(fn -> Process.sleep(:infinity) end)
      stop_worker = spawn(fn -> Process.sleep(:infinity) end)
      old_ref = Process.monitor(old_worker)

      state = %{
        State.new()
        | monitors: %{old_ref => {:adapter_cleanup, issue_id, :old_crash, :crash}},
          running_issue_ids: MapSet.new([issue_id])
      }

      assert {:noreply, state} =
               Dispatcher.handle_info(
                 {:defer_adapter_cleanup, issue_id, stop_worker, :operator_stop},
                 state
               )

      cleanup_entries =
        Enum.filter(state.monitors, fn
          {_ref, {:adapter_cleanup, ^issue_id, _reason, _action}} -> true
          _ -> false
        end)

      assert length(cleanup_entries) == 2

      assert Enum.all?(cleanup_entries, fn
               {_ref, {:adapter_cleanup, ^issue_id, :operator_stop, :stop}} -> true
               _ -> false
             end)

      Process.exit(old_worker, :kill)
      Process.exit(stop_worker, :kill)
    end

    @tag :capture_log
    test "an old controller DOWN cannot erase a registered successor fence" do
      ensure_dispatcher_running()
      issue_id = Ecto.UUID.generate()
      successor = start_registered_orchestrator(issue_id)
      old_controller = spawn(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(Process.whereis(Dispatcher), fn %State{} = state ->
        ref = Process.monitor(old_controller)

        %{
          state
          | running_issue_ids: MapSet.put(state.running_issue_ids, issue_id),
            monitors: Map.put(state.monitors, ref, issue_id)
        }
      end)

      Process.exit(old_controller, :kill)

      wait_until(fn ->
        assert MapSet.member?(Dispatcher.state().running_issue_ids, issue_id)
      end)

      stop_registered_orchestrator(successor, issue_id)
    end

    @tag :capture_log
    test "old crash cleanup cannot erase a live successor worker fence" do
      ensure_dispatcher_running()
      issue_id = Ecto.UUID.generate()

      old_worker =
        Cympho.AdapterSessions.spawn_registered(
          make_ref(),
          [runtime_issue_id: issue_id],
          fn -> Process.sleep(:infinity) end
        )

      successor =
        Cympho.AdapterSessions.spawn_registered(
          make_ref(),
          [runtime_issue_id: issue_id],
          fn -> Process.sleep(:infinity) end
        )

      :sys.replace_state(Process.whereis(Dispatcher), fn %State{} = state ->
        ref = Process.monitor(old_worker)

        %{
          state
          | running_issue_ids: MapSet.put(state.running_issue_ids, issue_id),
            monitors:
              Map.put(state.monitors, ref, {:adapter_cleanup, issue_id, :old_crash, :crash})
        }
      end)

      Process.exit(old_worker, :kill)

      wait_until(fn ->
        assert MapSet.member?(Dispatcher.state().running_issue_ids, issue_id)
      end)

      Process.exit(successor, :kill)
    end

    @tag :capture_log
    test "a crashed (non-graceful) orchestrator frees its slot" do
      ensure_dispatcher_running()

      issue_id = "down-test-issue-#{System.unique_integer([:positive])}"

      # Simulate the dispatch bookkeeping: a monitored fake orchestrator.
      fake_orchestrator = spawn(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(Process.whereis(Dispatcher), fn %State{} = state ->
        ref = Process.monitor(fake_orchestrator)

        %{
          state
          | running_issue_ids: MapSet.put(state.running_issue_ids, issue_id),
            monitors: Map.put(state.monitors, ref, issue_id)
        }
      end)

      Process.exit(fake_orchestrator, :kill)

      # The DOWN must free the slot even though no :session_ended arrived
      # (brutal kills skip terminate/2).
      wait_until(fn ->
        state = Dispatcher.state()

        refute MapSet.member?(state.running_issue_ids, issue_id)
        refute Enum.any?(state.monitors, fn {_ref, id} -> id == issue_id end)
      end)
    end

    @tag :capture_log
    test "a gracefully stopped orchestrator frees its slot via session_ended" do
      ensure_dispatcher_running()

      issue_id = "graceful-test-issue-#{System.unique_integer([:positive])}"
      fake_orchestrator = spawn(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(Process.whereis(Dispatcher), fn %State{} = state ->
        ref = Process.monitor(fake_orchestrator)

        %{
          state
          | running_issue_ids: MapSet.put(state.running_issue_ids, issue_id),
            monitors: Map.put(state.monitors, ref, issue_id)
        }
      end)

      # Graceful path: terminate/2 sends :session_ended, then the process
      # exits :normal.
      send(Process.whereis(Dispatcher), {:session_ended, issue_id, :normal})
      Process.exit(fake_orchestrator, :kill)

      wait_until(fn ->
        state = Dispatcher.state()

        refute MapSet.member?(state.running_issue_ids, issue_id)
        refute Enum.any?(state.monitors, fn {_ref, id} -> id == issue_id end)
      end)
    end

    @tag :capture_log
    test "a crashed orchestrator retains its issue slot until its registered child worker exits" do
      ensure_dispatcher_running()
      issue_id = Ecto.UUID.generate()
      session_id = make_ref()
      parent = self()
      root = Path.join(System.tmp_dir!(), "cympho-dispatcher-cleanup-#{System.unique_integer()}")
      gate = Path.join(root, "gate")
      command = Path.join(root, "child")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      {"", 0} = System.cmd("mkfifo", [gate], stderr_to_stdout: true)

      File.write!(command, """
      #!/bin/sh
      IFS= read -r _ < '#{gate}'
      """)

      File.chmod!(command, 0o755)

      fake_orchestrator =
        spawn(fn ->
          controller = self()

          Cympho.AdapterSessions.spawn_registered(session_id, fn ->
            controller_monitor = Process.monitor(controller)

            port =
              Port.open({:spawn_executable, String.to_charlist(command)}, [
                :binary,
                :exit_status,
                :use_stdio
              ])

            {:os_pid, os_pid} = Port.info(port, :os_pid)
            send(parent, {:cleanup_worker_started, self(), os_pid})

            assert_receive {:DOWN, ^controller_monitor, :process, ^controller, :killed}, 1_000
            send(parent, :cleanup_waiting_for_child)
            assert_receive {^port, {:exit_status, 0}}, 2_000
            Cympho.AdapterSessions.unregister(session_id)
          end)

          Process.sleep(:infinity)
        end)

      assert_receive {:cleanup_worker_started, worker, os_pid}, 1_000

      :sys.replace_state(Process.whereis(Dispatcher), fn %State{} = state ->
        ref = Process.monitor(fake_orchestrator)

        %{
          state
          | running_issue_ids: MapSet.put(state.running_issue_ids, issue_id),
            monitors: Map.put(state.monitors, ref, issue_id)
        }
      end)

      Process.exit(fake_orchestrator, :kill)
      assert_receive :cleanup_waiting_for_child, 1_000

      state = Dispatcher.state()
      assert MapSet.member?(state.running_issue_ids, issue_id)
      assert Process.alive?(worker)

      assert match?(
               {_output, 0},
               System.cmd("/bin/kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
             )

      File.write!(gate, "exit\n")

      wait_until(fn ->
        state = Dispatcher.state()
        refute MapSet.member?(state.running_issue_ids, issue_id)
      end)

      refute Process.alive?(worker)

      refute match?(
               {_output, 0},
               System.cmd("/bin/kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
             )
    end
  end

  describe "max_concurrent/0" do
    setup do
      original = Application.get_env(:cympho, :orchestrator, [])
      on_exit(fn -> Application.put_env(:cympho, :orchestrator, original) end)
      %{original: original}
    end

    test "honours a runtime setting", %{original: original} do
      Application.put_env(
        :cympho,
        :orchestrator,
        Keyword.put(original, :max_concurrent_agents, 12)
      )

      assert Dispatcher.max_concurrent() == 12
    end

    test "falls back to the machine's schedulers instead of a compiled-in 3", %{
      original: original
    } do
      # The ceiling used to be `Application.compile_env(..., 3)`: every install
      # ran three concurrent agents across all tenants, and raising it required
      # rebuilding the release.
      Application.put_env(
        :cympho,
        :orchestrator,
        Keyword.delete(original, :max_concurrent_agents)
      )

      derived = Dispatcher.max_concurrent()

      assert derived >= 4
      assert derived <= 32
      assert derived >= :erlang.system_info(:schedulers_online)
    end

    test "ignores a nonsensical setting", %{original: original} do
      for bad <- [0, -1, "many", nil] do
        Application.put_env(
          :cympho,
          :orchestrator,
          Keyword.put(original, :max_concurrent_agents, bad)
        )

        assert Dispatcher.max_concurrent() >= 4
      end
    end
  end

  describe "runnable_candidate?/1" do
    @company_id Ecto.UUID.generate()

    test "parks blocked issues even when they have no blocker relations" do
      refute Dispatcher.runnable_candidate?(%Issue{
               status: :blocked,
               company_id: @company_id,
               blocked_by: []
             })
    end

    test "rejects issues with active blockers and accepts resolved blockers" do
      refute Dispatcher.runnable_candidate?(%Issue{
               status: :todo,
               company_id: @company_id,
               blocked_by: [%Issue{status: :in_progress}]
             })

      assert Dispatcher.runnable_candidate?(%Issue{
               status: :todo,
               company_id: @company_id,
               blocked_by: [%Issue{status: :cancelled}]
             })
    end

    test "rejects issue-level paused work without changing workflow status" do
      refute Dispatcher.runnable_candidate?(%Issue{
               status: :todo,
               company_id: @company_id,
               blocked_by: [],
               monitor_state: %{"issue_runtime" => %{"paused" => true}}
             })
    end

    test "rejects issues with nil company_id (fail-closed tenancy)" do
      refute Dispatcher.runnable_candidate?(%Issue{
               status: :todo,
               company_id: nil,
               blocked_by: [],
               monitor_state: %{}
             })
    end
  end

  # Helpers

  defp ensure_dispatcher_running do
    unless Process.whereis(Dispatcher) do
      {:ok, _} = Dispatcher.start_link([])
    end
  end

  defp start_registered_orchestrator(issue_id) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(Cympho.OrchestratorRegistry, issue_id, nil)
        send(parent, {:orchestrator_registered, self(), issue_id})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:orchestrator_registered, ^pid, ^issue_id}, 2_000
    pid
  end

  defp stop_registered_orchestrator(pid, issue_id) do
    monitor = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 2_000
    send(Dispatcher, {:session_ended, issue_id, :normal})
    _ = Dispatcher.state()
    :ok
  end
end

defmodule Cympho.Orchestrator.DispatcherDbTest do
  use Cympho.DataCase, async: false

  import Mock
  import Cympho.WaitHelpers

  alias Cympho.{Agents, Companies, Issues, Orchestrator, Runtime}
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Orchestrator.Dispatcher.State

  @moduletag :capture_log

  setup do
    unless Process.whereis(Cympho.OrchestratorRegistry) do
      start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
    end

    original = Application.get_env(:cympho, :orchestrator, [])
    Application.put_env(:cympho, :orchestrator, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:cympho, :orchestrator, original) end)

    {:ok, company} =
      Companies.create_company(%{
        name: "Dispatcher DB Co #{System.unique_integer([:positive])}",
        slug: "disp-db-#{System.unique_integer([:positive])}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Dispatch Agent",
        role: "engineer",
        status: :idle,
        company_id: company.id,
        adapter: :claude_code
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Dispatchable issue",
        description: "Test",
        status: :todo,
        company_id: company.id,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })

    %{company: company, agent: agent, issue: issue}
  end

  describe "restart live-session accounting" do
    test "rebuilds and monitors a surviving registered orchestrator", %{
      company: company
    } do
      {:ok, survivor_agent} =
        Agents.create_agent(%{
          name: "Restart survivor",
          role: :engineer,
          status: :idle,
          company_id: company.id,
          adapter: :claude_code
        })

      {:ok, survivor_issue} =
        Issues.create_issue(%{
          title: "Surviving in-progress session",
          status: :todo,
          company_id: company.id,
          assignee_id: survivor_agent.id
        })

      {:ok, checked_out} = Issues.checkout_issue(survivor_issue, survivor_agent)
      survivor = start_registered_orchestrator(checked_out.id)

      state = Dispatcher.rebuild_live_sessions(State.new())

      assert state.running_issue_ids == MapSet.new([checked_out.id])
      assert [{monitor_ref, checked_out_id}] = Map.to_list(state.monitors)
      assert checked_out_id == checked_out.id

      Process.exit(survivor, :kill)
      assert_receive {:DOWN, ^monitor_ref, :process, ^survivor, :killed}, 2_000
    end

    test "ignores dead registry entries and live entries without an in-progress issue", %{
      agent: agent,
      company: company,
      issue: todo_issue
    } do
      stale_live = start_registered_orchestrator(todo_issue.id)

      {:ok, stale_bound_issue} =
        Issues.create_issue(%{
          title: "Stale terminal checkout owner",
          status: :todo,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, terminal_run} =
        Cympho.HeartbeatEngine.create_run(%{
          company_id: company.id,
          agent_id: agent.id,
          issue_id: stale_bound_issue.id,
          adapter: "claude_code"
        })

      {:ok, terminal_run} = Cympho.HeartbeatEngine.cancel_run(terminal_run)

      stale_bound_issue =
        stale_bound_issue
        |> Ecto.Changeset.change(%{
          status: :in_progress,
          checked_out_at: DateTime.utc_now() |> DateTime.truncate(:second),
          checkout_run_id: terminal_run.id
        })
        |> Cympho.Repo.update!()

      stale_bound = start_registered_orchestrator(stale_bound_issue.id)

      dead_issue_id = Ecto.UUID.generate()
      dead = start_registered_orchestrator(dead_issue_id)
      dead_ref = Process.monitor(dead)
      Process.exit(dead, :kill)
      assert_receive {:DOWN, ^dead_ref, :process, ^dead, :killed}, 2_000

      state = Dispatcher.rebuild_live_sessions(State.new())

      assert state.running_issue_ids == MapSet.new()
      assert state.monitors == %{}
      Process.exit(stale_live, :kill)
      Process.exit(stale_bound, :kill)
    end

    test "a surviving session consumes the rebuilt global slot", %{
      company: company,
      issue: candidate
    } do
      {survivor, survivor_issue} = create_registered_survivor(company)
      original = Application.get_env(:cympho, :orchestrator, [])

      Application.put_env(
        :cympho,
        :orchestrator,
        Keyword.put(original, :max_concurrent_agents, 1)
      )

      on_exit(fn -> Application.put_env(:cympho, :orchestrator, original) end)
      state = Dispatcher.rebuild_live_sessions(State.new())
      test_pid = self()

      with_mocks([
        {Runtime, [], [dispatchable?: fn _issue, _agent -> :ok end]},
        {Orchestrator, [],
         [
           start_and_run: fn issue, _agent_id ->
             send(test_pid, {:unexpected_dispatch, issue.id})
             {:ok, spawn(fn -> Process.sleep(:infinity) end)}
           end,
           whereis: fn
             id when id == survivor_issue.id -> survivor
             _id -> nil
           end,
           stop: fn _issue_id, _reason -> :ok end
         ]}
      ]) do
        assert {:noreply, %State{} = after_poll} =
                 Dispatcher.handle_info({:poll_company, company.id}, state)

        assert MapSet.member?(after_poll.running_issue_ids, survivor_issue.id)
        refute_received {:unexpected_dispatch, _issue_id}
        assert Issues.get_issue!(candidate.id).status == :todo
      end
    end

    test "a surviving session consumes its rebuilt company slot", %{
      company: company,
      issue: candidate
    } do
      {survivor, survivor_issue} = create_registered_survivor(company)
      original = Application.get_env(:cympho, :orchestrator, [])

      Application.put_env(
        :cympho,
        :orchestrator,
        Keyword.put(original, :max_concurrent_agents, 2)
      )

      on_exit(fn -> Application.put_env(:cympho, :orchestrator, original) end)

      {:ok, _company} =
        Companies.execute_company_update(company, %{
          governance_config: %{"limits" => %{"max_concurrent_runs" => 1}}
        })

      state = Dispatcher.rebuild_live_sessions(State.new())
      test_pid = self()

      with_mocks([
        {Runtime, [], [dispatchable?: fn _issue, _agent -> :ok end]},
        {Orchestrator, [],
         [
           start_and_run: fn issue, _agent_id ->
             send(test_pid, {:unexpected_dispatch, issue.id})
             {:ok, spawn(fn -> Process.sleep(:infinity) end)}
           end,
           whereis: fn
             id when id == survivor_issue.id -> survivor
             _id -> nil
           end,
           stop: fn _issue_id, _reason -> :ok end
         ]}
      ]) do
        assert {:noreply, %State{} = after_poll} =
                 Dispatcher.handle_info({:poll_company, company.id}, state)

        assert MapSet.member?(after_poll.running_issue_ids, survivor_issue.id)
        refute_received {:unexpected_dispatch, _issue_id}
        assert Issues.get_issue!(candidate.id).status == :todo
      end
    end
  end

  test "explicit issue stop defers release when only an orphan worker remains", %{
    agent: agent,
    issue: issue
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, issue} =
      Issues.update_issue(issue, %{
        status: :in_progress,
        checked_out_at: now,
        started_at: now
      })

    parent = self()
    session_id = make_ref()

    controller =
      spawn(fn ->
        worker =
          Cympho.AdapterSessions.spawn_registered(
            session_id,
            [runtime_issue_id: issue.id],
            fn ->
              receive do
                {:cancel_session, ^session_id, _reason} ->
                  send(parent, {:orphan_cancelled, self()})
                  receive do: (:finish_cleanup -> :ok)
              end
            end
          )

        send(parent, {:orphan_worker, worker})
        Process.sleep(:infinity)
      end)

    assert_receive {:orphan_worker, worker}, 1_000
    Process.exit(controller, :kill)
    assert_receive {:orphan_cancelled, ^worker}, 1_000

    assert {:ok, result} = Dispatcher.stop_issue(issue.id, :operator_issue_pause)
    assert issue.id in result.deferred_issue_ids
    assert Issues.get_issue!(issue.id).status == :in_progress
    assert agent.id == issue.assignee_id

    send(worker, :finish_cleanup)
    wait_until(fn -> refute Process.alive?(worker) end)

    # Drain this test's deferred cleanup before its sandbox owner exits. The
    # application Dispatcher may not share this test's DB connection, so it
    # deliberately retries rather than completing database cleanup here.
    send(Dispatcher, {:session_ended, issue.id, :normal})
    refute MapSet.member?(Dispatcher.state().running_issue_ids, issue.id)
  end

  test "admits blocked issue with pending issue_children_completed wake", %{
    company: company,
    agent: agent
  } do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Soft parked parent",
        status: :blocked,
        company_id: company.id,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })

    {:ok, _wake} =
      Cympho.Wakes.do_wake_agent(
        agent.id,
        issue.id,
        "issue_children_completed",
        "system",
        nil,
        %{}
      )

    preloaded = Issues.get_issue!(issue.id) |> Cympho.Repo.preload([:blocked_by, :company])
    assert Dispatcher.runnable_candidate?(preloaded)
  end

  test "admits blocked issue with pending escalation_from_subordinate wake", %{
    company: company,
    agent: agent
  } do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Escalated blocked",
        status: :blocked,
        company_id: company.id,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })

    {:ok, _wake} =
      Cympho.Wakes.do_wake_agent(
        agent.id,
        issue.id,
        "escalation_from_subordinate",
        "system",
        nil,
        %{}
      )

    preloaded = Issues.get_issue!(issue.id) |> Cympho.Repo.preload([:blocked_by, :company])
    assert Dispatcher.runnable_candidate?(preloaded)
  end

  test "one tenant's backlog does not starve another tenant", %{
    company: company,
    agent: agent,
    issue: issue
  } do
    # Candidates used to come from one globally priority-ordered window. A
    # tenant holding the top rows of that window starved everyone else
    # outright: nobody else's issues were even loaded, so rejecting the busy
    # tenant's candidates admitted no one and the slots simply went unused.
    for n <- 1..30 do
      {:ok, _hog} =
        Issues.create_issue(%{
          title: "Loud tenant critical #{n}",
          description: "Outranks everything the quiet tenant has",
          status: :todo,
          priority: :critical,
          company_id: company.id,
          assignee_id: agent.id,
          assigned_role: "engineer"
        })
    end

    unique = System.unique_integer([:positive])

    {:ok, quiet_company} =
      Companies.create_company(%{
        name: "Quiet Co #{unique}",
        slug: "quiet-co-#{unique}",
        issue_prefix: "QC"
      })

    {:ok, quiet_agent} =
      Agents.create_agent(%{
        name: "Quiet Agent",
        role: "engineer",
        status: :idle,
        company_id: quiet_company.id,
        adapter: :claude_code
      })

    {:ok, quiet_issue} =
      Issues.create_issue(%{
        title: "Quiet tenant low priority",
        description: "Ranks below every issue the loud tenant has",
        status: :todo,
        priority: :low,
        company_id: quiet_company.id,
        assignee_id: quiet_agent.id,
        assigned_role: "engineer"
      })

    test_pid = self()

    with_mocks([
      {Runtime, [], [dispatchable?: fn _issue, _agent -> :ok end]},
      {Orchestrator, [],
       [
         start_and_run: fn checked_out, _agent_id ->
           send(test_pid, {:dispatched, checked_out.company_id})
           {:ok, spawn(fn -> Process.sleep(200) end)}
         end,
         whereis: fn _issue_id -> nil end,
         stop: fn _issue_id, _reason -> :ok end
       ]}
    ]) do
      assert {:noreply, %State{}} = Dispatcher.handle_info(:poll, State.new())

      dispatched = collect_dispatched([])

      assert quiet_company.id in dispatched,
             "the quiet tenant never got a slot: #{inspect(dispatched)}"

      # The loud tenant is not shut out either — fair share, not round-robin
      # starvation in the other direction.
      assert company.id in dispatched

      assert Issues.get_issue!(quiet_issue.id).status == :in_progress
      assert Issues.get_issue!(issue.id).company_id == company.id
    end
  end

  test "paused issues at the head of the queue do not starve dispatch", %{
    company: company,
    agent: agent,
    issue: issue
  } do
    # Runnability is filtered in Elixir after the SQL LIMIT, so a full page of
    # non-runnable issues used to leave nothing to dispatch — for every tenant,
    # on every poll, indefinitely. Nothing clears a runtime pause on a timer,
    # and a budget hard stop sets that flag automatically.
    for n <- 1..14 do
      {:ok, paused} =
        Issues.create_issue(%{
          title: "Paused critical #{n}",
          description: "Ranks above the dispatchable issue",
          status: :todo,
          priority: :critical,
          company_id: company.id,
          assignee_id: agent.id,
          assigned_role: "engineer"
        })

      {:ok, _} = Issues.pause_issue_runtime(paused, reason: "budget hard stop")
    end

    test_pid = self()

    with_mocks([
      {Runtime, [], [dispatchable?: fn _issue, _agent -> :ok end]},
      {Orchestrator, [],
       [
         start_and_run: fn checked_out, _agent_id ->
           send(test_pid, {:dispatched, checked_out.id})
           {:ok, spawn(fn -> Process.sleep(200) end)}
         end,
         whereis: fn _issue_id -> nil end,
         stop: fn _issue_id, _reason -> :ok end
       ]}
    ]) do
      assert {:noreply, %State{} = state} =
               Dispatcher.handle_info({:poll_company, company.id}, State.new())

      assert_received {:dispatched, dispatched_id}
      assert dispatched_id == issue.id
      assert MapSet.member?(state.running_issue_ids, issue.id)
    end
  end

  test "orchestrator start failure releases the checkout so the retry can run", %{
    company: company,
    issue: issue
  } do
    with_mocks([
      {Runtime, [], [dispatchable?: fn _issue, _agent -> :ok end]},
      {Orchestrator, [],
       [
         start_and_run: fn _issue, _agent_id -> {:error, :boom} end,
         whereis: fn _issue_id -> nil end,
         stop: fn _issue_id, _reason -> :ok end
       ]}
    ]) do
      # Drive one poll inline (the dispatcher GenServer is disabled in tests).
      assert {:noreply, %State{} = state} =
               Dispatcher.handle_info({:poll_company, company.id}, State.new())

      # The failed start must not leave the issue checked out in
      # :in_progress — that state is invisible to the candidate query, so
      # the scheduled retry would never fire.
      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :todo
      assert reloaded.assignee_id == nil

      assert %{attempts: 1} = state.retry_attempts[issue.id]
      refute MapSet.member?(state.running_issue_ids, issue.id)
    end
  end

  test "advisory local denial consumes no slot while a later gateway dispatches", %{
    company: company,
    agent: local_agent,
    issue: local_issue
  } do
    {:ok, local_agent} =
      Agents.update_agent(local_agent, %{
        adapter: :process,
        config: %{"command" => "echo", "repo_capable" => true}
      })

    {:ok, local_issue} = Issues.update_issue(local_issue, %{priority: :critical})

    {:ok, gateway_agent} =
      Agents.create_agent(%{
        name: "Later gateway CEO",
        role: :ceo,
        status: :idle,
        company_id: company.id,
        adapter: :http,
        config: %{"url" => "https://example.com/runtime"}
      })

    {:ok, gateway_issue} =
      Issues.create_issue(%{
        title: "Strategic gateway follow-up",
        description: "CEO task after a deferred local candidate",
        status: :todo,
        priority: :high,
        company_id: company.id,
        assignee_id: gateway_agent.id,
        assigned_role: "ceo"
      })

    test_pid = self()
    local_issue_id = local_issue.id

    with_mocks([
      {Cympho.RuntimeAdmission, [],
       [
         available: fn
           Cympho.Adapters.ProcessAdapter -> {:error, :local_slots_exhausted}
           Cympho.Adapters.HttpAdapter -> :ok
         end
       ]},
      {Orchestrator, [],
       [
         start_and_run: fn checked_out, _agent_id ->
           send(test_pid, {:provider_started, checked_out.id})
           {:ok, spawn(fn -> Process.sleep(200) end)}
         end,
         whereis: fn _issue_id -> nil end,
         stop: fn _issue_id, _reason -> :ok end
       ]}
    ]) do
      assert {:noreply, %State{} = state} =
               Dispatcher.handle_info({:poll_company, company.id}, State.new())

      assert_received {:provider_started, gateway_id}
      assert gateway_id == gateway_issue.id
      refute_received {:provider_started, ^local_issue_id}

      local = Issues.get_issue!(local_issue.id)
      gateway = Issues.get_issue!(gateway_issue.id)

      assert local.status == :todo
      assert local.assignee_id == local_agent.id
      assert gateway.status == :in_progress

      assert %{attempts: 1, next_retry_at: retry_at} = state.retry_attempts[local.id]
      assert retry_at > :os.system_time(:millisecond)
      refute MapSet.member?(state.running_issue_ids, local.id)
      assert MapSet.member?(state.running_issue_ids, gateway.id)
      assert MapSet.size(state.running_issue_ids) == 1
    end
  end

  test "orchestrator ownership conflict preserves a successor run checkout", %{
    company: company,
    agent: agent,
    issue: issue
  } do
    test_pid = self()

    with_mocks([
      {Runtime, [], [dispatchable?: fn _issue, _agent -> :ok end]},
      {Orchestrator, [],
       [
         start_and_run: fn checked_out, agent_id ->
           assert {:ok, successor_run} =
                    Cympho.HeartbeatEngine.create_run(%{
                      company_id: checked_out.company_id,
                      agent_id: agent_id,
                      issue_id: checked_out.id,
                      adapter: "claude_code",
                      bind_checkout: true
                    })

           send(test_pid, {:successor_run, successor_run.id})
           {:error, {:checkout_run_bind_failed, :checkout_run_conflict}}
         end,
         whereis: fn _issue_id -> nil end,
         stop: fn _issue_id, _reason -> :ok end
       ]}
    ]) do
      assert {:noreply, %State{} = state} =
               Dispatcher.handle_info({:poll_company, company.id}, State.new())

      assert_received {:successor_run, successor_run_id}

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :in_progress
      assert reloaded.assignee_id == agent.id
      assert reloaded.checkout_run_id == successor_run_id
      assert reloaded.checked_out_at

      assert {:ok, %{status: "pending"}} =
               Cympho.HeartbeatEngine.get_run(successor_run_id)

      assert %{attempts: 1} = state.retry_attempts[issue.id]
      refute MapSet.member?(state.running_issue_ids, issue.id)
    end
  end

  describe "crash reclaim (orchestrator DOWN)" do
    test "preserves assignee like orphan reclaim", %{agent: agent, issue: issue} do
      ensure_dispatcher_for_db_tests()
      dispatcher = Process.whereis(Dispatcher)
      # Shared sandbox covers most cases; allow is belt-and-suspenders when
      # the dispatcher GenServer predates this test's owner.
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, self(), dispatcher)

      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert checked_out.status == :in_progress
      assert checked_out.assignee_id == agent.id
      assert is_nil(Orchestrator.whereis(checked_out.id))

      checked_out = backdate_checkout(checked_out)

      # Simulate a monitored fake orchestrator that dies non-gracefully so
      # release_crashed_session_issue runs (brutal kill skips terminate/2).
      fake_orchestrator = spawn(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(dispatcher, fn %State{} = state ->
        ref = Process.monitor(fake_orchestrator)

        %{
          state
          | running_issue_ids: MapSet.put(state.running_issue_ids, checked_out.id),
            monitors: Map.put(state.monitors, ref, checked_out.id)
        }
      end)

      Process.exit(fake_orchestrator, :kill)

      wait_until(fn ->
        reloaded = Issues.get_issue!(issue.id)
        assert reloaded.status == :todo
        assert is_nil(reloaded.checkout_run_id)
        assert is_nil(reloaded.checked_out_at)
        assert reloaded.assignee_id == agent.id
      end)
    end

    test "does not clear a successor-bound checkout_run_id", %{
      agent: agent,
      company: company,
      issue: issue
    } do
      ensure_dispatcher_for_db_tests()

      {:ok, checked_out} = Issues.checkout_issue(issue, agent)

      # Snapshot as the crashed path would see it (no run bound yet).
      stale_snapshot = Issues.get_issue!(checked_out.id)
      assert is_nil(stale_snapshot.checkout_run_id)

      # Successor binds a run (bumps lock_version + sets checkout_run_id).
      assert {:ok, successor_run} =
               Cympho.HeartbeatEngine.create_run(%{
                 company_id: company.id,
                 agent_id: agent.id,
                 issue_id: checked_out.id,
                 adapter: "claude_code",
                 bind_checkout: true
               })

      bound = Issues.get_issue!(issue.id)
      assert bound.checkout_run_id == successor_run.id
      assert bound.lock_version > stale_snapshot.lock_version

      # Stale clear_checkout_lock (same CAS used by crash reclaim) must lose.
      assert {:error, :checkout_conflict} =
               Issues.clear_checkout_lock(stale_snapshot, :todo)

      still = Issues.get_issue!(issue.id)
      assert still.checkout_run_id == successor_run.id
      assert still.assignee_id == agent.id
      assert still.status == :in_progress
    end

    test "does not cancel a successor-bound run on crash reclaim", %{
      agent: agent,
      company: company,
      issue: issue
    } do
      ensure_dispatcher_for_db_tests()
      dispatcher = Process.whereis(Dispatcher)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, self(), dispatcher)

      {:ok, checked_out} = Issues.checkout_issue(issue, agent)

      # Dead-session leftover run (not bound) must be safe to recover later;
      # the successor run must never be cancelled by crash reclaim.
      assert {:ok, _dead_run} =
               Cympho.HeartbeatEngine.create_run(%{
                 company_id: company.id,
                 agent_id: agent.id,
                 issue_id: checked_out.id,
                 adapter: "claude_code"
               })

      assert {:ok, successor_run} =
               Cympho.HeartbeatEngine.create_run(%{
                 company_id: company.id,
                 agent_id: agent.id,
                 issue_id: checked_out.id,
                 adapter: "claude_code",
                 bind_checkout: true
               })

      bound = Issues.get_issue!(issue.id)
      assert bound.checkout_run_id == successor_run.id
      assert bound.status == :in_progress

      fake_orchestrator = spawn(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(dispatcher, fn %State{} = state ->
        ref = Process.monitor(fake_orchestrator)

        %{
          state
          | running_issue_ids: MapSet.put(state.running_issue_ids, checked_out.id),
            monitors: Map.put(state.monitors, ref, checked_out.id)
        }
      end)

      Process.exit(fake_orchestrator, :kill)

      wait_until(fn ->
        state = Dispatcher.state()
        refute MapSet.member?(state.running_issue_ids, checked_out.id)
      end)

      # Give the DOWN handler time to finish reclaim after slot free.
      wait_until(fn ->
        still = Issues.get_issue!(issue.id)
        assert still.status == :in_progress
        assert still.checkout_run_id == successor_run.id
        assert still.assignee_id == agent.id

        assert {:ok, %{status: "pending"}} =
                 Cympho.HeartbeatEngine.get_run(successor_run.id)
      end)
    end
  end

  describe "recover_orphaned_in_progress/0" do
    test "reclaims stranded :in_progress keeping assignee when no orchestrator", %{
      agent: agent,
      issue: issue
    } do
      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert checked_out.status == :in_progress

      checked_out = backdate_checkout(checked_out)
      assert checked_out.assignee_id == agent.id
      assert is_nil(Orchestrator.whereis(checked_out.id))

      result = Dispatcher.recover_orphaned_in_progress()

      assert result.recovered >= 1

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :todo
      assert reloaded.assignee_id == agent.id
      assert is_nil(reloaded.checked_out_at)
      assert is_nil(reloaded.checkout_run_id)
    end

    test "does not release when a live orchestrator is registered", %{
      agent: agent,
      issue: issue
    } do
      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert checked_out.status == :in_progress

      checked_out = backdate_checkout(checked_out)

      {:ok, _} = Registry.register(Cympho.OrchestratorRegistry, checked_out.id, nil)
      assert is_pid(Orchestrator.whereis(checked_out.id))

      result = Dispatcher.recover_orphaned_in_progress()

      assert result.skipped >= 1

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :in_progress
      assert reloaded.assignee_id == agent.id
    end

    test "does not reclaim a fresh checkout during the cross-node startup window", %{
      agent: agent,
      issue: issue
    } do
      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert is_nil(Orchestrator.whereis(checked_out.id))

      result = Dispatcher.recover_orphaned_in_progress()

      assert result.recovered == 0
      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :in_progress
      assert reloaded.checked_out_at == checked_out.checked_out_at
    end

    test "re-checks live orchestrator inside reclaim before cancel_and_release", %{
      agent: agent,
      issue: issue
    } do
      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert checked_out.status == :in_progress
      assert is_nil(Orchestrator.whereis(checked_out.id))

      checked_out = backdate_checkout(checked_out)

      # Outer recover_orphaned_in_progress sees no orch (first whereis), then a
      # successor registers before reclaim_orphaned_issue mutates — second live
      # check must skip cancel_and_release / clear_checkout_lock.
      call_count = :atomics.new(1, signed: false)

      with_mocks([
        {Orchestrator, [],
         [
           whereis: fn issue_id ->
             if issue_id == checked_out.id do
               n = :atomics.add_get(call_count, 1, 1)

               if n == 1 do
                 nil
               else
                 # Live pid for subsequent checks inside reclaim_orphaned_issue.
                 self()
               end
             else
               nil
             end
           end
         ]}
      ]) do
        result = Dispatcher.recover_orphaned_in_progress()

        assert result.skipped >= 1

        reloaded = Issues.get_issue!(issue.id)
        assert reloaded.status == :in_progress
        assert reloaded.assignee_id == agent.id
        assert reloaded.checked_out_at
      end
    end

    test "does not release when a non-terminal run exists", %{
      agent: agent,
      company: company,
      issue: issue
    } do
      {:ok, checked_out} = Issues.checkout_issue(issue, agent)

      checked_out = backdate_checkout(checked_out)

      {:ok, _run} =
        Cympho.HeartbeatEngine.create_run(%{
          company_id: company.id,
          agent_id: agent.id,
          issue_id: checked_out.id,
          adapter: "claude_code"
        })

      assert is_nil(Orchestrator.whereis(checked_out.id))

      result = Dispatcher.recover_orphaned_in_progress()

      assert result.skipped >= 1

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :in_progress
      assert reloaded.assignee_id == agent.id
    end
  end

  describe "poll recovers orphaned runs (zombie runs)" do
    test "do_poll terminalizes orphaned runs so they cannot pin reclaim", %{
      agent: agent,
      company: company,
      issue: issue
    } do
      {:ok, checked_out} = Issues.checkout_issue(issue, agent)

      assert {:ok, zombie_run} =
               Cympho.HeartbeatEngine.create_run(%{
                 company_id: company.id,
                 agent_id: agent.id,
                 issue_id: checked_out.id,
                 adapter: "claude_code"
               })

      assert zombie_run.status == "pending"
      assert is_nil(Orchestrator.whereis(checked_out.id))

      backdate_run(zombie_run)

      # Inline poll (same path as handle_info :poll / :poll_company) must run
      # recover_orphaned_runs — previously only handle_continue(:recover_orphans)
      # did, leaving zombies until restart.
      with_mocks([
        {Runtime, [], [dispatchable?: fn _issue, _agent -> :ok end]},
        {Orchestrator, [],
         [
           start_and_run: fn _issue, _agent_id -> {:error, :boom} end,
           whereis: fn _issue_id -> nil end,
           stop: fn _issue_id, _reason -> :ok end
         ]}
      ]) do
        assert {:noreply, %State{}} =
                 Dispatcher.handle_info({:poll_company, company.id}, State.new())
      end

      assert {:ok, recovered} = Cympho.HeartbeatEngine.get_run(zombie_run.id)
      assert recovered.status == "cancelled"

      reloaded = Issues.get_issue!(issue.id)
      # Orphan issue reclaim can proceed once the zombie run is terminal.
      assert reloaded.status in [:todo, :in_progress]
    end

    test "handle_continue(:recover_orphans) still recovers orphaned runs", %{
      agent: agent,
      company: company,
      issue: issue
    } do
      {:ok, checked_out} = Issues.checkout_issue(issue, agent)

      assert {:ok, zombie_run} =
               Cympho.HeartbeatEngine.create_run(%{
                 company_id: company.id,
                 agent_id: agent.id,
                 issue_id: checked_out.id,
                 adapter: "claude_code"
               })

      backdate_run(zombie_run)

      assert {:noreply, %State{}} =
               Dispatcher.handle_continue(:recover_orphans, State.new())

      assert {:ok, recovered} = Cympho.HeartbeatEngine.get_run(zombie_run.id)
      assert recovered.status == "cancelled"
    end
  end

  describe "recover_stale_checkouts/0" do
    test "clears age-threshold checkouts while preserving assignee", %{
      agent: agent,
      issue: issue
    } do
      {:ok, checked_out} = Issues.checkout_issue(issue, agent)

      old =
        DateTime.utc_now()
        |> DateTime.add(-3 * 60 * 60, :second)
        |> DateTime.truncate(:second)

      checked_out
      |> Ecto.Changeset.change(%{checked_out_at: old})
      |> Cympho.Repo.update!()

      result = Dispatcher.recover_stale_checkouts()

      assert result.released >= 1
      assert result.exhausted == 0

      assert Cympho.Repo.exists?(
               Ecto.Query.from(c in Cympho.Recovery.RecoveryCase,
                 where:
                   c.issue_id == ^issue.id and c.source_type == "issue_checkout" and
                     c.state == "recovered"
               )
             )

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :todo
      assert reloaded.assignee_id == agent.id
      assert is_nil(reloaded.checked_out_at)
    end
  end

  defp backdate_checkout(issue) do
    old = DateTime.utc_now() |> DateTime.add(-16 * 60, :second) |> DateTime.truncate(:second)
    issue |> Ecto.Changeset.change(checked_out_at: old) |> Cympho.Repo.update!()
  end

  defp backdate_run(run) do
    old = DateTime.utc_now() |> DateTime.add(-16 * 60, :second) |> DateTime.truncate(:second)
    run |> Ecto.Changeset.change(inserted_at: old) |> Cympho.Repo.update!()
  end

  describe "poll scheduling" do
    # `poll_now/0` sends the same `:poll` message the periodic timer uses, and
    # it runs on issue launch, dashboard actions, and event heartbeats. If the
    # handler re-armed unconditionally, each on-demand poll would leave behind
    # an extra self-perpetuating timer chain and the poll rate would grow
    # without bound for the life of the node.
    test "handling :poll leaves exactly one armed timer" do
      {:noreply, first} = Dispatcher.handle_info(:poll, State.new())

      assert is_reference(first.poll_timer)
      assert is_integer(Process.read_timer(first.poll_timer))

      {:noreply, second} = Dispatcher.handle_info(:poll, first)

      refute second.poll_timer == first.poll_timer
      assert Process.read_timer(first.poll_timer) == false
      assert is_integer(Process.read_timer(second.poll_timer))
    end

    test "repeated on-demand polls never accumulate timers" do
      state =
        Enum.reduce(1..5, State.new(), fn _, acc ->
          {:noreply, next} = Dispatcher.handle_info(:poll, acc)
          next
        end)

      assert is_integer(Process.read_timer(state.poll_timer))

      # Nothing else is armed: draining the mailbox finds no stray :poll.
      refute_received :poll
    end
  end

  defp collect_dispatched(acc) do
    receive do
      {:dispatched, company_id} -> collect_dispatched([company_id | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp create_registered_survivor(company) do
    unique = System.unique_integer([:positive])

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Restart slot agent #{unique}",
        role: :engineer,
        status: :idle,
        company_id: company.id,
        adapter: :claude_code
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Restart slot issue #{unique}",
        status: :todo,
        company_id: company.id,
        assignee_id: agent.id
      })

    {:ok, checked_out} = Issues.checkout_issue(issue, agent)
    {start_registered_orchestrator(checked_out.id), checked_out}
  end

  defp start_registered_orchestrator(issue_id) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(Cympho.OrchestratorRegistry, issue_id, nil)
        send(parent, {:orchestrator_registered, self(), issue_id})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:orchestrator_registered, ^pid, ^issue_id}, 2_000

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    pid
  end

  defp ensure_dispatcher_for_db_tests do
    unless Process.whereis(Dispatcher) do
      {:ok, _} = Dispatcher.start_link([])
    end
  end
end
