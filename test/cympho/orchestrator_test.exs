defmodule Cympho.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Cympho.Orchestrator
  alias Cympho.Orchestrator.Session

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

  describe "orchestrator lifecycle" do
    @tag :capture_log
    test "start_link creates orchestrator registered by issue id" do
      issue = %{id: "orch-test-1", title: "Test", description: "Desc"}
      agent_id = "agent-1"

      {:ok, pid} = Orchestrator.start_link(issue, agent_id)
      assert Orchestrator.whereis(issue.id) == pid
    after
      # cleanup
      if pid = Orchestrator.whereis("orch-test-1") do
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

      {:ok, pid} = Orchestrator.start_link(issue, agent_id)
      assert Orchestrator.whereis(issue.id) == pid
      assert :ok = Orchestrator.stop(issue.id)
      # Give the Registry time to clean up the entry
      :timer.sleep(50)
      assert Orchestrator.whereis(issue.id) == nil
    end
  end
end