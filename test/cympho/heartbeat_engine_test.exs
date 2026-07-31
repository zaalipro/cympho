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

    test "a nil issue id reaches the run changeset instead of the finance gate" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      assert {:error, %Ecto.Changeset{} = changeset} =
               HeartbeatEngine.create_run(%{
                 agent_id: agent_id,
                 issue_id: nil,
                 adapter: "claude_local"
               })

      assert "can't be blank" in errors_on(changeset).issue_id
    end

    test "rejects an agent and issue from different scoped companies without binding checkout" do
      first_company =
        Cympho.Repo.insert!(%Cympho.Companies.Company{
          name: "HB Agent Company #{System.unique_integer([:positive])}",
          slug: "hb-agent-company-#{System.unique_integer([:positive])}"
        })

      second_company =
        Cympho.Repo.insert!(%Cympho.Companies.Company{
          name: "HB Issue Company #{System.unique_integer([:positive])}",
          slug: "hb-issue-company-#{System.unique_integer([:positive])}"
        })

      agent =
        Cympho.Repo.insert!(%Cympho.Agents.Agent{
          name: "cross-company-run-agent",
          role: :engineer,
          status: :idle,
          company_id: first_company.id
        })

      issue =
        Cympho.Repo.insert!(%Cympho.Issues.Issue{
          title: "cross-company run issue",
          company_id: second_company.id
        })

      assert {:error, :company_mismatch} =
               HeartbeatEngine.create_run(%{
                 company_id: second_company.id,
                 agent_id: agent.id,
                 issue_id: issue.id,
                 adapter: "claude_local"
               })

      refute Cympho.Repo.exists?(
               from r in Run, where: r.agent_id == ^agent.id and r.issue_id == ^issue.id
             )
    end
  end

  describe "checkout run ownership" do
    test "binds the pending run to the checked-out issue before execution" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      issue = insert_checked_out_issue(agent_id)

      assert {:ok, run} =
               HeartbeatEngine.create_run(%{
                 agent_id: agent_id,
                 issue_id: issue.id,
                 adapter: "claude_local",
                 bind_checkout: true
               })

      reloaded = Cympho.Repo.get!(Cympho.Issues.Issue, issue.id)
      assert reloaded.checkout_run_id == run.id
      assert reloaded.status == :in_progress
      assert reloaded.assignee_id == agent_id
    end

    test "cancels a duplicate pending run when another run owns the checkout" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      issue = insert_checked_out_issue(agent_id)

      assert {:ok, owner_run} =
               HeartbeatEngine.create_run(%{
                 agent_id: agent_id,
                 issue_id: issue.id,
                 adapter: "claude_local",
                 bind_checkout: true
               })

      assert {:error, {:checkout_run_bind_failed, :checkout_run_conflict}} =
               HeartbeatEngine.create_run(%{
                 agent_id: agent_id,
                 issue_id: issue.id,
                 adapter: "claude_local",
                 bind_checkout: true
               })

      reloaded = Cympho.Repo.get!(Cympho.Issues.Issue, issue.id)
      assert reloaded.checkout_run_id == owner_run.id

      assert Enum.any?(
               HeartbeatEngine.list_runs_for_issue(issue.id),
               &(&1.id != owner_run.id and &1.status == "cancelled")
             )
    end

    test "a terminal old run cannot clear a successor run's checkout" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      issue = insert_checked_out_issue(agent_id)

      assert {:ok, old_run} =
               HeartbeatEngine.create_run(%{
                 agent_id: agent_id,
                 issue_id: issue.id,
                 adapter: "claude_local",
                 bind_checkout: true
               })

      assert {:ok, started_old_run} = HeartbeatEngine.start_run(old_run)

      assert {:ok, successor_run} =
               HeartbeatEngine.create_run(%{
                 agent_id: agent_id,
                 issue_id: issue.id,
                 adapter: "claude_local"
               })

      issue
      |> Cympho.Repo.reload!()
      |> Ecto.Changeset.change(checkout_run_id: successor_run.id)
      |> Cympho.Repo.update!()

      assert {:ok, _completed} = HeartbeatEngine.complete_run(started_old_run, %{})

      reloaded = Cympho.Repo.get!(Cympho.Issues.Issue, issue.id)
      assert reloaded.checkout_run_id == successor_run.id
      assert reloaded.status == :in_progress
      assert reloaded.checked_out_at
    end

    test "a terminal legacy run cannot clear a newer unbound checkout by the same agent" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      issue = insert_checked_out_issue(agent_id)

      assert {:ok, old_run} =
               HeartbeatEngine.create_run(%{
                 agent_id: agent_id,
                 issue_id: issue.id,
                 adapter: "claude_local"
               })

      assert {:ok, started_old_run} = HeartbeatEngine.start_run(old_run)
      assert {:ok, released} = Cympho.Issues.clear_checkout_lock(issue, :todo)
      assert {:ok, successor_checkout} = Cympho.Issues.checkout_issue(released, agent_id)
      assert is_nil(successor_checkout.checkout_run_id)
      assert successor_checkout.status == :in_progress
      assert successor_checkout.checked_out_at

      assert {:ok, _recovered} = HeartbeatEngine.recover_stale_run(started_old_run)

      reloaded = Cympho.Repo.get!(Cympho.Issues.Issue, issue.id)
      assert is_nil(reloaded.checkout_run_id)
      assert reloaded.status == :in_progress
      assert reloaded.checked_out_at == successor_checkout.checked_out_at
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

    test "provisions a configured issue repository before the run starts" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      {issue_id, repo_dir} = insert_repo_issue()
      path = Cympho.Workspace.workspace_path(issue_id)

      for dirname <- [".git", ".agents", ".codex"] do
        File.mkdir_p!(Path.join(path, dirname))
      end

      on_exit(fn ->
        File.rm_rf!(repo_dir)
        File.rm_rf!(path)
      end)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: issue_id,
          adapter: "claude_local"
        })

      assert {:ok, started} = HeartbeatEngine.start_run(run)
      assert started.workspace_path == path
      assert File.read!(Path.join(path, "README.md")) == "# Heartbeat repo\n"

      assert {"true\n", 0} =
               System.cmd("git", ["-C", path, "rev-parse", "--is-inside-work-tree"])
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

    test "clears a checked-out issue when its owning run completes without changing status" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      issue = insert_checked_out_issue(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: issue.id,
          adapter: "claude_local",
          bind_checkout: true
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

    test "records usage spent before the failure on the failed run" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: insert_issue(),
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)

      # A gate-rejected turn still burned real tokens — budgets must see it.
      assert {:ok, failed} =
               HeartbeatEngine.fail_run(started, {:agent_action_failed, :missing_action_block}, %{
                 input_tokens: 12_345,
                 output_tokens: 678,
                 cost_usd: Decimal.new("1.25")
               })

      assert failed.status == "failed"
      assert failed.input_tokens == 12_345
      assert failed.output_tokens == 678
      assert Decimal.eq?(failed.cost_usd, Decimal.new("1.25"))
    end

    test "clears a checked-out issue when its owning run fails" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      issue = insert_checked_out_issue(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: issue.id,
          adapter: "claude_local",
          bind_checkout: true
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

    test "clears a checked-out issue when its owning run is cancelled" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      issue = insert_checked_out_issue(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: issue.id,
          adapter: "claude_local",
          bind_checkout: true
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

      # Timestamps are second-precision, so the new heartbeat may land in the
      # same second — the assertion allows :eq, no sleep needed.
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

    test "clears a checked-out issue when stale owned run recovery fails it" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      issue = insert_checked_out_issue(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: issue.id,
          adapter: "claude_local",
          bind_checkout: true
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

  describe "terminal transition races" do
    test "recover_stale_run loses to a run that already completed" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: insert_issue(),
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)
      {:ok, _completed} = HeartbeatEngine.complete_run(started, %{})

      # Watchdog holds a stale struct that still says "running".
      assert {:error, {:invalid_status, "completed"}} =
               HeartbeatEngine.recover_stale_run(started)

      reloaded = Cympho.Repo.get!(Run, started.id)
      assert reloaded.status == "completed"
      assert is_nil(reloaded.error_reason)
    end

    test "complete_run loses to a run the watchdog already recovered" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: insert_issue(),
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)
      {:ok, _recovered} = HeartbeatEngine.recover_stale_run(started)

      assert {:error, {:invalid_status, "failed"}} =
               HeartbeatEngine.complete_run(started, %{cost_usd: Decimal.new("1.00")})

      reloaded = Cympho.Repo.get!(Run, started.id)
      assert reloaded.status == "failed"
      assert reloaded.error_reason == "stale_run_recovered"
    end

    test "cancel_run loses to a run that already completed" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: insert_issue(),
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)
      {:ok, _completed} = HeartbeatEngine.complete_run(started, %{})

      assert {:error, {:invalid_status, "completed"}} = HeartbeatEngine.cancel_run(started)
      assert Cympho.Repo.get!(Run, started.id).status == "completed"
    end

    test "record_heartbeat with a stale struct cannot re-touch a finished run" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: insert_issue(),
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)
      {:ok, recovered} = HeartbeatEngine.recover_stale_run(started)

      # Backdate the terminal run's liveness timestamp so an erroneous
      # re-touch (which would stamp "now") is detectable without sleeping
      # across a second boundary.
      backdated = DateTime.add(recovered.last_heartbeat_at, -60)

      {:ok, _} =
        Cympho.Repo.update(Ecto.Changeset.change(recovered, last_heartbeat_at: backdated))

      # Late heartbeat from the (dead) session must not move the terminal
      # run's liveness timestamp.
      assert {:ok, _} = HeartbeatEngine.record_heartbeat(started)

      reloaded = Cympho.Repo.get!(Run, started.id)
      assert reloaded.status == "failed"
      assert DateTime.compare(reloaded.last_heartbeat_at, backdated) == :eq
    end
  end

  describe "budget gate" do
    test "allows run creation when the active agent budget has headroom" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      insert_budget(agent_id, limit: "100.00", spent: "10.00")

      assert {:ok, _run} =
               HeartbeatEngine.create_run(%{
                 agent_id: agent_id,
                 issue_id: insert_issue(),
                 adapter: "claude_local"
               })
    end

    test "blocks run creation with an operator signal when the budget is exhausted" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      insert_budget(agent_id, limit: "10.00", spent: "9.50")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :budget_exhausted} =
                   HeartbeatEngine.create_run(%{
                     agent_id: agent_id,
                     issue_id: insert_issue(),
                     adapter: "claude_local"
                   })
        end)

      assert log =~ "budget exhausted"
    end
  end

  describe "count_stale_runs_for_company/2" do
    test "counts only stale running runs in the company" do
      agent_id = Ecto.UUID.generate()
      insert_agent(agent_id)
      issue_id = insert_issue()
      issue = Cympho.Repo.get!(Cympho.Issues.Issue, issue_id)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          company_id: issue.company_id,
          agent_id: agent_id,
          issue_id: issue_id,
          adapter: "claude_local"
        })

      {:ok, started} = HeartbeatEngine.start_run(run)

      assert HeartbeatEngine.count_stale_runs_for_company(issue.company_id, 15) == 0

      stale_time =
        DateTime.utc_now()
        |> DateTime.add(-30 * 60, :second)
        |> DateTime.truncate(:second)

      started
      |> Ecto.Changeset.change(%{last_heartbeat_at: stale_time})
      |> Cympho.Repo.update!()

      assert HeartbeatEngine.count_stale_runs_for_company(issue.company_id, 15) == 1
      assert HeartbeatEngine.count_stale_runs_for_company(Ecto.UUID.generate(), 15) == 0
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

  defp insert_budget(agent_id, opts) do
    Cympho.Repo.insert!(%Cympho.Budgets.Budget{
      name: "budget-#{:rand.uniform(10_000)}",
      scope_type: "agent",
      scope_id: agent_id,
      agent_id: agent_id,
      limit_amount: Decimal.new(Keyword.fetch!(opts, :limit)),
      spent_amount: Decimal.new(Keyword.fetch!(opts, :spent)),
      status: "active"
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

  defp insert_repo_issue do
    unique = System.unique_integer([:positive])
    repo_dir = Path.join(System.tmp_dir!(), "cympho_hb_repo_#{unique}")
    File.mkdir_p!(repo_dir)
    assert {_output, 0} = System.cmd("git", ["init", "--quiet"], cd: repo_dir)

    assert {_output, 0} =
             System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo_dir)

    assert {_output, 0} = System.cmd("git", ["config", "user.name", "Cympho Test"], cd: repo_dir)
    File.write!(Path.join(repo_dir, "README.md"), "# Heartbeat repo\n")
    assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: repo_dir)
    assert {_output, 0} = System.cmd("git", ["commit", "--quiet", "-m", "initial"], cd: repo_dir)

    company =
      Cympho.Repo.insert!(%Cympho.Companies.Company{
        name: "HB Repo Co #{unique}",
        slug: "hb-repo-co-#{unique}"
      })

    {:ok, project} =
      Cympho.Projects.create_project(%{
        company_id: company.id,
        name: "HB Repo Project #{unique}",
        prefix: "HBR",
        settings: %{"repo_url" => repo_dir}
      })

    issue =
      Cympho.Repo.insert!(%Cympho.Issues.Issue{
        title: "heartbeat repo issue #{unique}",
        identifier: "HBR-#{unique}",
        company_id: company.id,
        project_id: project.id
      })

    {issue.id, repo_dir}
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
