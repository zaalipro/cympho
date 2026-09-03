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
  alias Cympho.BoardApprovals
  alias Cympho.BoardApprovals.BoardApproval
  alias Cympho.Companies.Company
  alias Cympho.Decisions.Decision
  alias Cympho.GovernanceAuditLogs.GovernanceAuditLog
  alias Cympho.Issues.Issue
  alias Cympho.Recovery
  alias Cympho.Recovery.RecoveryCase
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
      Repo.delete_all(from(approval in BoardApproval, where: approval.company_id == ^company_id))
      Repo.delete_all(from(case_row in RecoveryCase, where: case_row.company_id == ^company_id))
      Repo.delete_all(from(issue in Issue, where: issue.company_id == ^company_id))
      Repo.delete_all(from(company in Company, where: company.id == ^company_id))
    end)
  end
end
