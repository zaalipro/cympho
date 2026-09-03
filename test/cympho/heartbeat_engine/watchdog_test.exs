defmodule Cympho.HeartbeatEngine.WatchdogTest do
  # async: false so we can grant the global watchdog process access to our
  # sandbox connection without contention with other tests.
  use Cympho.DataCase, async: false

  alias Cympho.Agents
  alias Cympho.HeartbeatEngine
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.HeartbeatEngine.Watchdog
  alias Cympho.Issues
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Recovery.RecoveryAttempt
  alias Cympho.Recovery.RecoveryCase

  setup do
    pid =
      case start_supervised(Cympho.HeartbeatEngine.Watchdog) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, self(), pid)
    :ok
  end

  describe "start_link/1" do
    test "starts the watchdog process" do
      assert Process.whereis(Cympho.HeartbeatEngine.Watchdog)
    end
  end

  describe "last_results/0" do
    test "returns initial empty results" do
      results = Watchdog.last_results()
      assert is_map(results)
    end
  end

  describe "check_now/0" do
    test "triggers a check without error" do
      assert :ok = Watchdog.check_now()
      # Sync through the GenServer so the check_now cast has been processed.
      _ = :sys.get_state(Process.whereis(Watchdog))
    end

    test "skips never-started orphaned runs without a company scope" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Watchdog Orphan Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Watchdog orphan run",
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent.id,
          issue_id: issue.id,
          adapter: "process"
        })

      old = DateTime.utc_now() |> DateTime.add(-16 * 60, :second) |> DateTime.truncate(:second)
      run |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()

      assert :ok = Watchdog.check_now()
      # Sync through the GenServer so the check_now cast has been processed.
      _ = :sys.get_state(Process.whereis(Watchdog))

      reloaded = Repo.get!(Run, run.id)
      assert reloaded.status == "pending"
      assert is_nil(reloaded.error_reason)
    end

    test "counts durable checkout recovery once across Watchdog and Dispatcher" do
      {:ok, company} =
        Cympho.Companies.create_company(%{
          name: "Watchdog Checkout Co #{System.unique_integer([:positive])}",
          slug: "wd-checkout-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Watchdog Checkout Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Watchdog durable checkout",
          status: :todo,
          assignee_id: agent.id,
          company_id: company.id
        })

      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      old = DateTime.utc_now() |> DateTime.add(-16 * 60, :second) |> DateTime.truncate(:second)
      checked_out |> Ecto.Changeset.change(checked_out_at: old) |> Repo.update!()

      assert :ok = Watchdog.check_now()
      _ = :sys.get_state(Process.whereis(Watchdog))

      results = Watchdog.last_results()
      assert results.recovery_cases_created == 1
      assert results.recovery_attempts == 1
      assert results.orphaned_issues_recovered >= 1

      recovery_case =
        Repo.one!(
          Ecto.Query.from(c in RecoveryCase,
            where: c.source_type == "issue_checkout" and c.source_id == ^issue.id
          )
        )

      assert Repo.aggregate(
               Ecto.Query.from(a in RecoveryAttempt,
                 where: a.recovery_case_id == ^recovery_case.id
               ),
               :count
             ) == 1

      # A duplicate dispatcher sweep sees no stale source and cannot claim a
      # second attempt or mutate the recovered checkout.
      _ = Dispatcher.recover_orphaned_in_progress()
      _ = Dispatcher.recover_stale_checkouts()

      assert Repo.aggregate(
               Ecto.Query.from(a in RecoveryAttempt,
                 where: a.recovery_case_id == ^recovery_case.id
               ),
               :count
             ) == 1
    end

    test "skips stale runs whose company does not match the issue" do
      {:ok, issue_company} =
        Cympho.Companies.create_company(%{
          name: "Watchdog Issue Scope Co #{System.unique_integer([:positive])}",
          slug: "wd-issue-scope-#{System.unique_integer([:positive])}"
        })

      {:ok, run_company} =
        Cympho.Companies.create_company(%{
          name: "Watchdog Run Scope Co #{System.unique_integer([:positive])}",
          slug: "wd-run-scope-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Watchdog Scope Agent",
          role: :engineer,
          status: :idle,
          company_id: issue_company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Watchdog mismatched stale run",
          status: :todo,
          assignee_id: agent.id,
          company_id: issue_company.id
        })

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          company_id: issue_company.id,
          agent_id: agent.id,
          issue_id: issue.id,
          adapter: "process"
        })

      # Simulate a corrupted cross-tenant source row at rest; create_run/1
      # correctly rejects this combination at the API boundary.
      run = run |> Ecto.Changeset.change(company_id: run_company.id) |> Repo.update!()

      old = DateTime.utc_now() |> DateTime.add(-16 * 60, :second) |> DateTime.truncate(:second)
      run |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()

      assert :ok = Watchdog.check_now()
      _ = :sys.get_state(Process.whereis(Watchdog))

      assert Repo.get!(Run, run.id).status == "pending"

      refute Repo.exists?(
               Ecto.Query.from(c in RecoveryCase,
                 where: c.source_type == "heartbeat_run" and c.source_id == ^run.id
               )
             )
    end

    test "counts run and unbound-checkout recovery cases and attempts" do
      {:ok, company} =
        Cympho.Companies.create_company(%{
          name: "Watchdog Recovery Co #{System.unique_integer([:positive])}",
          slug: "wd-recovery-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Watchdog Recovery Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Watchdog durable stale run",
          status: :todo,
          assignee_id: agent.id,
          company_id: company.id
        })

      {:ok, checked_out} = Issues.checkout_issue(issue, agent)

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          company_id: company.id,
          agent_id: agent.id,
          issue_id: checked_out.id,
          adapter: "process"
        })

      old = DateTime.utc_now() |> DateTime.add(-16 * 60, :second) |> DateTime.truncate(:second)
      run |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()

      assert :ok = Watchdog.check_now()
      _ = :sys.get_state(Process.whereis(Watchdog))

      results = Watchdog.last_results()
      assert results.recovery_cases_created == 2
      assert results.recovery_attempts == 2
      assert results.recovery_exhausted == 0

      recovery_case =
        Repo.one!(
          Ecto.Query.from(c in RecoveryCase,
            where: c.source_type == "heartbeat_run" and c.source_id == ^run.id
          )
        )

      assert recovery_case.state == "recovered"

      assert Repo.aggregate(
               Ecto.Query.from(a in RecoveryAttempt,
                 where: a.recovery_case_id == ^recovery_case.id
               ),
               :count
             ) == 1

      checkout_case =
        Repo.one!(
          Ecto.Query.from(c in RecoveryCase,
            where: c.source_type == "issue_checkout" and c.source_id == ^issue.id
          )
        )

      assert checkout_case.state == "recovered"
      assert Repo.get!(Cympho.Issues.Issue, issue.id).status == :todo

      # The dispatcher scanner sees the same source after Watchdog has
      # terminalized it; durable source CAS prevents a duplicate attempt.
      _ = Dispatcher.recover_orphaned_in_progress()
      _ = Dispatcher.recover_stale_checkouts()

      assert Repo.aggregate(
               Ecto.Query.from(a in RecoveryAttempt,
                 where: a.recovery_case_id == ^recovery_case.id
               ),
               :count
             ) == 1
    end

    test "reclaims orphaned :in_progress issues and records results" do
      # Fail-closed same_company? requires a shared non-nil company_id for checkout.
      {:ok, company} =
        Cympho.Companies.create_company(%{
          name: "Watchdog Orphan Co #{System.unique_integer([:positive])}",
          slug: "wd-orphan-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Watchdog Issue Orphan Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Watchdog orphaned in_progress",
          status: :todo,
          assignee_id: agent.id,
          company_id: company.id
        })

      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert checked_out.status == :in_progress
      assert is_nil(Cympho.Orchestrator.whereis(checked_out.id))

      old = DateTime.utc_now() |> DateTime.add(-16 * 60, :second) |> DateTime.truncate(:second)
      checked_out |> Ecto.Changeset.change(checked_out_at: old) |> Repo.update!()

      assert :ok = Watchdog.check_now()
      _ = :sys.get_state(Process.whereis(Watchdog))

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :todo
      assert reloaded.assignee_id == agent.id

      results = Watchdog.last_results()
      assert results.orphaned_issues_recovered >= 1
    end
  end

  describe "stranded wake recovery" do
    test "reclaims an expired running wake claim and re-triggers its agent" do
      case start_supervised({Registry, keys: :unique, name: Cympho.AgentHeartbeat.Registry}) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Expired Wake Claim Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Expired running wake",
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, _wake} =
        Cympho.HeartbeatEngine.WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: "issue_commented"
        })

      {:ok, claimed} = Cympho.HeartbeatEngine.WakeupQueue.dequeue(agent.id)

      claimed
      |> Ecto.Changeset.change(%{
        claimed_at: DateTime.add(DateTime.utc_now(), -60 * 60, :second)
      })
      |> Repo.update!()

      {:ok, _} = Registry.register(Cympho.AgentHeartbeat.Registry, agent.id, nil)

      assert :ok = Watchdog.check_now()
      _ = :sys.get_state(Process.whereis(Watchdog))

      assert_receive :heartbeat, 2_000

      reloaded = Repo.get!(Cympho.Wakes.AgentWake, claimed.id)
      assert reloaded.status == "pending"
      assert is_nil(reloaded.claim_token)
      assert Watchdog.last_results().stale_wake_claims_recovered >= 1
    end

    test "re-triggers heartbeats for agents with old pending wakes" do
      case start_supervised({Registry, keys: :unique, name: Cympho.AgentHeartbeat.Registry}) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Stranded Wake Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Stranded wake issue",
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, wake} =
        Cympho.HeartbeatEngine.WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: "issue_commented"
        })

      # Age the wake past the stale threshold — the enqueue broadcast went
      # nowhere because no heartbeat process exists.
      old_time =
        DateTime.utc_now()
        |> DateTime.add(-60 * 60, :second)
        |> DateTime.truncate(:second)

      wake
      |> Ecto.Changeset.change(%{inserted_at: old_time})
      |> Repo.update!()

      # Register self() as the agent's heartbeat process so the watchdog's
      # re-trigger lands here.
      {:ok, _} = Registry.register(Cympho.AgentHeartbeat.Registry, agent.id, nil)

      assert :ok = Watchdog.check_now()

      assert_receive :heartbeat, 2_000
    end

    test "skips paused agents when sweeping stranded wakes" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Paused Stranded Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Paused stranded issue",
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, wake} =
        Cympho.HeartbeatEngine.WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: "issue_commented"
        })

      old_time =
        DateTime.utc_now()
        |> DateTime.add(-60 * 60, :second)
        |> DateTime.truncate(:second)

      wake
      |> Ecto.Changeset.change(%{inserted_at: old_time})
      |> Repo.update!()

      {:ok, _paused} = Agents.pause_agent(agent.id, "operator pause")

      assert Cympho.HeartbeatEngine.WakeupQueue.agent_ids_with_stale_pending(15) == []
    end
  end

  describe "crash resilience" do
    test "a check that raises does not kill the watchdog" do
      pid = Process.whereis(Cympho.HeartbeatEngine.Watchdog)
      assert is_pid(pid)

      # Revoke the watchdog's sandbox access so its DB queries raise, then
      # trigger a check — the rescue in do_check must keep it alive.
      Ecto.Adapters.SQL.Sandbox.mode(Cympho.Repo, :manual)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Watchdog.check_now()
          # Sync through the GenServer to ensure the cast was processed.
          _ = :sys.get_state(pid)
        end)

      Ecto.Adapters.SQL.Sandbox.mode(Cympho.Repo, {:shared, self()})

      assert Process.alive?(pid)
      assert log =~ "check failed"
    end
  end

  describe "unexpected messages" do
    test "catch-all handle_info and handle_cast keep the watchdog alive" do
      pid = Process.whereis(Cympho.HeartbeatEngine.Watchdog)
      assert is_pid(pid)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(pid, :random_garbage_msg)
          GenServer.cast(pid, :random_garbage_cast)
          # Sync through the GenServer so both messages have been processed.
          _ = :sys.get_state(pid)
        end)

      assert Process.alive?(pid)
      assert log =~ "unexpected message"
      assert log =~ "unexpected cast"
      assert log =~ "random_garbage_msg"
      assert log =~ "random_garbage_cast"
    end
  end
end
