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
             %RecoveryCase{} |> RecoveryCase.changeset(%{attrs | state: "bogus"}) |> Repo.insert()

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
             |> RecoveryCase.changeset(%{attrs | state: "superseded"})
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

    assert "has already been taken" in errors_on(dup).attempt_no

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
        resolved_at: now
      })

    refute Map.has_key?(changeset.changes, :claim_token)
    refute Map.has_key?(changeset.changes, :claimed_at)
    refute Map.has_key?(changeset.changes, :recovered_at)
    refute Map.has_key?(changeset.changes, :lease_expires_at)
    refute Map.has_key?(changeset.changes, :exhausted_at)
    refute Map.has_key?(changeset.changes, :resolved_at)
  end
end
