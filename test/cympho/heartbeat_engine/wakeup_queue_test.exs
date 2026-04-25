defmodule Cympho.HeartbeatEngine.WakeupQueueTest do
  use Cympho.DataCase, async: true

  alias Cympho.HeartbeatEngine.WakeupQueue

  describe "enqueue/1" do
    test "creates a new wake entry" do
      agent_id = Ecto.UUID.generate()
      issue_id = Ecto.UUID.generate()

      assert {:ok, wake} =
               WakeupQueue.enqueue(%{
                 agent_id: agent_id,
                 issue_id: issue_id,
                 reason: "issue_commented"
               })

      assert wake.agent_id == agent_id
      assert wake.issue_id == issue_id
      assert wake.reason == "issue_commented"
    end

    test "coalesces duplicate wake for same agent/issue/reason" do
      agent_id = Ecto.UUID.generate()
      issue_id = Ecto.UUID.generate()

      {:ok, _first} =
        WakeupQueue.enqueue(%{
          agent_id: agent_id,
          issue_id: issue_id,
          reason: "issue_commented",
          metadata: %{"key" => "value1"}
        })

      {:ok, second} =
        WakeupQueue.enqueue(%{
          agent_id: agent_id,
          issue_id: issue_id,
          reason: "issue_commented",
          metadata: %{"key" => "value2"}
        })

      count = WakeupQueue.pending_count(agent_id)
      assert count == 1

      assert second.metadata["key"] == "value2"
    end

    test "allows different reasons for same agent/issue" do
      agent_id = Ecto.UUID.generate()
      issue_id = Ecto.UUID.generate()

      {:ok, _} =
        WakeupQueue.enqueue(%{
          agent_id: agent_id,
          issue_id: issue_id,
          reason: "issue_commented"
        })

      {:ok, _} =
        WakeupQueue.enqueue(%{
          agent_id: agent_id,
          issue_id: issue_id,
          reason: "issue_blockers_resolved"
        })

      assert WakeupQueue.pending_count(agent_id) == 2
    end
  end

  describe "dequeue/1" do
    test "returns the most recent wake for an agent" do
      agent_id = Ecto.UUID.generate()

      {:ok, _} =
        WakeupQueue.enqueue(%{
          agent_id: agent_id,
          issue_id: Ecto.UUID.generate(),
          reason: "issue_commented"
        })

      {:ok, latest} =
        WakeupQueue.enqueue(%{
          agent_id: agent_id,
          issue_id: Ecto.UUID.generate(),
          reason: "issue_blockers_resolved"
        })

      assert {:ok, dequeued} = WakeupQueue.dequeue(agent_id)
      assert dequeued.id == latest.id
    end

    test "returns error when no wakes exist" do
      assert {:error, :empty} = WakeupQueue.dequeue(Ecto.UUID.generate())
    end
  end

  describe "pending_count/1" do
    test "returns 0 for agent with no wakes" do
      assert WakeupQueue.pending_count(Ecto.UUID.generate()) == 0
    end

    test "counts wakes for an agent" do
      agent_id = Ecto.UUID.generate()

      for _ <- 1..3 do
        WakeupQueue.enqueue(%{
          agent_id: agent_id,
          issue_id: Ecto.UUID.generate(),
          reason: "issue_commented"
        })
      end

      assert WakeupQueue.pending_count(agent_id) == 3
    end
  end

  describe "list_pending/1" do
    test "returns wakes ordered by most recent first" do
      agent_id = Ecto.UUID.generate()

      {:ok, first} =
        WakeupQueue.enqueue(%{
          agent_id: agent_id,
          issue_id: Ecto.UUID.generate(),
          reason: "issue_commented"
        })

      {:ok, second} =
        WakeupQueue.enqueue(%{
          agent_id: agent_id,
          issue_id: Ecto.UUID.generate(),
          reason: "issue_blockers_resolved"
        })

      wakes = WakeupQueue.list_pending(agent_id)
      assert length(wakes) == 2
      assert hd(wakes).id == second.id
    end

    test "respects limit option" do
      agent_id = Ecto.UUID.generate()

      for _ <- 1..5 do
        WakeupQueue.enqueue(%{
          agent_id: agent_id,
          issue_id: Ecto.UUID.generate(),
          reason: "issue_commented"
        })
      end

      wakes = WakeupQueue.list_pending(agent_id, limit: 2)
      assert length(wakes) == 2
    end
  end
end
