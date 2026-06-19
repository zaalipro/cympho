defmodule Cympho.HeartbeatEngineTest do
  use Cympho.DataCase, async: true

  alias Cympho.HeartbeatEngine
  alias Cympho.HeartbeatEngine.Run

  describe "create_run/1" do
    test "creates a pending run" do
      agent_id = Ecto.UUID.generate()
      issue_id = insert_issue()

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
          issue_id: insert_issue(),
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
          issue_id: insert_issue(),
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

    test "clears a checked-out issue when a run completes without changing status" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      issue = insert_checked_out_issue(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: issue.id,
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)

      assert {:ok, completed} = HeartbeatEngine.complete_run(started, %{})
      assert completed.status == "completed"

      reloaded = Cympho.Repo.get!(Cympho.Issues.Issue, issue.id)
      assert reloaded.status == :todo
      assert reloaded.assignee_id == agent_id
      assert is_nil(reloaded.checkout_run_id)
      assert is_nil(reloaded.checked_out_at)
    end
  end

  describe "fail_run/2" do
    test "transitions running run to failed with error reason" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: insert_issue(),
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)

      assert {:ok, failed} = HeartbeatEngine.fail_run(started, :stall_timeout)
      assert failed.status == "failed"
      assert failed.error_reason == "Run timed out"
      assert failed.run_metadata["adapter_error"]["category"] == "timeout"
      assert failed.completed_at
    end

    test "clears a checked-out issue when a run fails" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      issue = insert_checked_out_issue(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: issue.id,
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)

      assert {:ok, failed} = HeartbeatEngine.fail_run(started, :stall_timeout)
      assert failed.status == "failed"

      reloaded = Cympho.Repo.get!(Cympho.Issues.Issue, issue.id)
      assert reloaded.status == :todo
      assert reloaded.assignee_id == agent_id
      assert is_nil(reloaded.checked_out_at)
    end

    test "stores normalized adapter error metadata" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: insert_issue(),
          adapter: "codex"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)

      assert {:ok, failed} =
               HeartbeatEngine.fail_run(started, {:exit_code, 7, "provider failed"})

      assert failed.error_reason == "Runtime exited with an error"
      assert failed.log_excerpt == "provider failed"
      assert failed.run_metadata["adapter_error"]["category"] == "nonzero_exit"
      assert failed.run_metadata["adapter_error"]["message"] =~ "status 7"
    end
  end

  describe "cancel_run/1" do
    test "cancels a pending run" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: insert_issue(),
          adapter: "claude_local"
        })

      assert {:ok, cancelled} = HeartbeatEngine.cancel_run(run)
      assert cancelled.status == "cancelled"
    end

    test "clears a checked-out issue when a run is cancelled" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      issue = insert_checked_out_issue(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: issue.id,
          adapter: "claude_local"
        })

      assert {:ok, cancelled} = HeartbeatEngine.cancel_run(run)
      assert cancelled.status == "cancelled"

      reloaded = Cympho.Repo.get!(Cympho.Issues.Issue, issue.id)
      assert reloaded.status == :todo
      assert reloaded.assignee_id == agent_id
      assert is_nil(reloaded.checked_out_at)
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

      assert_received %Phoenix.Socket.Broadcast{
        event: "run_status",
        payload: %{event_type: :run_cancelled, status: "cancelled"}
      }
    end
  end

  describe "record_heartbeat/1" do
    test "updates last_heartbeat_at for running run" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: insert_issue(),
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
          issue_id: insert_issue(),
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
          issue_id: insert_issue(),
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)

      # Manually age the heartbeat
      stale_time =
        DateTime.utc_now()
        |> DateTime.add(-30 * 60, :second)
        |> DateTime.truncate(:second)

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
          issue_id: insert_issue(),
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)

      assert {:ok, recovered} = HeartbeatEngine.recover_stale_run(started)
      assert recovered.status == "failed"
      assert recovered.error_reason == "stale_run_recovered"
    end

    test "clears a checked-out issue when stale run recovery fails it" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      issue = insert_checked_out_issue(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: issue.id,
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)

      assert {:ok, recovered} = HeartbeatEngine.recover_stale_run(started)
      assert recovered.status == "failed"

      reloaded = Cympho.Repo.get!(Cympho.Issues.Issue, issue.id)
      assert reloaded.status == :todo
      assert reloaded.assignee_id == agent_id
      assert is_nil(reloaded.checked_out_at)
    end
  end

  describe "list_runs_for_issue/2" do
    test "bounds issue run history by default and exposes total count" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      issue_id = insert_issue()
      issue = Cympho.Repo.get!(Cympho.Issues.Issue, issue_id)
      base_time = ~U[2026-01-01 00:00:00Z]

      for index <- 1..55 do
        timestamp = DateTime.add(base_time, index, :second)

        Cympho.Repo.insert!(%Run{
          agent_id: agent_id,
          issue_id: issue_id,
          company_id: issue.company_id,
          status: "completed",
          adapter: "adapter-#{index}",
          inserted_at: timestamp,
          updated_at: timestamp
        })
      end

      runs = HeartbeatEngine.list_runs_for_issue(issue_id)

      assert length(runs) == HeartbeatEngine.issue_run_history_limit()
      assert hd(runs).adapter == "adapter-55"
      refute Enum.any?(runs, &(&1.adapter == "adapter-1"))
      assert HeartbeatEngine.count_runs_for_issue(issue_id) == 55

      assert [%Run{adapter: "adapter-54"}, %Run{adapter: "adapter-53"}] =
               HeartbeatEngine.list_runs_for_issue(issue_id, limit: 2, offset: 1)
    end
  end

  describe "orphaned run recovery" do
    test "finds pending runs with no live orchestrator" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: insert_issue(),
          adapter: "claude_local"
        })

      assert Enum.any?(HeartbeatEngine.find_orphaned_runs(), &(&1.id == run.id))
    end

    test "cancels orphaned runs that never started" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: insert_issue(),
          adapter: "claude_local"
        })

      assert {:ok, recovered} = HeartbeatEngine.recover_orphaned_run(run)
      assert recovered.status == "cancelled"
      assert is_nil(recovered.error_reason)
    end

    test "fails orphaned running runs" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: insert_issue(),
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)

      assert {:ok, recovered} = HeartbeatEngine.recover_orphaned_run(started)
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

  defp insert_issue do
    company_id = Ecto.UUID.generate()

    Cympho.Repo.insert!(%Cympho.Companies.Company{
      id: company_id,
      name: "HB Co #{:rand.uniform(100_000)}",
      slug: "hb-co-#{:rand.uniform(1_000_000)}"
    })

    issue =
      Cympho.Repo.insert!(%Cympho.Issues.Issue{
        title: "test issue #{:rand.uniform(100_000)}",
        company_id: company_id
      })

    issue.id
  end

  defp insert_checked_out_issue(agent_id) do
    company_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Cympho.Repo.insert!(%Cympho.Companies.Company{
      id: company_id,
      name: "HB Checked Out Co #{:rand.uniform(100_000)}",
      slug: "hb-checked-out-co-#{:rand.uniform(1_000_000)}"
    })

    Cympho.Repo.insert!(%Cympho.Issues.Issue{
      title: "checked out issue #{:rand.uniform(100_000)}",
      company_id: company_id,
      status: :in_progress,
      assignee_id: agent_id,
      checked_out_at: now
    })
  end
end
