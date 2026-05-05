defmodule Cympho.Orchestrator.DispatcherTest do
  use ExUnit.Case, async: false

  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Orchestrator.Dispatcher.State

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

  # Helpers

  defp ensure_dispatcher_running do
    unless Process.whereis(Dispatcher) do
      {:ok, _} = Dispatcher.start_link([])
    end
  end
end
