defmodule Cympho.AgentHeartbeatTest do
  use Cympho.DataCase, async: false

  alias Cympho.AgentHeartbeat

  setup do
    case start_supervised({Cympho.AgentHeartbeat.Supervisor, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case start_supervised({Registry, keys: :unique, name: Cympho.AgentHeartbeat.Registry}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "start_for_agent/1" do
    test "starts a heartbeat process for a new agent" do
      agent_id = Ecto.UUID.generate()

      assert {:ok, pid} = AgentHeartbeat.start_for_agent(agent_id)
      assert Process.alive?(pid)

      # Clean up
      AgentHeartbeat.stop_for_agent(agent_id)
    end

    test "returns error for already-started agent" do
      agent_id = Ecto.UUID.generate()

      assert {:ok, pid} = AgentHeartbeat.start_for_agent(agent_id)
      assert Process.alive?(pid)
      assert {:error, :already_started} = AgentHeartbeat.start_for_agent(agent_id)

      # Clean up
      AgentHeartbeat.stop_for_agent(agent_id)
    end
  end

  describe "stop_for_agent/1" do
    test "stops a running heartbeat process" do
      agent_id = Ecto.UUID.generate()

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent_id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
      assert :ok = AgentHeartbeat.stop_for_agent(agent_id)
      assert {:error, :not_found} = AgentHeartbeat.stop_for_agent(agent_id)
    end

    test "returns error when agent is not running" do
      assert {:error, :not_found} =
               AgentHeartbeat.stop_for_agent("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "status/1" do
    test "returns idle status for a newly started agent" do
      agent_id = Ecto.UUID.generate()

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent_id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
      assert {:ok, :idle} = AgentHeartbeat.status(agent_id)

      # Clean up
      AgentHeartbeat.stop_for_agent(agent_id)
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = AgentHeartbeat.status("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "set_working/2" do
    test "transitions agent to running status" do
      agent_id = Ecto.UUID.generate()
      issue_id = Ecto.UUID.generate()

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent_id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
      assert :ok = AgentHeartbeat.set_working(agent_id, issue_id)
      assert {:ok, :running} = AgentHeartbeat.status(agent_id)

      # Clean up
      AgentHeartbeat.stop_for_agent(agent_id)
    end
  end

  describe "set_idle/1" do
    test "transitions agent back to idle status" do
      agent_id = Ecto.UUID.generate()
      issue_id = Ecto.UUID.generate()

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent_id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
      AgentHeartbeat.set_working(agent_id, issue_id)
      assert :ok = AgentHeartbeat.set_idle(agent_id)
      assert {:ok, :idle} = AgentHeartbeat.status(agent_id)

      # Clean up
      AgentHeartbeat.stop_for_agent(agent_id)
    end
  end

  describe "lifecycle" do
    test "agent heartbeat process starts and stops cleanly" do
      agent_id = Ecto.UUID.generate()

      {:ok, pid} = AgentHeartbeat.start_for_agent(agent_id)
      Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
      assert is_pid(pid)
      assert Process.alive?(pid)

      :ok = AgentHeartbeat.stop_for_agent(agent_id)
      refute Process.alive?(pid)
    end
  end
end
