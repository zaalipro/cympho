defmodule Cympho.BoardApprovals.RecoveryActionTest do
  use Cympho.DataCase, async: false

  import Ecto.Query

  alias Cympho.Agents.Agent
  alias Cympho.BoardApprovals
  alias Cympho.BoardApprovals.{BoardApproval, BoardApprovalEffect}
  alias Cympho.Companies.Company
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue
  alias Cympho.OwnerAttention
  alias Cympho.Recovery
  alias Cympho.Recovery.{Fingerprint, RecoveryCase}
  alias Cympho.Repo

  setup do
    unique = System.unique_integer([:positive])
    company = company!("recovery-board-#{unique}", "RB")
    other_company = company!("recovery-board-other-#{unique}", "RO")
    agent = agent!(company, "Recovery engineer #{unique}")
    other_agent = agent!(other_company, "Other recovery engineer #{unique}")

    %{company: company, other_company: other_company, agent: agent, other_agent: other_agent}
  end

  test "exhaustion creates one board proposal, blocks the issue, and is idempotent", %{
    company: company,
    agent: agent
  } do
    issue = issue!(company, agent, "Stranded checkout", lock_version: 7)
    case_row = exhausted_case!(issue, max_attempts: 1)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    :ok = OwnerAttention.subscribe(company.id)
    :ok = Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company.id}:approvals")

    assert {:ok, approval} =
             Recovery.exhaust_case(case_row,
               reason: "timeout password=raw-secret prompt=private-prompt full-log=raw-log",
               now: now
             )

    assert %BoardApproval{} = approval
    assert approval.category == "stranded_work_recovery"
    assert approval.status == "pending"
    assert approval.recovery_case_id == case_row.id

    assert Repo.aggregate(
             from(a in BoardApproval, where: a.recovery_case_id == ^case_row.id),
             :count
           ) == 1

    persisted_case = Repo.get!(RecoveryCase, case_row.id)
    persisted_issue = Repo.get!(Issue, issue.id)
    assert persisted_case.state == "escalated"
    assert persisted_case.escalated_at != nil
    assert persisted_issue.status == :blocked
    assert persisted_issue.assignee_id == agent.id
    assert persisted_issue.lock_version == 8

    proposal = approval.proposal_data

    assert Map.keys(proposal) |> MapSet.new() ==
             MapSet.new([
               "action",
               "case_id",
               "issue_id",
               "source_run_id",
               "source_type",
               "fingerprint",
               "attempt_count",
               "max_attempts",
               "last_error",
               "attempt_history",
               "restart_packet"
             ])

    assert proposal["case_id"] == case_row.id
    assert proposal["issue_id"] == issue.id
    assert proposal["fingerprint"] == case_row.source_fingerprint
    assert proposal["attempt_count"] == case_row.attempt_count
    assert proposal["max_attempts"] == case_row.max_attempts
    assert proposal["last_error"] == "timeout"

    assert proposal["restart_packet"] == %{
             "issue_id" => issue.id,
             "case_id" => case_row.id,
             "source_type" => "issue_checkout",
             "attempts" => proposal["attempt_history"]
           }

    refute inspect(proposal) =~ "raw-secret"
    refute inspect(proposal) =~ "private-prompt"
    refute inspect(proposal) =~ "raw-log"

    assert_receive {:board_approval_created, %BoardApproval{id: id}}, 1_000
    assert id == approval.id
    company_id = company.id
    assert_receive {:owner_attention_changed, ^company_id}, 1_000

    # The source fingerprint changes when the first call blocks the issue. A
    # retry of the same exhausted/escalated row must still return its existing
    # proposal instead of superseding it or inserting a second row.
    assert {:ok, same_approval} =
             Recovery.exhaust_case(Repo.get!(RecoveryCase, case_row.id), now: now)

    assert same_approval.id == approval.id
    refute_receive {:board_approval_created, _}, 50
    refute_receive {:owner_attention_changed, _}, 50

    assert Repo.aggregate(
             from(a in BoardApproval, where: a.recovery_case_id == ^case_row.id),
             :count
           ) == 1

    audit =
      Repo.one!(
        from l in Cympho.GovernanceAuditLogs.GovernanceAuditLog,
          where: l.action_type == "recovery_exhausted" and l.resource_id == ^approval.id,
          order_by: [desc: l.inserted_at]
      )

    refute inspect(audit.metadata) =~ "raw-secret"
    refute inspect(audit.reasoning) =~ "raw-secret"
    assert audit.company_id == company.id
    assert audit.resource_type == "boardapproval"
    assert audit.decision == "Recovery case exhausted"
    assert audit.metadata == %{}
  end

  test "recovery approval helper participates in the caller transaction without publishing", %{
    company: company,
    agent: agent
  } do
    issue = issue!(company, agent, "Helper linkage")
    {:ok, recovery_case} = Recovery.ensure_case(%{source_type: "issue_checkout", issue: issue})
    :ok = Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company.id}:approvals")

    assert {:error, :rolled_back} =
             Repo.transaction(fn ->
               assert {:ok, _approval} =
                        BoardApprovals.create_recovery_approval(%{
                          title: "Rolled back retry",
                          company_id: company.id,
                          recovery_case_id: recovery_case.id,
                          proposal_data: %{"action" => "retry"}
                        })

               refute_receive {:board_approval_created, _}, 0
               Repo.rollback(:rolled_back)
             end)

    assert Repo.aggregate(BoardApproval, :count) == 0
    refute_receive {:board_approval_created, _}, 50

    assert {:ok, {:ok, committed}} =
             Repo.transaction(fn ->
               BoardApprovals.create_recovery_approval(%{
                 title: "Committed retry",
                 company_id: company.id,
                 recovery_case_id: recovery_case.id,
                 proposal_data: %{"action" => "retry"}
               })
             end)

    assert committed.category == "stranded_work_recovery"
    assert Repo.aggregate(BoardApproval, :count) == 1
    refute_receive {:board_approval_created, _}, 50

    assert {:error, wrong_category} =
             BoardApprovals.create_recovery_approval(%{
               title: "Wrong category",
               category: "other",
               company_id: company.id,
               recovery_case_id: recovery_case.id
             })

    assert "must be stranded_work_recovery" in errors_on(wrong_category).category
  end

  test "stale source, fingerprint, and tenant mismatches supersede without side effects", %{
    company: company,
    other_company: other_company,
    agent: agent
  } do
    stale_issue = issue!(company, agent, "Changed source", lock_version: 1)
    stale_case = checkout_case!(stale_issue, source_fingerprint: String.duplicate("a", 64))
    stale_lock = stale_issue.lock_version

    assert {:ok, %RecoveryCase{state: "superseded"}} =
             Recovery.exhaust_case(stale_case, reason: "stale")

    assert Repo.get!(Issue, stale_issue.id).status == :in_progress
    assert Repo.get!(Issue, stale_issue.id).lock_version == stale_lock

    assert Repo.aggregate(
             from(a in BoardApproval, where: a.recovery_case_id == ^stale_case.id),
             :count
           ) == 0

    fingerprint_issue = issue!(company, agent, "Changed fingerprint", lock_version: 2)
    fingerprint_case = checkout_case!(fingerprint_issue)

    Repo.update_all(from(i in Issue, where: i.id == ^fingerprint_issue.id),
      inc: [lock_version: 1]
    )

    assert {:ok, %RecoveryCase{state: "superseded"}} =
             Recovery.exhaust_case(fingerprint_case, reason: "changed")

    changed_issue = Repo.get!(Issue, fingerprint_issue.id)
    assert changed_issue.status == :in_progress
    assert changed_issue.lock_version == 3

    assert Repo.aggregate(
             from(a in BoardApproval, where: a.recovery_case_id == ^fingerprint_case.id),
             :count
           ) == 0

    tenant_issue = issue!(company, agent, "Tenant mismatch")
    tenant_case = checkout_case!(tenant_issue)

    Repo.update_all(from(c in RecoveryCase, where: c.id == ^tenant_case.id),
      set: [company_id: other_company.id]
    )

    tenant_case = Repo.get!(RecoveryCase, tenant_case.id)

    assert {:ok, %RecoveryCase{state: "superseded"}} =
             Recovery.exhaust_case(tenant_case, reason: "tenant")

    assert Repo.get!(Issue, tenant_issue.id).status == :in_progress

    assert Repo.aggregate(
             from(a in BoardApproval, where: a.recovery_case_id == ^tenant_case.id),
             :count
           ) == 0
  end

  test "an escalated proposal is superseded if its issue becomes terminal", %{
    company: company,
    agent: agent
  } do
    issue = issue!(company, agent, "Terminal after escalation")
    case_row = exhausted_case!(issue, max_attempts: 1)
    {:ok, approval} = Recovery.exhaust_case(case_row, reason: "timeout")

    Repo.update_all(from(i in Issue, where: i.id == ^issue.id), set: [status: :done])

    assert {:ok, %RecoveryCase{state: "superseded"}} =
             Recovery.exhaust_case(Repo.get!(RecoveryCase, case_row.id), reason: "late retry")

    assert Repo.get!(Issue, issue.id).status == :done
    assert Repo.get!(BoardApproval, approval.id).status == "cancelled"

    assert Repo.aggregate(
             from(a in BoardApproval, where: a.recovery_case_id == ^case_row.id),
             :count
           ) == 1
  end

  test "terminal heartbeat runs are rejected as stale sources", %{company: company, agent: agent} do
    for status <- ~w(completed succeeded failed cancelled timed_out done) do
      issue = issue!(company, agent, "Terminal #{status}")

      run =
        Repo.insert!(%Run{
          company_id: company.id,
          agent_id: agent.id,
          issue_id: issue.id,
          status: status,
          adapter: "codex",
          error_reason: "provider failure"
        })

      {fingerprint, snapshot} = Fingerprint.for_run(run, issue)

      case_row =
        recovery_case!(%{
          company_id: company.id,
          issue_id: issue.id,
          agent_id: agent.id,
          source_run_id: run.id,
          source_type: "heartbeat_run",
          source_id: run.id,
          source_status: status,
          source_fingerprint: fingerprint,
          fingerprint_version: Fingerprint.version(),
          source_snapshot: snapshot,
          state: "exhausted",
          attempt_count: 1,
          max_attempts: 1,
          policy_snapshot: complete_policy(1)
        })

      assert {:ok, %RecoveryCase{state: "superseded"}} =
               Recovery.exhaust_case(case_row, reason: "terminal")

      assert Repo.get!(Issue, issue.id).status == :in_progress

      assert Repo.aggregate(
               from(a in BoardApproval, where: a.recovery_case_id == ^case_row.id),
               :count
             ) == 0
    end
  end

  test "a changed heartbeat source fingerprint supersedes without blocking", %{
    company: company,
    agent: agent
  } do
    issue = issue!(company, agent, "Changed heartbeat")

    run =
      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "running",
        adapter: "codex"
      })

    {fingerprint, snapshot} = Fingerprint.for_run(run, issue)

    case_row =
      recovery_case!(%{
        company_id: company.id,
        issue_id: issue.id,
        agent_id: agent.id,
        source_run_id: run.id,
        source_type: "heartbeat_run",
        source_id: run.id,
        source_status: "running",
        source_fingerprint: fingerprint,
        fingerprint_version: Fingerprint.version(),
        source_snapshot: snapshot,
        state: "exhausted",
        attempt_count: 1,
        max_attempts: 1,
        policy_snapshot: complete_policy(1)
      })

    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [error_reason: "credential rotated"]
    )

    assert {:ok, %RecoveryCase{state: "superseded"}} =
             Recovery.exhaust_case(case_row, reason: "stale heartbeat")

    assert Repo.get!(Issue, issue.id).status == :in_progress

    assert Repo.aggregate(
             from(a in BoardApproval, where: a.recovery_case_id == ^case_row.id),
             :count
           ) == 0
  end

  test "denied, expired, and cancelled approvals resolve their cases and keep issues blocked", %{
    company: company,
    agent: agent
  } do
    for status <- ~w(denied expired cancelled) do
      issue = issue!(company, agent, "Resolution #{status}")
      case_row = exhausted_case!(issue, max_attempts: 1)
      {:ok, approval} = Recovery.exhaust_case(case_row, reason: "provider timeout")

      Repo.update_all(from(a in BoardApproval, where: a.id == ^approval.id),
        set: [status: status]
      )

      approval = Repo.get!(BoardApproval, approval.id)

      assert :ok = Recovery.handle_approval_resolution(approval)

      resolved = Repo.get!(RecoveryCase, case_row.id)
      persisted_issue = Repo.get!(Issue, issue.id)
      assert resolved.state == "resolved"
      assert resolved.resolved_at != nil
      assert persisted_issue.status == :blocked
      assert persisted_issue.assignee_id == agent.id
    end
  end

  test "cross-company resolution and retry proposals fail closed", %{
    company: company,
    other_company: other_company,
    agent: agent,
    other_agent: other_agent
  } do
    issue = issue!(company, agent, "Protected issue")
    case_row = exhausted_case!(issue, max_attempts: 1)
    {:ok, approval} = Recovery.exhaust_case(case_row, reason: "timeout")
    :ok = OwnerAttention.subscribe(other_company.id)

    assert :ok =
             Recovery.handle_approval_resolution(%{
               approval
               | status: "denied",
                 company_id: other_company.id
             })

    assert Repo.get!(RecoveryCase, case_row.id).state == "escalated"
    assert Repo.get!(Issue, issue.id).status == :blocked
    other_company_id = other_company.id
    refute_receive {:owner_attention_changed, ^other_company_id}, 50

    forged_case = %{approval | status: "approved", recovery_case_id: Ecto.UUID.generate()}
    assert {:error, :stale_recovery_proposal} = Recovery.apply_board_action(forged_case)
    assert Repo.get!(RecoveryCase, case_row.id).state == "escalated"
    assert Repo.get!(Issue, issue.id).status == :blocked

    for forged <- [
          %{approval | status: "approved", category: "other"},
          %{approval | status: "approved", company_id: other_company.id},
          %{
            approval
            | status: "approved",
              proposal_data:
                Map.put(approval.proposal_data, "fingerprint", String.duplicate("f", 64))
          },
          %{
            approval
            | status: "approved",
              proposal_data: Map.put(approval.proposal_data, "action", "approve")
          }
        ] do
      assert {:error, :stale_recovery_proposal} = Recovery.apply_board_action(forged)
      assert Repo.get!(RecoveryCase, case_row.id).state == "escalated"
      assert Repo.get!(Issue, issue.id).status == :blocked
    end

    foreign_issue = issue!(other_company, other_agent, "Foreign protected issue")
    foreign_case = checkout_case!(foreign_issue)

    foreign_approval = %{
      approval
      | status: "approved",
        company_id: company.id,
        recovery_case_id: foreign_case.id,
        proposal_data:
          approval.proposal_data
          |> Map.put("case_id", foreign_case.id)
          |> Map.put("issue_id", foreign_issue.id)
          |> Map.put("fingerprint", foreign_case.source_fingerprint)
    }

    Repo.update_all(from(i in Issue, where: i.id == ^foreign_issue.id), set: [status: :blocked])
    assert {:error, :stale_recovery_proposal} = Recovery.apply_board_action(foreign_approval)
    assert Repo.get!(RecoveryCase, foreign_case.id).state == "exhausted"
    assert Repo.get!(Issue, foreign_issue.id).status == :blocked
  end

  test "approved retry reopens only its blocked issue, preserves lineage and assignee, and is idempotent",
       %{
         company: company,
         other_company: other_company,
         agent: agent
       } do
    issue = issue!(company, agent, "Retry me", lock_version: 4)
    unrelated = issue!(company, agent, "Leave blocked", lock_version: 3)
    Repo.update_all(from(i in Issue, where: i.id in ^[unrelated.id]), set: [status: :blocked])

    case_row = exhausted_case!(issue, max_attempts: 1)
    {:ok, approval} = Recovery.exhaust_case(case_row, reason: "timeout")

    Repo.update_all(from(a in BoardApproval, where: a.id == ^approval.id),
      set: [status: "approved"]
    )

    approved = Repo.get!(BoardApproval, approval.id)
    :ok = OwnerAttention.subscribe(company.id)
    :ok = OwnerAttention.subscribe(other_company.id)
    dispatcher = Process.whereis(Cympho.Orchestrator.Dispatcher)
    assert is_pid(dispatcher)
    :erlang.trace(dispatcher, true, [:receive])
    on_exit(fn -> :erlang.trace(dispatcher, false, [:receive]) end)
    flush_dispatcher_traces(dispatcher)

    assert {:ok, child} = Recovery.apply_board_action(approved)
    assert child.state == "scheduled"
    assert child.parent_case_id == case_row.id
    assert child.root_case_id == case_row.root_case_id
    assert child.issue_id == issue.id
    assert child.company_id == company.id
    assert child.source_id == issue.id
    assert child.next_attempt_at != nil

    expected_poll = {:poll_company, company.id}
    assert_receive {:trace, ^dispatcher, :receive, ^expected_poll}, 1_000
    refute_receive {:trace, ^dispatcher, :receive, ^expected_poll}, 50
    refute_receive {:trace, ^dispatcher, :receive, :poll}, 50
    company_id = company.id
    assert_receive {:owner_attention_changed, ^company_id}, 1_000
    other_company_id = other_company.id
    refute_receive {:owner_attention_changed, ^other_company_id}, 50
    refute_receive {:owner_attention_changed, ^company_id}, 50

    assert Repo.get!(RecoveryCase, case_row.id).state == "resolved"
    reopened = Repo.get!(Issue, issue.id)
    assert reopened.status == :todo
    assert reopened.assignee_id == agent.id
    assert reopened.lock_version == 6
    assert Repo.get!(Issue, unrelated.id).status == :blocked

    assert Repo.aggregate(
             from(c in RecoveryCase,
               where: c.issue_id == ^issue.id and c.parent_case_id == ^case_row.id
             ),
             :count
           ) == 1

    assert {:error, :stale_recovery_proposal} = Recovery.apply_board_action(approved)

    assert Repo.aggregate(
             from(c in RecoveryCase,
               where: c.issue_id == ^issue.id and c.parent_case_id == ^case_row.id
             ),
             :count
           ) == 1
  end

  test "an approved retry cannot reopen a blocked issue after its source lock changes", %{
    company: company,
    agent: agent
  } do
    issue = issue!(company, agent, "Changed before approval")
    case_row = exhausted_case!(issue, max_attempts: 1)
    {:ok, approval} = Recovery.exhaust_case(case_row, reason: "timeout")

    Repo.update_all(from(a in BoardApproval, where: a.id == ^approval.id),
      set: [status: "approved"]
    )

    approved = Repo.get!(BoardApproval, approval.id)

    Repo.update_all(from(i in Issue, where: i.id == ^issue.id), inc: [lock_version: 1])

    assert {:error, :stale_recovery_proposal} = Recovery.apply_board_action(approved)
    assert Repo.get!(RecoveryCase, case_row.id).state == "escalated"
    changed = Repo.get!(Issue, issue.id)
    assert changed.status == :blocked
    assert changed.lock_version == 2

    assert Repo.aggregate(
             from(c in RecoveryCase, where: c.parent_case_id == ^case_row.id),
             :count
           ) == 0
  end

  test "approved heartbeat-run retry accepts the unchanged non-terminal run", %{
    company: company,
    agent: agent
  } do
    issue = issue!(company, agent, "Heartbeat retry")

    run =
      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "running",
        adapter: "codex"
      })

    {fingerprint, snapshot} = Fingerprint.for_run(run, issue)

    case_row =
      recovery_case!(%{
        company_id: company.id,
        issue_id: issue.id,
        agent_id: agent.id,
        source_run_id: run.id,
        source_type: "heartbeat_run",
        source_id: run.id,
        source_status: "running",
        source_fingerprint: fingerprint,
        fingerprint_version: Fingerprint.version(),
        source_snapshot: snapshot,
        state: "exhausted",
        attempt_count: 1,
        max_attempts: 1,
        policy_snapshot: complete_policy(1)
      })

    {:ok, approval} = Recovery.exhaust_case(case_row, reason: "network")

    Repo.update_all(from(a in BoardApproval, where: a.id == ^approval.id),
      set: [status: "approved"]
    )

    assert {:ok, child} = Recovery.apply_board_action(Repo.get!(BoardApproval, approval.id))
    assert child.source_type == "heartbeat_run"
    assert child.source_id == run.id
    assert child.source_run_id == run.id
    assert child.root_case_id == case_row.root_case_id
    reopened = Repo.get!(Issue, issue.id)
    assert reopened.status == :todo
    {expected_fingerprint, expected_snapshot} = Fingerprint.for_run(run, reopened)
    assert child.source_fingerprint == expected_fingerprint
    assert child.source_snapshot == expected_snapshot
    assert child.source_status == "todo"
  end

  test "approved retry resumes a paused runtime and clears the exact failed checkout", %{
    company: company,
    agent: agent
  } do
    issue = issue!(company, agent, "Paused failed checkout")

    run =
      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "failed",
        adapter: "codex",
        error_reason: "timeout"
      })

    checked_out_at = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(from(i in Issue, where: i.id == ^issue.id),
      set: [
        checkout_run_id: run.id,
        checked_out_at: checked_out_at,
        monitor_state: %{
          "issue_runtime" => %{
            "paused" => true,
            "paused_at" => DateTime.to_iso8601(checked_out_at),
            "paused_reason" => "operator review"
          }
        }
      ]
    )

    source_issue = Repo.get!(Issue, issue.id)
    case_row = exhausted_case!(source_issue, max_attempts: 1)
    {:ok, approval} = Recovery.exhaust_case(case_row, reason: "timeout")

    Repo.update_all(from(a in BoardApproval, where: a.id == ^approval.id),
      set: [status: "approved"]
    )

    assert {:ok, child} =
             Recovery.apply_board_action(Repo.get!(BoardApproval, approval.id),
               defer_side_effects: true
             )

    reopened = Repo.get!(Issue, issue.id)
    assert reopened.status == :todo
    assert reopened.assignee_id == agent.id
    assert reopened.checkout_run_id == nil
    assert reopened.checked_out_at == nil
    refute Cympho.Issues.issue_runtime_paused?(reopened)
    assert child.source_id == issue.id
    assert child.parent_case_id == case_row.id
  end

  test "deadline expiry durably resolves recovery and blocks late approval", %{
    company: company,
    agent: agent
  } do
    issue = issue!(company, agent, "Expired recovery")
    case_row = exhausted_case!(issue, max_attempts: 1)
    {:ok, approval} = Recovery.exhaust_case(case_row, reason: "timeout")
    expired_at = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(a in BoardApproval, where: a.id == ^approval.id),
      set: [review_deadline: expired_at]
    )

    assert {:error, :approval_expired} =
             BoardApprovals.resolve_board_approval(
               approval.id,
               "approved",
               %{decision_reasoning: "too late"},
               {"system", company.id}
             )

    assert Repo.get!(BoardApproval, approval.id).status == "expired"
    assert Repo.get!(RecoveryCase, case_row.id).state == "resolved"
    assert Repo.get!(Issue, issue.id).status == :blocked
  end

  test "startup reconciliation resolves already denied recovery approvals", %{
    company: company,
    agent: agent
  } do
    issue = issue!(company, agent, "Denied while executor down")
    case_row = exhausted_case!(issue, max_attempts: 1)
    {:ok, approval} = Recovery.exhaust_case(case_row, reason: "timeout")

    Repo.update_all(from(a in BoardApproval, where: a.id == ^approval.id),
      set: [status: "denied", decision_reasoning: "leave paused"]
    )

    assert BoardApprovals.reconcile_recovery_resolutions() >= 1
    assert Repo.get!(RecoveryCase, case_row.id).state == "resolved"
    assert Repo.get!(Issue, issue.id).status == :blocked
  end

  test "the durable board effect makes executor retry idempotent", %{
    company: company,
    agent: agent
  } do
    issue = issue!(company, agent, "Effect retry")
    case_row = exhausted_case!(issue, max_attempts: 1)
    {:ok, approval} = Recovery.exhaust_case(case_row, reason: "timeout")

    Repo.update_all(from(a in BoardApproval, where: a.id == ^approval.id),
      set: [status: "approved"]
    )

    approved = Repo.get!(BoardApproval, approval.id)

    assert {:ok, _child} = BoardApprovals.execute_approved_action(approved)
    assert :ok = BoardApprovals.execute_approved_action(approved)

    assert Repo.aggregate(
             from(e in BoardApprovalEffect, where: e.board_approval_id == ^approval.id),
             :count
           ) == 1

    assert Repo.aggregate(
             from(c in RecoveryCase,
               where: c.issue_id == ^issue.id and c.parent_case_id == ^case_row.id
             ),
             :count
           ) == 1
  end

  test "the executor resolves non-approved recovery proposals", %{company: company, agent: agent} do
    issue = issue!(company, agent, "Executor resolution")
    case_row = exhausted_case!(issue, max_attempts: 1)
    {:ok, approval} = Recovery.exhaust_case(case_row, reason: "timeout")

    Repo.update_all(from(a in BoardApproval, where: a.id == ^approval.id),
      set: [status: "denied"]
    )

    approval = Repo.get!(BoardApproval, approval.id)
    state = %{initial_recovery?: false}

    assert {:noreply, ^state} =
             Cympho.BoardApprovals.BoardApprovalActionExecutor.handle_info(
               {:board_approval_resolved, approval},
               state
             )

    assert Repo.get!(RecoveryCase, case_row.id).state == "resolved"
    assert Repo.get!(Issue, issue.id).status == :blocked
  end

  defp company!(slug, prefix) do
    %Company{}
    |> Company.changeset(%{name: slug, slug: slug, issue_prefix: prefix})
    |> Repo.insert!()
  end

  defp agent!(company, name) do
    %Agent{}
    |> Agent.changeset(%{name: name, role: :engineer, company_id: company.id})
    |> Repo.insert!()
  end

  defp issue!(company, agent, title, opts \\ []) do
    issue =
      %Issue{}
      |> Issue.changeset(%{
        title: title,
        description: "Durable recovery test issue",
        company_id: company.id,
        assignee_id: agent.id,
        status: Keyword.get(opts, :status, :in_progress)
      })
      |> Repo.insert!()

    lock_version = Keyword.get(opts, :lock_version, 0)

    if lock_version == 0 do
      issue
    else
      Repo.update_all(from(i in Issue, where: i.id == ^issue.id),
        set: [lock_version: lock_version]
      )

      Repo.get!(Issue, issue.id)
    end
  end

  defp exhausted_case!(issue, opts) do
    max_attempts = Keyword.get(opts, :max_attempts, 1)

    {:ok, case_row} =
      Recovery.ensure_case(%{
        company_id: issue.company_id,
        source_type: "issue_checkout",
        issue: issue,
        max_attempts: max_attempts
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, lease} = Recovery.claim_case(case_row, now: now)
    {:ok, exhausted} = Recovery.record_failure(lease, "provider timeout", now: now)
    exhausted
  end

  defp checkout_case!(issue, attrs \\ []) do
    {fingerprint, snapshot} = Fingerprint.for_issue_checkout(issue)

    recovery_case!(
      Map.merge(
        %{
          company_id: issue.company_id,
          issue_id: issue.id,
          agent_id: issue.assignee_id,
          source_type: "issue_checkout",
          source_id: issue.id,
          source_status: "in_progress",
          source_fingerprint: fingerprint,
          fingerprint_version: Fingerprint.version(),
          source_snapshot: snapshot,
          state: "exhausted",
          attempt_count: 1,
          max_attempts: 1,
          policy_snapshot: complete_policy(1)
        },
        Map.new(attrs)
      )
    )
  end

  defp recovery_case!(attrs) do
    row =
      %RecoveryCase{}
      |> RecoveryCase.changeset(attrs)
      |> Repo.insert!()

    Repo.update_all(from(c in RecoveryCase, where: c.id == ^row.id), set: [root_case_id: row.id])
    Repo.get!(RecoveryCase, row.id)
  end

  defp complete_policy(max_attempts) do
    %{
      "max_attempts" => max_attempts,
      "base_delay_seconds" => 60,
      "max_delay_seconds" => 600,
      "lease_seconds" => 300
    }
  end

  defp flush_dispatcher_traces(dispatcher) do
    receive do
      {:trace, ^dispatcher, :receive, _message} -> flush_dispatcher_traces(dispatcher)
    after
      0 -> :ok
    end
  end
end
