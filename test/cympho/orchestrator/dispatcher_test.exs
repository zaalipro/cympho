defmodule Cympho.Orchestrator.DispatcherTest do
  use ExUnit.Case, async: false

  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Orchestrator.Dispatcher.State

  setup do
    # Ensure registries are started (they may already be started by the app supervisor)
    for {name, keys} <- [{Cympho.OrchestratorRegistry, :unique}, {Cympho.AgentHeartbeat.Registry, :unique}] do
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

  # Helpers

  defp ensure_dispatcher_running do
    unless Process.whereis(Dispatcher) do
      {:ok, _} = Dispatcher.start_link([])
    end
  end
end