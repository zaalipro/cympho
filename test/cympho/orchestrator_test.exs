defmodule Cympho.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Cympho.Orchestrator
  alias Cympho.Orchestrator.Session

  setup do
    unless Process.whereis(Cympho.OrchestratorRegistry) do
      start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
    end

    on_exit(fn ->
      Registry.select(Cympho.OrchestratorRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])
      |> Enum.each(fn pid ->
        try do
          GenServer.stop(pid, :normal, 500)
        catch
          _, _ -> :ok
        end
      end)
    end)

    :ok
  end

  describe "Session struct" do
    test "has required fields" do
      session = %Session{
        issue: %{id: "test-1", title: "Test", description: "Desc"},
        agent_id: "agent-1"
      }

      assert session.issue.id == "test-1"
      assert session.agent_id == "agent-1"
      assert session.session_id == nil
      assert session.turn_count == 0
    end

    test "can be created with all fields" do
      session = %Session{
        issue: %{id: "test-1", title: "Test", description: "Desc"},
        agent_id: "agent-1",
        session_id: make_ref(),
        turn_count: 0
      }

      assert session.turn_count == 0
    end
  end

  describe "start_and_run/2" do
    @tag :capture_log
    test "starts orchestrator registered by issue id" do
      issue = %{id: "orch-test-2", title: "Test", description: "Desc"}
      agent_id = "agent-1"

      {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
      assert Orchestrator.whereis(issue.id) == pid
    after
      if pid = Orchestrator.whereis("orch-test-2") do
        GenServer.stop(pid)
      end
    end

    test "returns error if orchestrator already running for issue" do
      issue = %{id: "orch-test-3", title: "Test", description: "Desc"}
      agent_id = "agent-1"

      {:ok, pid1} = Orchestrator.start_and_run(issue, agent_id)
      {:error, :already_started} = Orchestrator.start_and_run(issue, agent_id)
    after
      if pid = Orchestrator.whereis("orch-test-3") do
        GenServer.stop(pid)
      end
    end

    @tag :capture_log
    test "whereis returns nil for non-existent orchestrator" do
      assert Orchestrator.whereis("non-existent-id") == nil
    end

    @tag :capture_log
    test "stop returns :ok for non-existent orchestrator" do
      assert :ok = Orchestrator.stop("non-existent-id")
    end

    @tag :capture_log
    test "stop terminates existing orchestrator" do
      issue = %{id: "orch-stop-test", title: "Test", description: "Desc"}
      agent_id = "agent-1"

      {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
      assert Orchestrator.whereis(issue.id) == pid
      assert :ok = Orchestrator.stop(issue.id)
      # Give the Registry time to clean up the entry
      :timer.sleep(50)
      assert Orchestrator.whereis(issue.id) == nil
    end
  end

  describe "whereis/1" do
    test "returns pid for running orchestrator" do
      issue = %{id: "orch-test-4", title: "Test", description: "Desc"}
      agent_id = "agent-1"

      {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
      assert Orchestrator.whereis(issue.id) == pid
    after
      if pid = Orchestrator.whereis("orch-test-4") do
        GenServer.stop(pid)
      end
    end

    test "returns nil for unknown issue" do
      assert Orchestrator.whereis("nonexistent-issue") == nil
    end
  end

  describe "stop/1" do
    test "stops running orchestrator" do
      issue = %{id: "orch-test-5", title: "Test", description: "Desc"}
      agent_id = "agent-1"

      {:ok, pid} = Orchestrator.start_and_run(issue, agent_id)
      assert Orchestrator.whereis(issue.id) == pid

      Orchestrator.stop(issue.id)
      :timer.sleep(50)
      assert Orchestrator.whereis(issue.id) == nil
    end

    test "handles stop for unknown issue gracefully" do
      Orchestrator.stop("nonexistent-issue")
    end
  end
end
