defmodule Cympho.HeartbeatEngineTest do
  use Cympho.DataCase, async: true

  alias Cympho.HeartbeatEngine
  alias Cympho.HeartbeatEngine.Run

  describe "create_run/1" do
    test "creates a pending run" do
      agent_id = Ecto.UUID.generate()
      issue_id = Ecto.UUID.generate()

      insert_agent(agent_id)

      assert {:ok, run} =
               HeartbeatEngine.create_run(%{
                 agent_id: agent_id,
                 issue_id: issue_id,
                 adapter: "claude_local"
               })

      assert run.status == "pending"
      assert run.agent_id == agent_id
      assert run.issue_id == issue_id
    end
  end

  describe "start_run/1" do
    test "transitions pending run to running" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: Ecto.UUID.generate(),
          adapter: "claude_local"
        })

      assert {:ok, started} = HeartbeatEngine.start_run(run)
      assert started.status == "running"
      assert started.workspace_path
      assert started.started_at
    end

    test "rejects non-pending run" do
      run = %Run{status: "running", id: Ecto.UUID.generate()}
      assert {:error, {:invalid_status, "running"}} = HeartbeatEngine.start_run(run)
    end
  end

  describe "complete_run/2" do
    test "transitions running run to completed with cost data" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: Ecto.UUID.generate(),
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)

      attrs = %{
        input_tokens: 1000,
        output_tokens: 500,
        cost_usd: Decimal.new("0.010500")
      }

      assert {:ok, completed} = HeartbeatEngine.complete_run(started, attrs)
      assert completed.status == "completed"
      assert completed.input_tokens == 1000
      assert completed.output_tokens == 500
      assert completed.completed_at
    end
  end

  describe "fail_run/2" do
    test "transitions running run to failed with error reason" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: Ecto.UUID.generate(),
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)

      assert {:ok, failed} = HeartbeatEngine.fail_run(started, "stall_timeout")
      assert failed.status == "failed"
      assert failed.error_reason == "stall_timeout"
      assert failed.completed_at
    end
  end

  describe "cancel_run/1" do
    test "cancels a pending run" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: Ecto.UUID.generate(),
          adapter: "claude_local"
        })

      assert {:ok, cancelled} = HeartbeatEngine.cancel_run(run)
      assert cancelled.status == "cancelled"
    end

    test "broadcasts run_cancelled via PubSub" do
      company_id = Ecto.UUID.generate()
      issue_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()

      Cympho.Repo.insert!(%Cympho.Companies.Company{
        id: company_id,
        name: "Test Co",
        slug: "test-co-#{:rand.uniform(100_000)}"
      })

      Cympho.Repo.insert!(%Cympho.Issues.Issue{
        id: issue_id,
        title: "Test",
        company_id: company_id
      })

      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: issue_id,
          adapter: "claude_local"
        })

      Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:runs")

      assert {:ok, _cancelled} = HeartbeatEngine.cancel_run(run)

      assert_received {:run_status_changed,
                       %{
                         event_type: :run_cancelled,
                         new_status: "cancelled",
                         old_status: "pending"
                       }}
    end
  end

  describe "record_heartbeat/1" do
    test "updates last_heartbeat_at for running run" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: Ecto.UUID.generate(),
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)
      original_hb = started.last_heartbeat_at

      Process.sleep(10)

      assert {:ok, updated} = HeartbeatEngine.record_heartbeat(started)
      assert DateTime.compare(updated.last_heartbeat_at, original_hb) in [:gt, :eq]
    end
  end

  describe "get_active_run_for_agent/1" do
    test "returns the running run for an agent" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: Ecto.UUID.generate(),
          adapter: "claude_local"
        })

      {:ok, _started} = HeartbeatEngine.start_run(run)

      assert {:ok, active} = HeartbeatEngine.get_active_run_for_agent(agent_id)
      assert active.status == "running"
    end

    test "returns error when no active run" do
      assert {:error, :not_found} = HeartbeatEngine.get_active_run_for_agent(Ecto.UUID.generate())
    end
  end

  describe "find_stale_runs/1" do
    test "finds runs with old heartbeat timestamps" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: Ecto.UUID.generate(),
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)

      # Manually age the heartbeat
      stale_time = DateTime.add(DateTime.utc_now(), -30 * 60, :second)

      started
      |> Ecto.Changeset.change(%{last_heartbeat_at: stale_time})
      |> Cympho.Repo.update!()

      stale = HeartbeatEngine.find_stale_runs(15)
      assert length(stale) >= 1
      assert Enum.any?(stale, &(&1.id == started.id))
    end
  end

  describe "recover_stale_run/1" do
    test "marks stale run as failed" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: Ecto.UUID.generate(),
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)

      assert {:ok, recovered} = HeartbeatEngine.recover_stale_run(started)
      assert recovered.status == "failed"
      assert recovered.error_reason == "stale_run_recovered"
    end
  end

  defp insert_agent(agent_id) do
    Cympho.Repo.insert!(%Cympho.Agents.Agent{
      id: agent_id,
      name: "test-agent-#{:rand.uniform(10_000)}",
      role: :engineer,
      status: :idle
    })
  end
end
