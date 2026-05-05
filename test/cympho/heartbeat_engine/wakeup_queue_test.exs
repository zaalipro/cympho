defmodule Cympho.HeartbeatEngine.WakeupQueueTest do
  # async: false because the depth-cap describe mutates Application env
  # (`:wakeup_queue, :max_pending_per_agent`), which is process-global
  # and would race with concurrent tests that enqueue >3 wakes per agent.
  use Cympho.DataCase, async: false

  alias Cympho.HeartbeatEngine.WakeupQueue

  setup do
    {:ok, agent} =
      Cympho.Agents.create_agent(%{
        name: "WakeTest #{System.unique_integer()}",
        role: :engineer,
        status: :idle
      })

    {:ok, project} =
      Cympho.Projects.create_project(%{
        name: "WakeTestProject #{System.unique_integer()}",
        prefix: "WKP"
      })

    {:ok, issue} =
      Cympho.Issues.create_issue(%{
        title: "WakeTest Issue",
        description: "test",
        project_id: project.id
      })

    {:ok, issue2} =
      Cympho.Issues.create_issue(%{
        title: "WakeTest Issue 2",
        description: "test",
        project_id: project.id
      })

    %{agent: agent, issue: issue, issue2: issue2}
  end

  describe "enqueue/1" do
    test "creates a new wake entry", %{agent: agent, issue: issue} do
      assert {:ok, wake} =
               WakeupQueue.enqueue(%{
                 agent_id: agent.id,
                 issue_id: issue.id,
                 reason: "issue_commented"
               })

      assert wake.agent_id == agent.id
      assert wake.issue_id == issue.id
      assert wake.reason == "issue_commented"
    end

    test "coalesces duplicate wake for same agent/issue/reason", %{agent: agent, issue: issue} do
      {:ok, _first} =
        WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: "issue_commented",
          metadata: %{"key" => "value1"}
        })

      {:ok, second} =
        WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: "issue_commented",
          metadata: %{"key" => "value2"}
        })

      count = WakeupQueue.pending_count(agent.id)
      assert count == 1

      assert second.metadata["key"] == "value2"
    end

    test "allows different reasons for same agent/issue", %{agent: agent, issue: issue} do
      {:ok, _} =
        WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: "issue_commented"
        })

      {:ok, _} =
        WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: "issue_blockers_resolved"
        })

      assert WakeupQueue.pending_count(agent.id) == 2
    end
  end

  describe "dequeue/1" do
    test "returns the oldest pending wake for an agent", %{
      agent: agent,
      issue: issue,
      issue2: issue2
    } do
      {:ok, first} =
        WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: "issue_commented"
        })

      # Ensure different timestamp
      Process.sleep(1100)

      {:ok, _latest} =
        WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue2.id,
          reason: "issue_blockers_resolved"
        })

      assert {:ok, dequeued} = WakeupQueue.dequeue(agent.id)
      assert dequeued.id == first.id
    end

    test "returns error when no wakes exist" do
      assert {:error, :empty} = WakeupQueue.dequeue(Ecto.UUID.generate())
    end
  end

  describe "pending_count/1" do
    test "returns 0 for agent with no wakes" do
      assert WakeupQueue.pending_count(Ecto.UUID.generate()) == 0
    end

    test "counts wakes for an agent", %{agent: agent, issue: issue, issue2: issue2} do
      WakeupQueue.enqueue(%{
        agent_id: agent.id,
        issue_id: issue.id,
        reason: "issue_commented"
      })

      WakeupQueue.enqueue(%{
        agent_id: agent.id,
        issue_id: issue2.id,
        reason: "issue_commented"
      })

      WakeupQueue.enqueue(%{
        agent_id: agent.id,
        issue_id: issue.id,
        reason: "issue_blockers_resolved"
      })

      assert WakeupQueue.pending_count(agent.id) == 3
    end
  end

  describe "consume_for/2" do
    test "marks pending wakes for an agent and issue as consumed", %{agent: agent, issue: issue} do
      {:ok, _wake} =
        WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: "issue_commented"
        })

      assert WakeupQueue.pending_count(agent.id) == 1
      assert :ok = WakeupQueue.consume_for(agent.id, issue.id)
      assert WakeupQueue.pending_count(agent.id) == 0
    end
  end

  describe "list_pending/1" do
    test "returns wakes ordered by most recent first", %{
      agent: agent,
      issue: issue,
      issue2: issue2
    } do
      {:ok, _first} =
        WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: "issue_commented"
        })

      Process.sleep(1100)

      {:ok, second} =
        WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue2.id,
          reason: "issue_blockers_resolved"
        })

      wakes = WakeupQueue.list_pending(agent.id)
      assert length(wakes) == 2
      assert hd(wakes).id == second.id
    end

    test "respects limit option", %{agent: agent, issue: issue, issue2: issue2} do
      reasons = ["issue_commented", "issue_blockers_resolved", "issue_children_completed"]

      for reason <- reasons do
        WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: reason
        })
      end

      WakeupQueue.enqueue(%{
        agent_id: agent.id,
        issue_id: issue2.id,
        reason: "issue_commented"
      })

      WakeupQueue.enqueue(%{
        agent_id: agent.id,
        issue_id: issue2.id,
        reason: "issue_blockers_resolved"
      })

      wakes = WakeupQueue.list_pending(agent.id, limit: 2)
      assert length(wakes) == 2
    end
  end

  describe "enqueue/1 depth cap" do
    setup do
      original = Application.get_env(:cympho, :wakeup_queue, [])
      Application.put_env(:cympho, :wakeup_queue, max_pending_per_agent: 3)
      on_exit(fn -> Application.put_env(:cympho, :wakeup_queue, original) end)
      :ok
    end

    test "rejects new wakes once the per-agent cap is exceeded", %{
      agent: agent,
      issue: issue,
      issue2: issue2
    } do
      assert {:ok, _} =
               WakeupQueue.enqueue(%{
                 agent_id: agent.id,
                 issue_id: issue.id,
                 reason: "issue_commented"
               })

      assert {:ok, _} =
               WakeupQueue.enqueue(%{
                 agent_id: agent.id,
                 issue_id: issue.id,
                 reason: "issue_blockers_resolved"
               })

      assert {:ok, _} =
               WakeupQueue.enqueue(%{
                 agent_id: agent.id,
                 issue_id: issue2.id,
                 reason: "issue_commented"
               })

      assert {:error, :wakeup_queue_full} =
               WakeupQueue.enqueue(%{
                 agent_id: agent.id,
                 issue_id: issue2.id,
                 reason: "issue_blockers_resolved"
               })
    end

    test "coalescing into an existing wake bypasses the cap", %{agent: agent, issue: issue} do
      {:ok, _} =
        WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: "issue_commented"
        })

      {:ok, _} =
        WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: "issue_blockers_resolved"
        })

      {:ok, _} =
        WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: "issue_children_completed"
        })

      # Coalescing same (agent, issue, reason) into the existing wake is
      # always allowed — we update the existing row rather than insert.
      assert {:ok, _} =
               WakeupQueue.enqueue(%{
                 agent_id: agent.id,
                 issue_id: issue.id,
                 reason: "issue_commented",
                 metadata: %{"again" => true}
               })
    end
  end
end
