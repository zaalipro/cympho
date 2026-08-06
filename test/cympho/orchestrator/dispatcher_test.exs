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

      {:ok, _} = Registry.register(Cympho.OrchestratorRegistry, checked_out.id, nil)
      assert is_pid(Orchestrator.whereis(checked_out.id))

      result = Dispatcher.recover_orphaned_in_progress()

      assert result.skipped >= 1

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :in_progress
      assert reloaded.assignee_id == agent.id
    end

    test "re-checks live orchestrator inside reclaim before cancel_and_release", %{
      agent: agent,
      issue: issue
    } do
      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert checked_out.status == :in_progress
      assert is_nil(Orchestrator.whereis(checked_out.id))

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

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :todo
      assert reloaded.assignee_id == agent.id
      assert is_nil(reloaded.checked_out_at)
    end
  end

  defp ensure_dispatcher_for_db_tests do
    unless Process.whereis(Dispatcher) do
      {:ok, _} = Dispatcher.start_link([])
    end
  end
end
