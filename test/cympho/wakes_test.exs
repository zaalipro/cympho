defmodule Cympho.WakesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Wakes
  alias Cympho.Agents

  setup do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "Wake Test Agent",
        role: :engineer,
        status: :idle
      })

    %{agent: agent}
  end

  describe "wake_agent/2" do
    test "updates agent status to running", %{agent: agent} do
      assert {:ok, updated} = Wakes.wake_agent(agent.id)
      assert updated.status == :running
    end

    test "updates last_heartbeat_at", %{agent: agent} do
      assert {:ok, updated} = Wakes.wake_agent(agent.id)
      assert updated.last_heartbeat_at != nil
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Wakes.wake_agent("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "notify_comment/2" do
    test "updates last_heartbeat_at", %{agent: agent} do
      assert {:ok, updated} = Wakes.notify_comment(agent.id, %{body: "hello"})
      assert updated.last_heartbeat_at != nil
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} =
               Wakes.notify_comment("00000000-0000-0000-0000-000000000000", %{})
    end
  end
end
