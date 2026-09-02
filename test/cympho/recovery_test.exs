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
end
