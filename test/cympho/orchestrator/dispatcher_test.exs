defmodule Cympho.Orchestrator.DispatcherTest do
  use ExUnit.Case, async: false

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
      :timer.sleep(50)
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
      assert eventually(fn ->
               state = Dispatcher.state()

               not MapSet.member?(state.running_issue_ids, issue_id) and
                 not Enum.any?(state.monitors, fn {_ref, id} -> id == issue_id end)
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

      assert eventually(fn ->
               state = Dispatcher.state()

               not MapSet.member?(state.running_issue_ids, issue_id) and
                 not Enum.any?(state.monitors, fn {_ref, id} -> id == issue_id end)
             end)
    end
  end

  describe "runnable_candidate?/1" do
    test "parks blocked issues even when they have no blocker relations" do
      refute Dispatcher.runnable_candidate?(%Issue{status: :blocked, blocked_by: []})
    end

    test "rejects issues with active blockers and accepts resolved blockers" do
      refute Dispatcher.runnable_candidate?(%Issue{
               status: :todo,
               blocked_by: [%Issue{status: :in_progress}]
             })

      assert Dispatcher.runnable_candidate?(%Issue{
               status: :todo,
               blocked_by: [%Issue{status: :cancelled}]
             })
    end

    test "rejects issue-level paused work without changing workflow status" do
      refute Dispatcher.runnable_candidate?(%Issue{
               status: :todo,
               blocked_by: [],
               monitor_state: %{"issue_runtime" => %{"paused" => true}}
             })
    end
  end

  # Helpers

  defp ensure_dispatcher_running do
    unless Process.whereis(Dispatcher) do
      {:ok, _} = Dispatcher.start_link([])
    end
  end

  defp eventually(fun, attempts \\ 40)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end
end

defmodule Cympho.Orchestrator.DispatcherDbTest do
  use Cympho.DataCase, async: false

  import Mock

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
end
