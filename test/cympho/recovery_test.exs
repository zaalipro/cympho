defmodule Cympho.RecoveryTest do
  use Cympho.DataCase, async: false
  alias Cympho.Repo
  alias Cympho.Companies.Company
  alias Cympho.Issues.Issue
  alias Cympho.Recovery.RecoveryCase
  alias Cympho.Recovery.RecoveryAttempt

  test "recovery case changeset defaults and validates state" do
    company = Repo.insert!(%Company{name: "Recovery Co", slug: "recovery-co"})
    issue = Repo.insert!(%Issue{title: "Stranded", company_id: company.id})

    attrs = %{
      company_id: company.id,
      issue_id: issue.id,
      source_type: "issue_checkout",
      source_id: issue.id,
      source_status: "in_progress",
      source_fingerprint: String.duplicate("a", 64),
      fingerprint_version: 1
    }

    assert {:ok, row} = %RecoveryCase{} |> RecoveryCase.changeset(attrs) |> Repo.insert()
    assert row.state == "detected"
    assert row.company_id == company.id

    assert {:error, changeset} =
             %RecoveryCase{}
             |> RecoveryCase.changeset(Map.put(attrs, :state, "bogus"))
             |> Repo.insert()

    assert "is invalid" in errors_on(changeset).state
  end

  test "active source uniqueness excludes superseded rows" do
    company = Repo.insert!(%Company{name: "Recovery Co 2", slug: "recovery-co-2"})
    issue = Repo.insert!(%Issue{title: "Stranded", company_id: company.id})

    attrs = %{
      company_id: company.id,
      issue_id: issue.id,
      source_type: "issue_checkout",
      source_id: issue.id,
      source_status: "in_progress",
      source_fingerprint: String.duplicate("b", 64),
      fingerprint_version: 1
    }

    assert {:ok, _} = %RecoveryCase{} |> RecoveryCase.changeset(attrs) |> Repo.insert()
    assert {:error, changeset} = %RecoveryCase{} |> RecoveryCase.changeset(attrs) |> Repo.insert()
    assert "has already been taken" in errors_on(changeset).source_id

    assert {:ok, _} =
             %RecoveryCase{}
             |> RecoveryCase.changeset(
               attrs
               |> Map.put(:state, "superseded")
               |> Map.put(:source_fingerprint, String.duplicate("e", 64))
             )
             |> Repo.insert()
  end

  test "exposes status lists" do
    assert "detected" in RecoveryCase.states()
    assert "heartbeat_run" in RecoveryCase.source_types()
    assert "succeeded" in RecoveryAttempt.statuses()
  end

  test "attempts validate status and unique attempt number" do
    company = Repo.insert!(%Company{name: "Attempt Co", slug: "attempt-co"})
    issue = Repo.insert!(%Issue{title: "Attempt issue", company_id: company.id})

    attrs = %{
      company_id: company.id,
      issue_id: issue.id,
      source_type: "issue_checkout",
      source_id: issue.id,
      source_status: "in_progress",
      source_fingerprint: String.duplicate("c", 64)
    }

    case_row = Repo.insert!(RecoveryCase.changeset(%RecoveryCase{}, attrs))

    attempt_attrs = %{
      recovery_case_id: case_row.id,
      attempt_no: 1,
      status: "claimed",
      action: "retry",
      source_fingerprint: attrs.source_fingerprint
    }

    assert {:ok, _attempt} =
             RecoveryAttempt.changeset(%RecoveryAttempt{}, attempt_attrs) |> Repo.insert()

    assert {:error, dup} =
             RecoveryAttempt.changeset(%RecoveryAttempt{}, attempt_attrs) |> Repo.insert()

    assert "has already been taken" in Map.get(errors_on(dup), :recovery_case_id, [])

    assert {:error, invalid} =
             RecoveryAttempt.changeset(%RecoveryAttempt{}, %{attempt_attrs | status: "bogus"})
             |> Repo.insert()

    assert "is invalid" in errors_on(invalid).status
  end

  test "board approval supports recovery linkage and category" do
    company = Repo.insert!(%Company{name: "Approval Co", slug: "approval-co"})
    issue = Repo.insert!(%Issue{title: "Approval issue", company_id: company.id})

    case_row =
      Repo.insert!(
        RecoveryCase.changeset(%RecoveryCase{}, %{
          company_id: company.id,
          issue_id: issue.id,
          source_type: "issue_checkout",
          source_id: issue.id,
          source_status: "in_progress",
          source_fingerprint: String.duplicate("d", 64)
        })
      )

    changeset =
      Cympho.BoardApprovals.BoardApproval.changeset(%Cympho.BoardApprovals.BoardApproval{}, %{
        title: "Retry",
        category: "stranded_work_recovery",
        company_id: company.id,
        recovery_case_id: case_row.id
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :recovery_case_id) == case_row.id
  end

  test "creation changeset ignores lease and result timestamps" do
    now = DateTime.utc_now()

    changeset =
      RecoveryCase.changeset(%RecoveryCase{}, %{
        claim_token: Ecto.UUID.generate(),
        claimed_at: now,
        lease_expires_at: now,
        recovered_at: now,
        exhausted_at: now,
        escalated_at: now,
        resolved_at: now,
        last_attempt_at: now
      })

    refute Map.has_key?(changeset.changes, :claim_token)
    refute Map.has_key?(changeset.changes, :claimed_at)
    refute Map.has_key?(changeset.changes, :recovered_at)
    refute Map.has_key?(changeset.changes, :escalated_at)
    refute Map.has_key?(changeset.changes, :last_attempt_at)
    refute Map.has_key?(changeset.changes, :lease_expires_at)
    refute Map.has_key?(changeset.changes, :exhausted_at)
    refute Map.has_key?(changeset.changes, :resolved_at)
  end
end

# Lifecycle facade coverage

defmodule Cympho.RecoveryLifecycleTest do
  use Cympho.DataCase, async: false
  alias Cympho.Repo
  alias Cympho.Companies.Company
  alias Cympho.Issues.Issue
  alias Cympho.Recovery

  test "ensure_case deduplicates and leases a checkout" do
    company = Repo.insert!(%Company{name: "Lifecycle Co", slug: "lifecycle-co"})

    issue =
      Repo.insert!(%Issue{
        title: "Stranded",
        company_id: company.id,
        status: :in_progress,
        lock_version: 0
      })

    assert {:ok, first} = Recovery.ensure_case(%{source_type: "issue_checkout", issue: issue})
    assert {:ok, same} = Recovery.ensure_case(%{source_type: "issue_checkout", issue: issue})
    assert same.id == first.id
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    assert {:ok, lease} = Recovery.claim_case(first, now: now)
    assert {:error, :already_claimed} = Recovery.claim_case(first, now: now)
    assert {:ok, failed} = Recovery.record_failure(lease, "temporary", now: now)
    assert failed.state == "scheduled"
  end

  test "changed lock version supersedes prior lineage and tenant scope is required" do
    company = Repo.insert!(%Company{name: "Lineage Co", slug: "lineage-co"})

    issue =
      Repo.insert!(%Issue{
        title: "Lineage",
        company_id: company.id,
        status: :in_progress,
        lock_version: 1
      })

    assert {:ok, first} = Recovery.ensure_case(%{source_type: "issue_checkout", issue: issue})
    Repo.update_all(Ecto.Query.from(i in Issue, where: i.id == ^issue.id), set: [lock_version: 2])
    changed = Repo.get!(Issue, issue.id)
    assert {:ok, child} = Recovery.ensure_case(%{source_type: "issue_checkout", issue: changed})
    assert child.id != first.id
    assert child.parent_case_id == first.id
    assert child.root_case_id == first.id
    assert Repo.get!(Cympho.Recovery.RecoveryCase, first.id).state == "superseded"

    assert {:error, :company_scope_required} =
             Recovery.ensure_case(%{
               source_type: "issue_checkout",
               issue: %{changed | company_id: nil}
             })
  end
end

defmodule Cympho.RecoveryReviewFixTest do
  use Cympho.DataCase, async: false
  alias Cympho.Repo
  alias Cympho.Companies.Company
  alias Cympho.Issues.Issue
  alias Cympho.Recovery
  alias Cympho.Recovery.RecoveryCase
  alias Cympho.Recovery.RecoveryAttempt

  test "callback exceptions are recorded without leaking lease" do
    company = Repo.insert!(%Company{name: "Exception Co", slug: "exception-co"})
    issue = Repo.insert!(%Issue{title: "Oops", company_id: company.id})
    source = %{source_type: "issue_checkout", issue: issue}

    assert {:ok, %{outcome: :scheduled}} =
             Recovery.with_attempt(source, [base_delay: 1], fn _ -> raise "password=secret" end)

    row = Repo.one!(Ecto.Query.from(c in RecoveryCase, where: c.issue_id == ^issue.id))
    assert row.state == "scheduled"
    refute row.last_error =~ "secret"
  end

  test "string-key source maps and custom max attempts work" do
    company = Repo.insert!(%Company{name: "Map Co", slug: "map-co"})
    issue = Repo.insert!(%Issue{title: "Map", company_id: company.id})

    run = %{
      "id" => Ecto.UUID.generate(),
      "company_id" => company.id,
      "issue_id" => issue.id,
      "agent_id" => nil,
      "status" => "running",
      "inserted_at" => ~U[2026-01-01 00:00:00Z],
      "error_reason" => "temporary"
    }

    assert {:ok, case_row} =
             Recovery.ensure_case(%{
               "source_type" => "heartbeat_run",
               "issue" => Map.from_struct(issue),
               "run" => run,
               "max_attempts" => 2
             })

    assert {:ok, lease} =
             Recovery.claim_case(case_row, now: DateTime.utc_now() |> DateTime.truncate(:second))

    assert {:ok, failed} =
             Recovery.record_failure(lease, {:provider, "secret-token"},
               base_delay: 1,
               max_delay: 2
             )

    assert failed.state == "scheduled"
    assert failed.next_attempt_at != nil
  end

  test "completion rejects forged or mismatched leases without changing durable rows" do
    company = Repo.insert!(%Company{name: "CAS Co", slug: "cas-co"})
    issue = Repo.insert!(%Issue{title: "CAS", company_id: company.id})
    now = ~U[2026-01-01 00:00:00Z]

    assert {:ok, case_row} = Recovery.ensure_case(%{source_type: "issue_checkout", issue: issue})
    assert {:ok, lease} = Recovery.claim_case(case_row, now: now)

    case_struct = %RecoveryCase{} = lease.case
    attempt_struct = %RecoveryAttempt{} = lease.attempt

    scenarios = [
      {:forged_token, %{lease | token: Ecto.UUID.generate()}},
      {:mismatched_case, %{lease | case: %{case_struct | id: Ecto.UUID.generate()}}},
      {:nonexistent_attempt, %{lease | attempt: %{attempt_struct | id: Ecto.UUID.generate()}}},
      {:mismatched_attempt_number,
       %{
         lease
         | attempt: %{attempt_struct | attempt_no: attempt_struct.attempt_no + 1}
       }}
    ]

    for complete <- [&Recovery.record_success/2, &Recovery.record_superseded/2],
        {_label, forged_lease} <- scenarios do
      assert {:error, :stale_claim} = complete.(forged_lease, now: now)
      unchanged_case = Repo.get!(RecoveryCase, case_row.id)
      unchanged_attempt = Repo.get!(RecoveryAttempt, lease.attempt.id)
      assert unchanged_case.state == "claimed"
      assert unchanged_case.claim_token == lease.token
      assert unchanged_attempt.status == "claimed"
      assert unchanged_attempt.completed_at == nil
    end
  end

  test "with_attempt normalizes callback return values" do
    company = Repo.insert!(%Company{name: "Normalization Co", slug: "normalization-co"})
    now = ~U[2026-01-02 00:00:00Z]

    issue_ok = Repo.insert!(%Issue{title: "Tuple", company_id: company.id})

    assert {:ok, %{result: %{value: 1}, outcome: :recovered, case: %{state: "recovered"}}} =
             Recovery.with_attempt(
               %{source_type: "issue_checkout", issue: issue_ok},
               [now: now],
               fn _ -> {:ok, %{value: 1}} end
             )

    issue_bare = Repo.insert!(%Issue{title: "Bare", company_id: company.id})

    assert {:ok, %{result: :done, outcome: :recovered, case: %{state: "recovered"}}} =
             Recovery.with_attempt(
               %{source_type: "issue_checkout", issue: issue_bare},
               [now: now],
               fn _ -> :done end
             )

    issue_superseded = Repo.insert!(%Issue{title: "Superseded", company_id: company.id})

    assert {:ok,
            %{result: {:error, :superseded}, outcome: :superseded, case: %{state: "superseded"}}} =
             Recovery.with_attempt(
               %{source_type: "issue_checkout", issue: issue_superseded},
               [now: now],
               fn _ -> {:error, :superseded} end
             )
  end

  test "failure retry delay is deterministic and capped" do
    company = Repo.insert!(%Company{name: "Delay Co", slug: "delay-co"})
    issue = Repo.insert!(%Issue{title: "Delay", company_id: company.id, lock_version: 0})
    now = ~U[2026-01-03 00:00:00Z]

    assert {:ok, case_row} = Recovery.ensure_case(%{source_type: "issue_checkout", issue: issue})
    assert {:ok, lease_one} = Recovery.claim_case(case_row, now: now)

    assert {:ok, scheduled} =
             Recovery.record_failure(lease_one, :temporary,
               now: now,
               base_delay: 7,
               max_delay: 9
             )

    assert scheduled.next_attempt_at == DateTime.add(now, 7, :second)

    due = scheduled.next_attempt_at
    assert {:ok, lease_two} = Recovery.claim_case(scheduled, now: due)

    assert {:ok, capped} =
             Recovery.record_failure(lease_two, :temporary,
               now: due,
               base_delay: 7,
               max_delay: 9
             )

    assert capped.next_attempt_at == DateTime.add(due, 9, :second)
  end
end

defmodule Cympho.RecoveryMalformedRunTest do
  use Cympho.DataCase, async: false
  alias Cympho.Repo
  alias Cympho.Companies.Company
  alias Cympho.Issues.Issue
  alias Cympho.Recovery
  alias Cympho.Recovery.RecoveryCase

  test "malformed heartbeat run maps return stable errors without inserts" do
    company = Repo.insert!(%Company{name: "Malformed Co", slug: "malformed-co"})
    issue = Repo.insert!(%Issue{title: "Malformed", company_id: company.id})
    run_id = Ecto.UUID.generate()

    atom_run = %{id: run_id, status: "failed", issue_id: issue.id, company_id: company.id}

    string_run = %{
      "id" => run_id,
      "status" => "failed",
      "issue_id" => issue.id,
      "company_id" => company.id
    }

    variants = [
      {Map.delete(atom_run, :id), :invalid_run_source},
      {%{atom_run | id: ""}, :invalid_run_source},
      {Map.delete(atom_run, :status), :invalid_run_source},
      {%{atom_run | status: ""}, :invalid_run_source},
      {Map.delete(atom_run, :issue_id), :company_scope_required},
      {Map.delete(atom_run, :company_id), :company_scope_required},
      {Map.delete(string_run, "id"), :invalid_run_source},
      {%{string_run | "id" => ""}, :invalid_run_source},
      {Map.delete(string_run, "status"), :invalid_run_source},
      {%{string_run | "status" => ""}, :invalid_run_source},
      {Map.delete(string_run, "issue_id"), :company_scope_required},
      {Map.delete(string_run, "company_id"), :company_scope_required}
    ]

    for {run, expected} <- variants do
      before = Repo.aggregate(RecoveryCase, :count, :id)

      assert {:error, ^expected} =
               Recovery.ensure_case(%{source_type: "heartbeat_run", issue: issue, run: run})

      assert Repo.aggregate(RecoveryCase, :count, :id) == before
    end
  end
end

defmodule Cympho.RecoveryAdapterTest do
  use Cympho.DataCase, async: false

  alias Cympho.Agents.Agent
  alias Cympho.Companies.Company
  alias Cympho.HeartbeatEngine
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Recovery
  alias Cympho.Recovery.RecoveryCase
  alias Cympho.Repo

  test "stale run recovery creates a durable recovered case" do
    {company, agent, issue} = recovery_source("stale-run")

    assert {:ok, run} =
             HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: agent.id,
               issue_id: issue.id,
               adapter: "claude_code"
             })

    assert {:ok, started} = HeartbeatEngine.start_run(run)
    stale_at = DateTime.add(DateTime.utc_now(), -20, :minute) |> DateTime.truncate(:second)

    Repo.update_all(from(r in Run, where: r.id == ^started.id),
      set: [last_heartbeat_at: stale_at]
    )

    started = Repo.get!(Run, started.id)

    assert {:ok, %{run: recovered, outcome: :recovered, case: case_row}} =
             Recovery.recover_stale_run(started, now: DateTime.utc_now())

    assert recovered.status == "failed"
    assert case_row.state == "recovered"
    assert case_row.source_run_id == run.id
  end

  test "a terminal run race is recorded as superseded" do
    {company, agent, issue} = recovery_source("run-race")

    assert {:ok, run} =
             HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: agent.id,
               issue_id: issue.id,
               adapter: "claude_code"
             })

    assert {:ok, stale_snapshot} = HeartbeatEngine.start_run(run)
    assert {:ok, completed} = HeartbeatEngine.complete_run(stale_snapshot, %{})

    assert {:ok, %{outcome: :superseded, case: case_row}} =
             Recovery.recover_stale_run(stale_snapshot)

    assert case_row.state == "superseded"
    assert Repo.get!(Run, run.id).status == completed.status
  end

  test "a run fingerprint change after detection is superseded without mutation" do
    {company, agent, issue} = recovery_source("run-fingerprint-race")

    assert {:ok, run} =
             HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: agent.id,
               issue_id: issue.id,
               adapter: "claude_code"
             })

    assert {:ok, stale_snapshot} = HeartbeatEngine.start_run(run)

    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [error_reason: "authentication changed"]
    )

    assert {:ok, %{outcome: :superseded, case: case_row}} =
             Recovery.recover_stale_run(stale_snapshot)

    assert case_row.state == "superseded"
    assert Repo.get!(Run, run.id).status == "running"
  end

  test "a heartbeat refreshed after detection supersedes direct recovery" do
    {company, agent, issue} = recovery_source("run-heartbeat-direct-race")

    assert {:ok, run} =
             HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: agent.id,
               issue_id: issue.id,
               adapter: "claude_code"
             })

    assert {:ok, started} = HeartbeatEngine.start_run(run)
    stale_at = DateTime.add(DateTime.utc_now(), -20, :minute) |> DateTime.truncate(:second)

    Repo.update_all(from(r in Run, where: r.id == ^started.id),
      set: [last_heartbeat_at: stale_at]
    )

    stale = Repo.get!(Run, started.id)

    assert {:ok, case_row} =
             Recovery.ensure_case(%{source_type: "heartbeat_run", issue: issue, run: stale})

    assert {:ok, _} = HeartbeatEngine.record_heartbeat(stale)

    assert {:ok, %{outcome: :superseded, case: superseded}} =
             Recovery.recover_stale_run(stale, now: DateTime.utc_now())

    assert superseded.id == case_row.id
    assert superseded.state == "superseded"
    assert Repo.get!(Run, run.id).status == "running"
    refute Repo.get!(Issue, issue.id).status == :blocked

    refute Repo.exists?(
             from(a in Cympho.BoardApprovals.BoardApproval,
               where: a.recovery_case_id == ^case_row.id
             )
           )
  end

  test "the final run CAS refuses a newly live orchestrator" do
    {company, agent, issue} = recovery_source("run-live-race")

    assert {:ok, run} =
             HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: agent.id,
               issue_id: issue.id,
               adapter: "claude_code"
             })

    assert {:ok, started} = HeartbeatEngine.start_run(run)
    stale_at = DateTime.add(DateTime.utc_now(), -20, :minute) |> DateTime.truncate(:second)

    Repo.update_all(from(r in Run, where: r.id == ^started.id),
      set: [last_heartbeat_at: stale_at]
    )

    started = Repo.get!(Run, started.id)

    assert {:ok, case_row} =
             Recovery.ensure_case(%{source_type: "heartbeat_run", issue: issue, run: started})

    assert {:ok, _} = Registry.register(Cympho.OrchestratorRegistry, issue.id, nil)

    assert {:error, :superseded} =
             HeartbeatEngine.recover_run_if_current(
               started,
               run_guard(case_row, :stale),
               :stale,
               now: DateTime.utc_now()
             )

    assert Repo.get!(Run, run.id).status == "running"
    Registry.unregister(Cympho.OrchestratorRegistry, issue.id)
  end

  test "the final locked run CAS rejects a source younger than fifteen minutes" do
    {company, agent, issue} = recovery_source("run-young-final-cas")

    assert {:ok, run} =
             HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: agent.id,
               issue_id: issue.id,
               adapter: "claude_code"
             })

    assert {:ok, started} = HeartbeatEngine.start_run(run)

    assert {:ok, case_row} =
             Recovery.ensure_case(%{source_type: "heartbeat_run", issue: issue, run: started})

    assert {:error, :superseded} =
             HeartbeatEngine.recover_run_if_current(
               started,
               run_guard(case_row, :stale),
               :stale,
               now: DateTime.add(started.last_heartbeat_at, 14, :minute)
             )

    assert Repo.get!(Run, run.id).status == "running"
  end

  test "a successor checkout is never cleared by an old issue snapshot" do
    {company, agent, issue} = recovery_source("checkout-race")
    assert {:ok, checked_out} = Issues.checkout_issue(issue, agent)

    assert {:ok, successor} =
             HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: agent.id,
               issue_id: issue.id,
               adapter: "claude_code"
             })

    assert {:ok, bound} = Issues.bind_checkout_run(issue.id, agent.id, successor.id)
    assert bound.checkout_run_id == successor.id

    assert {:ok, %{outcome: :superseded, case: case_row}} =
             Recovery.recover_orphaned_issue(checked_out)

    reloaded = Issues.get_issue!(issue.id)
    assert case_row.state == "superseded"
    assert reloaded.status == :in_progress
    assert reloaded.checkout_run_id == successor.id
    assert Repo.get!(Run, successor.id).status == "pending"
  end

  test "an active database run blocks checkout recovery without a live owner" do
    {company, agent, issue} = recovery_source("active-run")
    assert {:ok, checked_out} = Issues.checkout_issue(issue, agent)

    assert {:ok, run} =
             HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: agent.id,
               issue_id: issue.id,
               adapter: "claude_code"
             })

    assert {:ok, %{outcome: :superseded, case: case_row}} =
             Recovery.recover_orphaned_issue(checked_out)

    assert case_row.state == "superseded"
    reloaded = Issues.get_issue!(issue.id)
    assert reloaded.status == :in_progress
    assert reloaded.checkout_run_id == checked_out.checkout_run_id
    assert Repo.get!(Run, run.id).status == "pending"
  end

  test "three callback failures schedule twice and then escalate for board review" do
    {_, _, issue} = recovery_source("exhaustion")
    Repo.update_all(from(i in Issue, where: i.id == ^issue.id), set: [status: :in_progress])
    issue = Repo.get!(Issue, issue.id)
    source = %{source_type: "issue_checkout", issue: issue}
    now = ~U[2026-02-01 00:00:00Z]

    assert {:ok, %{outcome: :scheduled, case: first}} =
             Recovery.with_attempt(source, [now: now, base_delay: 1], fn _ ->
               {:error, :network_failure}
             end)

    assert {:ok, %{outcome: :scheduled, case: second}} =
             Recovery.with_attempt(source, [now: first.next_attempt_at, base_delay: 1], fn _ ->
               raise "temporary callback failure"
             end)

    assert {:ok, %{outcome: :exhausted, case: exhausted}} =
             Recovery.with_attempt(source, [now: second.next_attempt_at, base_delay: 1], fn _ ->
               {:error, :timeout}
             end)

    assert exhausted.state == "escalated"
    assert exhausted.attempt_count == 3
    assert exhausted.last_error == "timeout"
    assert exhausted.escalated_at != nil

    assert Repo.aggregate(
             from(a in Cympho.BoardApprovals.BoardApproval,
               where: a.recovery_case_id == ^exhausted.id
             ),
             :count
           ) == 1
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
      liveness_at: case_row.source_snapshot["liveness_at"],
      recovery_kind: kind
    }
  end

  defp recovery_source(suffix) do
    company =
      Repo.insert!(%Company{
        name: "Recovery adapter #{suffix}",
        slug: "recovery-adapter-#{suffix}-#{System.unique_integer([:positive])}"
      })

    agent =
      Repo.insert!(%Agent{
        name: "agent-#{suffix}",
        role: :engineer,
        status: :idle,
        company_id: company.id
      })

    issue = Repo.insert!(%Issue{title: "Issue #{suffix}", company_id: company.id})
    {company, agent, issue}
  end
