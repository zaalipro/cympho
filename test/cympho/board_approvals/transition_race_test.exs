defmodule Cympho.BoardApprovals.TransitionRaceTest do
  use Cympho.DataCase, async: false

  alias Cympho.BoardApprovals
  alias Cympho.BoardApprovals.{BoardApproval, BoardApprovalVote}
  alias Cympho.Companies
  alias Cympho.Decisions.Decision
  alias Cympho.Issues.Issue
  alias Cympho.Recovery
  alias Cympho.Recovery.RecoveryCase

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Board transition race #{unique}",
        slug: "board-transition-race-#{unique}",
        governance_config: %{"threshold_type" => "count", "threshold_value" => 1}
      })

    {:ok, approval} =
      BoardApprovals.create_board_approval(%{
        title: "Choose one terminal state",
        category: "other",
        company_id: company.id
      })

    %{approval: approval, company: company, user_id: Ecto.UUID.generate()}
  end

  test "concurrent approve, deny, and cancel commit exactly one terminal transition", %{
    approval: approval,
    user_id: user_id
  } do
    results =
      race([
        fn ->
          BoardApprovals.resolve_board_approval(
            approval.id,
            "approved",
            %{decision_reasoning: "approve won"},
            {"user", user_id}
          )
        end,
        fn ->
          BoardApprovals.resolve_board_approval(
            approval.id,
            "denied",
            %{decision_reasoning: "deny won"},
            {"user", user_id}
          )
        end,
        fn -> BoardApprovals.cancel_board_approval(approval.id, {"user", user_id}) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_pending})) == 2
    status = Repo.get!(BoardApproval, approval.id).status
    assert status in ~w(approved denied cancelled)

    decision_count =
      Repo.aggregate(
        from(d in Decision,
          where: d.resource_type == "board_approval" and d.resource_id == ^approval.id
        ),
        :count
      )

    assert decision_count == if(status == "cancelled", do: 0, else: 1)
  end

  test "vote auto-resolution cannot cross a concurrent manual denial", %{
    approval: approval,
    user_id: user_id
  } do
    [vote_result, denial_result] =
      race([
        fn -> BoardApprovals.cast_vote(approval.id, user_id, "approve") end,
        fn ->
          BoardApprovals.resolve_board_approval(
            approval.id,
            "denied",
            %{decision_reasoning: "manual denial"},
            {"user", user_id}
          )
        end
      ])

    reloaded = Repo.get!(BoardApproval, approval.id)

    votes =
      Repo.all(from vote in BoardApprovalVote, where: vote.board_approval_id == ^approval.id)

    case reloaded.status do
      "approved" ->
        assert match?({:ok, _}, vote_result)
        assert denial_result == {:error, :not_pending}
        assert length(votes) == 1

      "denied" ->
        assert vote_result == {:error, :not_pending}
        assert match?({:ok, _}, denial_result)
        assert votes == []
    end

    assert Repo.aggregate(
             from(d in Decision,
               where: d.resource_type == "board_approval" and d.resource_id == ^approval.id
             ),
             :count
           ) == 1
  end

  test "concurrent denial and cancellation resolve a linked recovery case once", %{
    company: company,
    user_id: user_id
  } do
    issue =
      %Issue{}
      |> Issue.changeset(%{
        title: "Recovery transition race",
        company_id: company.id,
        status: :in_progress
      })
      |> Repo.insert!()

    {:ok, case_row} =
      Recovery.ensure_case(%{
        company_id: company.id,
        source_type: "issue_checkout",
        issue: issue,
        max_attempts: 1
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, lease} = Recovery.claim_case(case_row, now: now)
    {:ok, exhausted} = Recovery.record_failure(lease, "provider timeout", now: now)
    {:ok, approval} = Recovery.exhaust_case(exhausted, now: now)

    results =
      race([
        fn ->
          BoardApprovals.resolve_board_approval(
            approval.id,
            "denied",
            %{decision_reasoning: "deny won"},
            {"user", user_id}
          )
        end,
        fn -> BoardApprovals.cancel_board_approval(approval.id, {"user", user_id}) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_pending})) == 1
    assert Repo.get!(BoardApproval, approval.id).status in ~w(denied cancelled)
    assert Repo.get!(RecoveryCase, case_row.id).state == "resolved"
    assert Repo.get!(Issue, issue.id).status == :blocked
  end

  defp race(functions) do
    parent = self()

    tasks =
      Enum.map(functions, fn function ->
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, parent, self())
          send(parent, {:ready, self()})

          receive do
            :go -> function.()
          end
        end)
      end)

    task_pids = Enum.map(tasks, & &1.pid)
    Enum.each(task_pids, fn pid -> assert_receive {:ready, ^pid} end)
    Enum.each(task_pids, &send(&1, :go))
    Enum.map(tasks, &Task.await(&1, 30_000))
  end