end

defmodule Cympho.RecoveryDueTest do
  use Cympho.DataCase, async: false

  alias Cympho.Agents.Agent
  alias Cympho.BoardApprovals.BoardApproval
  alias Cympho.Companies.Company
  alias Cympho.HeartbeatEngine
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue
  alias Cympho.Recovery
  alias Cympho.Recovery.{RecoveryAttempt, RecoveryCase}
  alias Cympho.Repo

  test "process_due consumes a detected checkout without relying on an age scan" do
    {_company, _agent, issue} = due_source("detected")
    {:ok, case_row} = Recovery.ensure_case(%{source_type: "issue_checkout", issue: issue})
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert %{checked: 1, claimed: 1, recovered: 1, failed: 0} =
             Recovery.process_due(now: now, limit: 1)

    assert Repo.get!(Issue, issue.id).status == :todo
    assert Repo.get!(RecoveryCase, case_row.id).state == "recovered"
  end

  test "process_due resumes a persisted scheduled case with its policy snapshot" do
    {_company, _agent, issue} = due_source("scheduled")

    {:ok, case_row} =
      Recovery.ensure_case(%{
        source_type: "issue_checkout",
        issue: issue,
        base_delay: 1,
        max_delay: 2,
        lease_seconds: 3
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, lease} = Recovery.claim_case(case_row, now: now, lease_seconds: 3)
    {:ok, scheduled} = Recovery.record_failure(lease, :network, now: now)

    assert scheduled.next_attempt_at == DateTime.add(now, 1, :second)

    assert %{recovered: 1, failed: 0} =
             Recovery.process_due(now: scheduled.next_attempt_at, limit: 1)

    assert Repo.get!(RecoveryCase, case_row.id).state == "recovered"
  end

  test "process_due supersedes a run whose heartbeat refreshed after detection" do
    {company, agent, issue} = due_source("fresh-heartbeat")

    assert {:ok, run} =
             HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: agent.id,
               issue_id: issue.id,
               adapter: "claude_code"
             })

    assert {:ok, started} = HeartbeatEngine.start_run(run)
    stale_at = DateTime.add(DateTime.utc_now(), -20, :minute) |> DateTime.truncate(:second)

    Repo.update_all(from(r in Run, where: r.id == ^started.id),
      set: [last_heartbeat_at: stale_at]
    )

    stale = Repo.get!(Run, started.id)

    assert {:ok, case_row} =
             Recovery.ensure_case(%{source_type: "heartbeat_run", issue: issue, run: stale})

    assert {:ok, _} = HeartbeatEngine.record_heartbeat(stale)

    assert %{superseded: 1, recovered: 0, failed: 0} =
             Recovery.process_due(now: DateTime.utc_now(), limit: 1)

    assert Repo.get!(Run, run.id).status == "running"
    refute Repo.get!(Issue, issue.id).status == :blocked
    assert Repo.get!(RecoveryCase, case_row.id).state == "superseded"
    refute Repo.get_by(BoardApproval, recovery_case_id: case_row.id)
  end

  test "process_due supersedes a checkout whose liveness changed after detection" do
    {_company, _agent, issue} = due_source("fresh-checkout")
    stale_at = DateTime.add(DateTime.utc_now(), -20, :minute) |> DateTime.truncate(:second)
    Repo.update_all(from(i in Issue, where: i.id == ^issue.id), set: [checked_out_at: stale_at])
    stale = Repo.get!(Issue, issue.id)

    assert {:ok, case_row} =
             Recovery.ensure_case(%{source_type: "issue_checkout", issue: stale})

    fresh_at = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.update_all(from(i in Issue, where: i.id == ^issue.id), set: [checked_out_at: fresh_at])

    assert %{superseded: 1, recovered: 0, failed: 0} =
             Recovery.process_due(now: fresh_at, limit: 1)

    assert Repo.get!(Issue, issue.id).status == :in_progress
    assert Repo.get!(RecoveryCase, case_row.id).state == "superseded"
    refute Repo.get_by(BoardApproval, recovery_case_id: case_row.id)
  end

  test "process_due fails closed for each corrupted run case identity field" do
    for field <- [:company_id, :issue_id, :source_id, :source_run_id, :agent_id] do
      {company, agent, issue} = due_source("corrupt-#{field}")

      other_company =
        Repo.insert!(%Company{name: "Other #{field}", slug: "other-#{field}-#{unique()}"})

      other_agent =
        Repo.insert!(%Agent{
          name: "Other agent #{field}",
          role: :engineer,
          company_id: other_company.id
        })

      other_issue =
        Repo.insert!(%Issue{title: "Other issue #{field}", company_id: other_company.id})

      assert {:ok, run} =
               HeartbeatEngine.create_run(%{
                 company_id: company.id,
                 agent_id: agent.id,
                 issue_id: issue.id,
                 adapter: "claude_code"
               })

      assert {:ok, started} = HeartbeatEngine.start_run(run)
      stale_at = DateTime.add(DateTime.utc_now(), -20, :minute) |> DateTime.truncate(:second)

      Repo.update_all(from(r in Run, where: r.id == ^started.id),
        set: [last_heartbeat_at: stale_at]
      )

      stale = Repo.get!(Run, started.id)

      assert {:ok, other_run} =
               HeartbeatEngine.create_run(%{
                 company_id: other_company.id,
                 agent_id: other_agent.id,
                 issue_id: other_issue.id,
                 adapter: "claude_code"
               })

      assert {:ok, case_row} =
               Recovery.ensure_case(%{source_type: "heartbeat_run", issue: issue, run: stale})

      corrupt_value = %{
        company_id: other_company.id,
        issue_id: other_issue.id,
        source_id: Ecto.UUID.generate(),
        source_run_id: other_run.id,
        agent_id: other_agent.id
      }

      Repo.update_all(from(c in RecoveryCase, where: c.id == ^case_row.id),
        set: [{field, Map.fetch!(corrupt_value, field)}]
      )

      assert %{superseded: 1, recovered: 0, failed: 0} =
               Recovery.process_due(now: DateTime.utc_now(), limit: 1)

      assert Repo.get!(Run, run.id).status == "running"
      refute Repo.get!(Issue, issue.id).status == :blocked
      refute Repo.get_by(BoardApproval, recovery_case_id: case_row.id)
    end
  end

  test "an expired final lease is closed and escalated exactly once" do
    {_company, _agent, issue} = due_source("expired-final")

    {:ok, case_row} =
      Recovery.ensure_case(%{
        source_type: "issue_checkout",
        issue: issue,
        max_attempts: 1,
        lease_seconds: 1
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, _lease} = Recovery.claim_case(case_row, now: now, lease_seconds: 1)
    expired_at = DateTime.add(now, -1, :second)

    Repo.update_all(from(c in RecoveryCase, where: c.id == ^case_row.id),
      set: [lease_expires_at: expired_at]
    )

    assert %{exhausted: 1, failed: 0} = Recovery.process_due(now: now, limit: 1)
    assert Repo.get!(RecoveryCase, case_row.id).state == "escalated"
    assert Repo.get!(Issue, issue.id).status == :blocked
    assert Repo.get_by!(BoardApproval, recovery_case_id: case_row.id).status == "pending"

    assert Repo.get_by!(RecoveryAttempt,
             recovery_case_id: case_row.id,
             attempt_no: 1
           ).status == "failed"
  end

  test "policy and bounded schema inputs fail closed" do
    {company, _agent, issue} = due_source("bounds")

    for attrs <- [
          %{max_attempts: 4},
          %{base_delay: 601},
          %{max_delay: 601},
          %{lease_seconds: 601}
        ] do
      assert {:error, :invalid_policy} =
               Recovery.ensure_case(
                 Map.merge(%{source_type: "issue_checkout", issue: issue}, attrs)
               )
    end

    other = Repo.insert!(%Company{name: "Other bounds", slug: "other-bounds-#{unique()}"})

    invalid =
      RecoveryCase.changeset(%RecoveryCase{}, %{
        company_id: other.id,
        issue_id: issue.id,
        source_type: "issue_checkout",
        source_id: issue.id,
        source_status: "in_progress",
        source_fingerprint: String.duplicate("A", 64),
        fingerprint_version: 0,
        source_snapshot: %{"payload" => String.duplicate("x", 17_000)},
        max_attempts: 4
      })

    refute invalid.valid?
    errors = errors_on(invalid)
    assert errors.source_fingerprint != []
    assert errors.fingerprint_version != []
    assert errors.max_attempts != []
    assert errors.source_snapshot != []

    assert {:error, cross_scope} =
             %RecoveryCase{}
             |> RecoveryCase.changeset(%{
               company_id: other.id,
               issue_id: issue.id,
               source_type: "issue_checkout",
               source_id: issue.id,
               source_status: "in_progress",
               source_fingerprint: String.duplicate("a", 64)
             })
             |> Repo.insert()

    assert errors_on(cross_scope).issue_id != []
    assert company.id == issue.company_id
  end

  defp due_source(suffix) do
    company =
      Repo.insert!(%Company{
        name: "Due #{suffix}",
        slug: "due-#{suffix}-#{unique()}"
      })

    agent =
      Repo.insert!(%Agent{
        name: "Due agent #{suffix}",
        role: :engineer,
        company_id: company.id
      })

    issue =
      Repo.insert!(%Issue{
        title: "Due issue #{suffix}",
        company_id: company.id,
        assignee_id: agent.id,
        status: :in_progress
      })

    {company, agent, issue}
  end

  defp unique, do: System.unique_integer([:positive])
end

defmodule Cympho.RecoveryConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cympho.Companies.Company
  alias Cympho.Issues.Issue
  alias Cympho.Recovery
  alias Cympho.Recovery.RecoveryCase
  alias Cympho.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    unique = System.unique_integer([:positive])
    company = Repo.insert!(%Company{name: "Recovery race", slug: "recovery-race-#{unique}"})

    issue =
      Repo.insert!(%Issue{title: "Recovery race", company_id: company.id, status: :in_progress})

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(c in RecoveryCase, where: c.company_id == ^company.id))
        Repo.delete_all(from(i in Issue, where: i.id == ^issue.id))
        Repo.delete_all(from(c in Company, where: c.id == ^company.id))
      end)
    end)

    %{company: company, issue: issue}
  end

  test "concurrent ensure_case calls deduplicate without raising", %{
    company: company,
    issue: issue
  } do
    caller = self()

    workers =
      for _ <- 1..2 do
        spawn_monitor(fn ->
          Process.delete(:"$callers")
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          send(caller, {:ready, self()})
          receive do: (:go -> :ok)

          result =
            Recovery.ensure_case(%{
              company_id: company.id,
              source_type: "issue_checkout",
              issue: issue
            })

          :ok = Ecto.Adapters.SQL.Sandbox.checkin(Repo)
          send(caller, {:result, self(), result})
        end)
      end

    Enum.each(workers, fn {pid, _ref} -> assert_receive {:ready, ^pid}, 5_000 end)
    Enum.each(workers, fn {pid, _ref} -> send(pid, :go) end)

    ids =
      Enum.map(workers, fn {pid, ref} ->
        assert_receive {:result, ^pid, {:ok, case_row}}, 10_000
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
        case_row.id
      end)

    assert Enum.uniq(ids) |> length() == 1

    assert Repo.aggregate(
             from(c in RecoveryCase,
               where:
                 c.company_id == ^company.id and c.source_type == "issue_checkout" and
                   c.source_id == ^issue.id and c.state in ^RecoveryCase.active_states()
             ),
             :count
           ) == 1
  end
end