end

defmodule Cympho.BoardApprovals.RecoveryLockOrderTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cympho.AuditTrail.AuditEvent
  alias Cympho.Activities.Activity
  alias Cympho.Agents.Agent
  alias Cympho.BoardApprovals
  alias Cympho.BoardApprovals.{BoardApproval, BoardApprovalEffect}
  alias Cympho.Companies.Company
  alias Cympho.Decisions.Decision
  alias Cympho.GovernanceAuditLogs.GovernanceAuditLog
  alias Cympho.HeartbeatEngine
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue
  alias Cympho.Recovery
  alias Cympho.Recovery.{Fingerprint, RecoveryAttempt, RecoveryCase}
  alias Cympho.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    :ok
  end

  test "exhaustion and denial use one case-first lock order without deadlocking" do
    assert_exhaustion_terminal_race(:denied)
  end

  test "exhaustion and cancellation use one case-first lock order without deadlocking" do
    assert_exhaustion_terminal_race(:cancelled)
  end

  test "final recovery retains the issue lock before waiting for the run lock" do
    fixture = heartbeat_recovery_fixture!("final-issue-before-run")
    on_exit(fn -> cleanup_company(fixture.company.id) end)

    result =
      assert_issue_locked_before_waiting_for_run(fixture, fn ->
        HeartbeatEngine.recover_run_if_current(
          fixture.run,
          run_guard(fixture.case_row, :stale),
          :stale,
          now: fixture.now
        )
      end)

    assert {:ok, %Run{status: "failed"}} = result
  end

  test "terminal run cancellation retains the issue lock before waiting for the run lock" do
    fixture = heartbeat_recovery_fixture!("terminal-issue-before-run", run_status: "pending")
    on_exit(fn -> cleanup_company(fixture.company.id) end)

    result =
      assert_issue_locked_before_waiting_for_run(fixture, fn ->
        HeartbeatEngine.cancel_run(fixture.run)
      end)

    assert {:ok, %Run{status: "cancelled"}} = result
  end

  test "heartbeat case insertion explicitly prelocks issue before its exact run" do
    fixture = heartbeat_recovery_fixture!("case-insert-issue-before-run")
    Repo.delete!(fixture.case_row)
    on_exit(fn -> cleanup_company(fixture.company.id) end)

    result =
      assert_issue_locked_before_waiting_for_run(
        fixture,
        fn ->
          Recovery.ensure_case(%{
            source_type: "heartbeat_run",
            issue: fixture.issue,
            run: fixture.run
          })
        end,
        "FOR NO KEY UPDATE"
      )

    assert {:ok, %RecoveryCase{source_run_id: run_id}} = result
    assert run_id == fixture.run.id
  end

  test "run-backed exhaustion retains the exact run lock while validating its source" do
    fixture = heartbeat_recovery_fixture!("exhaustion-run-lock")
    on_exit(fn -> cleanup_company(fixture.company.id) end)

    assert {:ok, %BoardApproval{}} =
             assert_action_retains_run_lock(fixture.run, fn ->
               Recovery.exhaust_case(fixture.case_row, now: fixture.now)
             end)
  end

  test "approved retry retains the exact run lock while validating and creating its child" do
    fixture = heartbeat_recovery_fixture!("retry-run-lock")
    {:ok, approval} = Recovery.exhaust_case(fixture.case_row, now: fixture.now)

    Repo.update_all(from(a in BoardApproval, where: a.id == ^approval.id),
      set: [status: "approved"]
    )

    approval = Repo.get!(BoardApproval, approval.id)
    on_exit(fn -> cleanup_company(fixture.company.id) end)

    assert {:ok, %RecoveryCase{parent_case_id: parent_id}} =
             assert_action_retains_run_lock(fixture.run, fn ->
               Recovery.apply_board_action(approval, defer_side_effects: true, now: fixture.now)
             end)

    assert parent_id == fixture.case_row.id
  end

  test "heartbeat committed before source locking makes exhaustion lose without an approval" do
    fixture = heartbeat_recovery_fixture!("heartbeat-before-exhaustion")
    on_exit(fn -> cleanup_company(fixture.company.id) end)

    assert {:ok, %RecoveryCase{state: "superseded"}} =
             run_after_committed_heartbeat(fixture, fn ->
               Recovery.exhaust_case(fixture.case_row, now: fixture.now)
             end)

    refute Repo.get_by(BoardApproval, recovery_case_id: fixture.case_row.id)
    assert Repo.get!(Issue, fixture.issue.id).status == :in_progress
  end

  test "heartbeat committed before source locking makes approved retry lose without a child" do
    fixture = heartbeat_recovery_fixture!("heartbeat-before-retry")
    {:ok, approval} = Recovery.exhaust_case(fixture.case_row, now: fixture.now)

    Repo.update_all(from(a in BoardApproval, where: a.id == ^approval.id),
      set: [status: "approved"]
    )

    approval = Repo.get!(BoardApproval, approval.id)
    on_exit(fn -> cleanup_company(fixture.company.id) end)

    assert {:error, :stale_recovery_proposal} =
             run_after_committed_heartbeat(fixture, fn ->
               Recovery.apply_board_action(approval, defer_side_effects: true, now: fixture.now)
             end)

    assert Repo.get!(RecoveryCase, fixture.case_row.id).state == "escalated"
    assert Repo.get!(Issue, fixture.issue.id).status == :blocked
    refute Repo.exists?(from(c in RecoveryCase, where: c.parent_case_id == ^fixture.case_row.id))
  end

  test "heartbeat committed before source locking makes final recovery defer or supersede" do
    fixture = heartbeat_recovery_fixture!("heartbeat-before-final")
    on_exit(fn -> cleanup_company(fixture.company.id) end)

    assert {:error, reason} =
             run_after_committed_heartbeat(fixture, fn ->
               HeartbeatEngine.recover_run_if_current(
                 fixture.run,
                 run_guard(fixture.case_row, :stale),
                 :stale,
                 now: fixture.now
               )
             end)

    assert reason in [:superseded, :recovery_deferred]
    assert Repo.get!(Run, fixture.run.id).status == "running"
  end

  test "a queued conditional heartbeat cannot touch a run after recovery owns its lock" do
    fixture = heartbeat_recovery_fixture!("recovery-before-heartbeat")
    on_exit(fn -> cleanup_company(fixture.company.id) end)
    parent = self()

    {recovery_worker, recovery_ref} =
      spawn_monitor(fn ->
        result =
          with_unboxed_connection(fn ->
            announce_backend(parent)
            send(parent, {:recovery_query_worker_ready, self()})

            receive do
              :run_recovery_query ->
                capture_result(fn ->
                  HeartbeatEngine.recover_run_if_current(
                    fixture.run,
                    run_guard(fixture.case_row, :stale),
                    :stale,
                    now: fixture.now
                  )
                end)
            after
              10_000 -> {:error, :recovery_query_wait_timeout}
            end
          end)

        send(parent, {:recovery_result, self(), result})
      end)

    assert_receive {:recovery_query_worker_ready, ^recovery_worker}, 5_000
    handler_id = "run-lock-heartbeat-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:cympho, :repo, :query],
        fn _event, _measurements, metadata, {parent, recovery_worker} ->
          if self() == recovery_worker and
               String.contains?(metadata.query, ~s(FROM "heartbeat_runs")) and
               String.contains?(metadata.query, "FOR UPDATE") do
            send(parent, {:run_lock_retained, self()})

            receive do
              :release_run_query -> :ok
            after
              10_000 -> :ok
            end
          end
        end,
        {parent, recovery_worker}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(recovery_worker, :run_recovery_query)

    assert_receive {:run_lock_retained, ^recovery_worker}, 5_000
    :ok = :telemetry.detach(handler_id)

    {heartbeat_worker, heartbeat_ref} =
      spawn_monitored_result(:heartbeat_result, fn ->
        HeartbeatEngine.record_heartbeat(fixture.run)
      end)

    assert :ok = await_process_blocked_by(heartbeat_worker, recovery_worker, 5_000)
    send(recovery_worker, :release_run_query)

    assert_receive {:recovery_result, ^recovery_worker, {:ok, %Run{status: "failed"}}}, 10_000
    assert_receive {:heartbeat_result, ^heartbeat_worker, {:ok, %Run{}}}, 10_000
    assert_receive {:DOWN, ^recovery_ref, :process, ^recovery_worker, :normal}, 5_000
    assert_receive {:DOWN, ^heartbeat_ref, :process, ^heartbeat_worker, :normal}, 5_000
    assert Repo.get!(Run, fixture.run.id).status == "failed"
  end

  test "final recovery and an issue-first terminal transition complete without a deadlock" do
    fixture = heartbeat_recovery_fixture!("recovery-terminal-race")
    on_exit(fn -> cleanup_company(fixture.company.id) end)
    parent = self()

    {terminal_worker, terminal_ref} =
      spawn_monitor(fn ->
        result =
          capture_result(fn ->
            with_unboxed_connection(fn ->
              announce_backend(parent)

              Repo.transaction(fn ->
                Repo.one!(from(i in Issue, where: i.id == ^fixture.issue.id, lock: "FOR UPDATE"))
                send(parent, {:terminal_issue_locked, self()})

                receive do
                  :continue_terminal -> HeartbeatEngine.cancel_run(fixture.run)
                after
                  10_000 -> Repo.rollback(:terminal_wait_timeout)
                end
              end)
            end)
          end)

        send(parent, {:terminal_run_result, self(), result})
      end)

    assert_receive {:terminal_issue_locked, ^terminal_worker}, 5_000

    {recovery_worker, recovery_ref} =
      spawn_monitored_result(:deadlock_recovery_result, fn ->
        HeartbeatEngine.recover_run_if_current(
          fixture.run,
          run_guard(fixture.case_row, :stale),
          :stale,
          now: fixture.now
        )
      end)

    assert :ok = await_process_blocked_by(recovery_worker, terminal_worker, 5_000)
    send(terminal_worker, :continue_terminal)

    assert_receive {:terminal_run_result, ^terminal_worker, terminal_result}, 10_000
    assert_receive {:deadlock_recovery_result, ^recovery_worker, recovery_result}, 10_000
    assert_receive {:DOWN, ^terminal_ref, :process, ^terminal_worker, :normal}, 5_000
    assert_receive {:DOWN, ^recovery_ref, :process, ^recovery_worker, :normal}, 5_000

    assert {:ok, {:ok, %Run{status: "cancelled"}}} = terminal_result
    assert recovery_result == {:error, :superseded}
    refute postgres_deadlock?(terminal_result)
    refute postgres_deadlock?(recovery_result)
  end

  test "recovery board execution waits on the case before retaining the approval" do
    fixture = heartbeat_recovery_fixture!("board-effect-case-first")
    {:ok, approval} = Recovery.exhaust_case(fixture.case_row, now: fixture.now)

    Repo.update_all(from(a in BoardApproval, where: a.id == ^approval.id),
      set: [status: "approved"]
    )

    approval = Repo.get!(BoardApproval, approval.id)
    on_exit(fn -> cleanup_company(fixture.company.id) end)
    parent = self()

    {case_locker, case_locker_ref} =
      spawn_monitor(fn ->
        result =
          with_unboxed_connection(fn ->
            announce_backend(parent)

            Repo.transaction(fn ->
              Repo.one!(
                from(c in RecoveryCase, where: c.id == ^fixture.case_row.id, lock: "FOR UPDATE")
              )

              send(parent, {:board_case_locked, self()})

              receive do
                :release_board_case -> :ok
              after
                10_000 -> Repo.rollback(:case_wait_timeout)
              end
            end)
          end)

        send(parent, {:board_case_locker_result, self(), result})
      end)

    assert_receive {:board_case_locked, ^case_locker}, 5_000

    {action_worker, action_ref} =
      spawn_monitored_result(:board_action_result, fn ->
        BoardApprovals.execute_approved_action(approval)
      end)

    assert :ok = await_process_blocked_by(action_worker, case_locker, 5_000)
    refute row_locked?("board_approvals", approval.id)
    send(case_locker, :release_board_case)

    assert_receive {:board_case_locker_result, ^case_locker, {:ok, :ok}}, 10_000
    assert_receive {:board_action_result, ^action_worker, {:ok, %RecoveryCase{} = child}}, 10_000
    assert_receive {:DOWN, ^case_locker_ref, :process, ^case_locker, :normal}, 5_000
    assert_receive {:DOWN, ^action_ref, :process, ^action_worker, :normal}, 5_000
    assert child.parent_case_id == fixture.case_row.id

    assert :ok = BoardApprovals.execute_approved_action(approval)

    assert Repo.aggregate(
             from(e in BoardApprovalEffect, where: e.board_approval_id == ^approval.id),
             :count
           ) == 1

    assert Repo.aggregate(
             from(c in RecoveryCase, where: c.parent_case_id == ^fixture.case_row.id),
             :count
           ) == 1
  end

  defp assert_exhaustion_terminal_race(terminal_status) do
    {company, issue, case_row, approval} = recovery_fixture!(terminal_status)
    parent = self()

    on_exit(fn -> cleanup_company(company.id) end)

    {issue_locker, issue_locker_ref} =
      spawn_monitor(fn ->
        result =
          with_unboxed_connection(fn ->
            Repo.transaction(fn ->
              Repo.one!(from(i in Issue, where: i.id == ^issue.id, lock: "FOR UPDATE"))
              send(parent, {:issue_locked, self()})

              receive do
                :release_issue -> :ok
              after
                10_000 -> Repo.rollback(:issue_lock_timeout)
              end
            end)
          end)

        send(parent, {:issue_locker_result, self(), result})
      end)

    on_exit(fn -> send(issue_locker, :release_issue) end)
    assert_receive {:issue_locked, ^issue_locker}, 5_000

    handler_id = "recovery-lock-order-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:cympho, :repo, :query],
        fn _event, _measurements, metadata, parent ->
          if String.contains?(metadata.query, ~s(FROM "recovery_cases")) and
               String.contains?(metadata.query, "FOR UPDATE") do
            send(parent, {:recovery_case_lock_finished, self()})
          end
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {exhaustion_worker, exhaustion_ref} =
      spawn_monitor(fn ->
        result =
          with_unboxed_connection(fn ->
            capture_result(fn -> Recovery.exhaust_case(case_row, reason: "repeat exhaustion") end)
          end)

        send(parent, {:exhaustion_result, self(), result})
      end)

    assert_receive {:recovery_case_lock_finished, ^exhaustion_worker}, 5_000
    :ok = :telemetry.detach(handler_id)

    {terminal_worker, terminal_ref} =
      spawn_monitor(fn ->
        result =
          with_unboxed_connection(fn ->
            capture_result(fn -> terminal_transition(approval, terminal_status, company.id) end)
          end)

        send(parent, {:terminal_result, self(), result})
      end)

    assert :ok = await_approval_lock(approval.id, 5_000)
    send(issue_locker, :release_issue)

    assert_receive {:issue_locker_result, ^issue_locker, {:ok, :ok}}, 10_000
    assert_receive {:DOWN, ^issue_locker_ref, :process, ^issue_locker, :normal}, 5_000
    assert_receive {:exhaustion_result, ^exhaustion_worker, exhaustion_result}, 10_000
    assert_receive {:terminal_result, ^terminal_worker, terminal_result}, 10_000
    assert_receive {:DOWN, ^exhaustion_ref, :process, ^exhaustion_worker, :normal}, 5_000
    assert_receive {:DOWN, ^terminal_ref, :process, ^terminal_worker, :normal}, 5_000

    assert {:ok, %BoardApproval{id: approval_id}} = exhaustion_result
    assert approval_id == approval.id
    expected_status = Atom.to_string(terminal_status)
    assert {:ok, %BoardApproval{status: ^expected_status}} = terminal_result
    assert Repo.get!(BoardApproval, approval.id).status == expected_status
    assert Repo.get!(RecoveryCase, case_row.id).state == "resolved"
    assert Repo.get!(Issue, issue.id).status == :blocked
  end

  defp heartbeat_recovery_fixture!(suffix, opts \\ []) do
    unique = System.unique_integer([:positive])

    company =
      Repo.insert!(%Company{
        name: "Recovery retained-lock #{suffix}",
        slug: "recovery-retained-lock-#{suffix}-#{unique}"
      })

    agent =
      Repo.insert!(%Agent{
        name: "Recovery retained-lock agent #{suffix}",
        role: :engineer,
        company_id: company.id
      })

    issue =
      Repo.insert!(%Issue{
        title: "Recovery retained-lock #{suffix}",
        company_id: company.id,
        assignee_id: agent.id,
        status: :in_progress
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stale_at = DateTime.add(now, -20, :minute)
    run_status = Keyword.get(opts, :run_status, "running")

    run =
      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: run_status,
        adapter: "codex",
        inserted_at: stale_at,
        last_heartbeat_at: if(run_status == "running", do: stale_at, else: nil)
      })

    {fingerprint, snapshot} = Fingerprint.for_run(run, issue)

    case_row =
      Repo.insert!(
        RecoveryCase.changeset(%RecoveryCase{}, %{
          company_id: company.id,
          issue_id: issue.id,
          agent_id: agent.id,
          source_run_id: run.id,
          source_type: "heartbeat_run",
          source_id: run.id,
          source_status: run_status,
          source_fingerprint: fingerprint,
          fingerprint_version: Fingerprint.version(),
          source_snapshot: snapshot,
          state: "exhausted",
          attempt_count: 1,
          max_attempts: 1,
          policy_snapshot: %{
            "max_attempts" => 1,
            "base_delay_seconds" => 60,
            "max_delay_seconds" => 600,
            "lease_seconds" => 300
          }
        })
      )

    Repo.update_all(from(c in RecoveryCase, where: c.id == ^case_row.id),
      set: [root_case_id: case_row.id]
    )

    %{
      company: company,
      agent: agent,
      issue: issue,
      run: run,
      case_row: Repo.get!(RecoveryCase, case_row.id),
      now: now
    }
  end

  defp run_guard(case_row, kind) do
    %{
      source_type: case_row.source_type,
      company_id: case_row.company_id,
      issue_id: case_row.issue_id,
      source_id: case_row.source_id,
      source_run_id: case_row.source_run_id,
      agent_id: case_row.agent_id,
      source_status: case_row.source_status,
      source_fingerprint: case_row.source_fingerprint,
      fingerprint_version: case_row.fingerprint_version,
      source_snapshot: case_row.source_snapshot,
      liveness_at: case_row.source_snapshot["liveness_at"],
      recovery_kind: kind
    }
  end

  defp assert_issue_locked_before_waiting_for_run(fixture, action, lock_clause \\ "FOR UPDATE") do
    parent = self()

    {run_locker, run_locker_ref} =
      spawn_monitor(fn ->
        result =
          with_unboxed_connection(fn ->
            announce_backend(parent)

            Repo.transaction(fn ->
              Repo.one!(from(r in Run, where: r.id == ^fixture.run.id, lock: "FOR UPDATE"))
              send(parent, {:ordered_run_locked, self()})

              receive do
                :release_ordered_run -> :ok
              after
                10_000 -> Repo.rollback(:run_wait_timeout)
              end
            end)
          end)

        send(parent, {:ordered_run_locker_result, self(), result})
      end)

    on_exit(fn -> send(run_locker, :release_ordered_run) end)
    assert_receive {:ordered_run_locked, ^run_locker}, 5_000

    {action_worker, action_ref} = spawn_monitored_result(:ordered_action_result, action)
    assert :ok = await_process_blocked_by(action_worker, run_locker, 5_000)
    issue_locked? = row_locked?("issues", fixture.issue.id, lock_clause)
    send(run_locker, :release_ordered_run)

    assert_receive {:ordered_run_locker_result, ^run_locker, {:ok, :ok}}, 10_000
    assert_receive {:ordered_action_result, ^action_worker, action_result}, 10_000
    assert_receive {:DOWN, ^run_locker_ref, :process, ^run_locker, :normal}, 5_000
    assert_receive {:DOWN, ^action_ref, :process, ^action_worker, :normal}, 5_000
    assert issue_locked?
    action_result
  end

  defp assert_action_retains_run_lock(run, action) do
    parent = self()

    {worker, worker_ref} =
      spawn_monitor(fn ->
        result =
          with_unboxed_connection(fn ->
            announce_backend(parent)
            send(parent, {:retained_run_worker_ready, self()})

            receive do
              :run_retained_action -> capture_result(action)
            after
              10_000 -> {:error, :retained_action_wait_timeout}
            end
          end)

        send(parent, {:retained_run_action_result, self(), result})
      end)

    assert_receive {:retained_run_worker_ready, ^worker}, 5_000
    handler_id = "retained-run-lock-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:cympho, :repo, :query],
        fn _event, _measurements, metadata, {parent, worker} ->
          if self() == worker and String.contains?(metadata.query, ~s(FROM "heartbeat_runs")) and
               String.starts_with?(String.trim_leading(metadata.query), "SELECT") do
            send(parent, {:source_run_query_finished, self()})

            receive do
              :release_source_run_query -> :ok
            after
              10_000 -> :ok
            end
          end
        end,
        {parent, worker}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(worker, :run_retained_action)
    assert_receive {:source_run_query_finished, ^worker}, 5_000
    :ok = :telemetry.detach(handler_id)
    locked? = row_locked?("heartbeat_runs", run.id)
    send(worker, :release_source_run_query)

    assert_receive {:retained_run_action_result, ^worker, result}, 10_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 5_000
    assert locked?
    result
  end

  defp run_after_committed_heartbeat(fixture, action) do
    parent = self()

    {issue_locker, issue_locker_ref} =
      spawn_monitor(fn ->
        result =
          with_unboxed_connection(fn ->
            announce_backend(parent)

            Repo.transaction(fn ->
              Repo.one!(from(i in Issue, where: i.id == ^fixture.issue.id, lock: "FOR UPDATE"))
              send(parent, {:heartbeat_gate_issue_locked, self()})

              receive do
                :release_heartbeat_gate_issue -> :ok
              after
                10_000 -> Repo.rollback(:issue_wait_timeout)
              end
            end)
          end)

        send(parent, {:heartbeat_gate_issue_result, self(), result})
      end)

    on_exit(fn -> send(issue_locker, :release_heartbeat_gate_issue) end)
    assert_receive {:heartbeat_gate_issue_locked, ^issue_locker}, 5_000

    {action_worker, action_ref} = spawn_monitored_result(:heartbeat_gate_action_result, action)
    assert :ok = await_process_blocked_by(action_worker, issue_locker, 5_000)

    {heartbeat_worker, heartbeat_ref} =
      spawn_monitored_result(:heartbeat_gate_heartbeat_result, fn ->
        HeartbeatEngine.record_heartbeat(fixture.run)
      end)

    heartbeat_before_release =
      receive do
        {:heartbeat_gate_heartbeat_result, ^heartbeat_worker, result} -> result
      after
        1_000 -> :blocked
      end

    send(issue_locker, :release_heartbeat_gate_issue)

    assert_receive {:heartbeat_gate_issue_result, ^issue_locker, {:ok, :ok}}, 10_000
    assert_receive {:heartbeat_gate_action_result, ^action_worker, action_result}, 10_000

    if heartbeat_before_release == :blocked do
      assert_receive {:heartbeat_gate_heartbeat_result, ^heartbeat_worker, _result}, 10_000
    end

    assert_receive {:DOWN, ^issue_locker_ref, :process, ^issue_locker, :normal}, 5_000
    assert_receive {:DOWN, ^action_ref, :process, ^action_worker, :normal}, 5_000
    assert_receive {:DOWN, ^heartbeat_ref, :process, ^heartbeat_worker, :normal}, 5_000
    assert match?({:ok, %Run{}}, heartbeat_before_release)
    action_result
  end

  defp spawn_monitored_result(tag, callback) do
    parent = self()

    spawn_monitor(fn ->
      result =
        with_unboxed_connection(fn ->
          announce_backend(parent)
          capture_result(callback)
        end)

      send(parent, {tag, self(), result})
    end)
  end

  defp announce_backend(parent) do
    %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    send(parent, {:db_backend, self(), backend_pid})
    :ok
  end

  defp await_process_blocked_by(worker, blocker, timeout_ms) do
    worker_backend = backend_pid_for(worker, timeout_ms)
    blocker_backend = backend_pid_for(blocker, timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_process_blocked_by(worker_backend, blocker_backend, deadline)
  end

  defp backend_pid_for(process, timeout_ms) do
    key = {:db_backend, process}

    case Process.get(key) do
      nil ->
        receive do
          {:db_backend, ^process, backend_pid} ->
            Process.put(key, backend_pid)
            backend_pid
        after
          timeout_ms -> flunk("database backend was not announced for #{inspect(process)}")
        end

      backend_pid ->
        backend_pid
    end
  end

  defp do_await_process_blocked_by(worker_backend, blocker_backend, deadline) do
    %{rows: [[blocked?]]} =
      Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [blocker_backend, worker_backend])

    cond do
      blocked? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :blocking_timeout}

      true ->
        Process.sleep(10)
        do_await_process_blocked_by(worker_backend, blocker_backend, deadline)
    end
  end

  defp row_locked?(table, id, lock_clause \\ "FOR UPDATE")

  defp row_locked?(table, id, lock_clause)
       when table in ["issues", "heartbeat_runs", "board_approvals"] and
              lock_clause in ["FOR UPDATE", "FOR NO KEY UPDATE"] do
    Repo.transaction(fn ->
      Repo.query!("SELECT id FROM #{table} WHERE id = $1 #{lock_clause} NOWAIT", [
        Ecto.UUID.dump!(id)
      ])

      Repo.rollback(:row_available)
    end)

    false
  rescue
    error in Postgrex.Error ->
      case error.postgres.code do
        :lock_not_available -> true
        "55P03" -> true
        _ -> reraise(error, __STACKTRACE__)
      end
  end

  defp postgres_deadlock?(result) do
    rendered = inspect(result)
    String.contains?(rendered, "deadlock_detected") or String.contains?(rendered, "40P01")
  end

  defp recovery_fixture!(suffix) do
    unique = System.unique_integer([:positive])

    company =
      Repo.insert!(%Company{
        name: "Recovery lock order #{suffix}",
        slug: "recovery-lock-order-#{suffix}-#{unique}"
      })

    issue =
      Repo.insert!(%Issue{
        title: "Recovery lock order #{suffix}",
        company_id: company.id,
        status: :in_progress
      })

    {:ok, case_row} =
      Recovery.ensure_case(%{
        company_id: company.id,
        source_type: "issue_checkout",
        issue: issue,
        max_attempts: 1
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, lease} = Recovery.claim_case(case_row, now: now)
    {:ok, exhausted} = Recovery.record_failure(lease, "provider timeout", now: now)
    {:ok, approval} = Recovery.exhaust_case(exhausted, now: now)

    {company, Repo.get!(Issue, issue.id), Repo.get!(RecoveryCase, case_row.id), approval}
  end

  defp terminal_transition(approval, :denied, company_id) do
    BoardApprovals.resolve_board_approval(
      approval.id,
      "denied",
      %{decision_reasoning: "leave paused"},
      {"system", company_id}
    )
  end

  defp terminal_transition(approval, :cancelled, company_id) do
    BoardApprovals.cancel_board_approval(approval.id, {"system", company_id})
  end

  defp await_approval_lock(approval_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_approval_lock(approval_id, deadline)
  end

  defp do_await_approval_lock(approval_id, deadline) do
    cond do
      approval_locked?(approval_id) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :approval_lock_timeout}

      true ->
        Process.sleep(10)
        do_await_approval_lock(approval_id, deadline)
    end
  end

  defp approval_locked?(approval_id) do
    Repo.transaction(fn ->
      Repo.query!(
        "SELECT id FROM board_approvals WHERE id = $1 FOR UPDATE NOWAIT",
        [Ecto.UUID.dump!(approval_id)]
      )

      Repo.rollback(:not_locked)
    end)

    false
  rescue
    error in Postgrex.Error ->
      case error.postgres.code do
        :lock_not_available -> true
        "55P03" -> true
        _ -> reraise(error, __STACKTRACE__)
      end
  end

  defp capture_result(callback) do
    callback.()
  rescue
    error -> {:raised, error}
  catch
    kind, reason -> {kind, reason}
  end

  defp with_unboxed_connection(callback) do
    Process.delete(:"$callers")
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    try do
      callback.()
    after
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end
  end

  defp cleanup_company(company_id) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("ALTER TABLE audit_events DISABLE TRIGGER audit_events_prevent_delete")

      try do
        Repo.delete_all(from(event in AuditEvent, where: event.company_id == ^company_id))
      after
        Repo.query!("ALTER TABLE audit_events ENABLE TRIGGER audit_events_prevent_delete")
      end

      Repo.delete_all(from(log in GovernanceAuditLog, where: log.company_id == ^company_id))
      Repo.delete_all(from(decision in Decision, where: decision.company_id == ^company_id))

      Repo.delete_all(
        from(effect in BoardApprovalEffect,
          join: approval in BoardApproval,
          on: approval.id == effect.board_approval_id,
          where: approval.company_id == ^company_id
        )
      )

      Repo.delete_all(from(approval in BoardApproval, where: approval.company_id == ^company_id))

      Repo.delete_all(
        from(attempt in RecoveryAttempt,
          join: case_row in RecoveryCase,
          on: case_row.id == attempt.recovery_case_id,
          where: case_row.company_id == ^company_id
        )
      )

      Repo.delete_all(from(case_row in RecoveryCase, where: case_row.company_id == ^company_id))
      Repo.delete_all(from(run in Run, where: run.company_id == ^company_id))
      Repo.delete_all(from(activity in Activity, where: activity.company_id == ^company_id))
      Repo.delete_all(from(issue in Issue, where: issue.company_id == ^company_id))
      Repo.delete_all(from(agent in Agent, where: agent.company_id == ^company_id))
      Repo.delete_all(from(company in Company, where: company.id == ^company_id))
    end)
  end
end
