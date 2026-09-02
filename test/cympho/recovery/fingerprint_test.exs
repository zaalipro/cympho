defmodule Cympho.Recovery.FingerprintTest do
  use Cympho.DataCase, async: false
  alias Cympho.Recovery.Fingerprint
  alias Cympho.Companies.Company
  alias Cympho.Issues.Issue
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Repo

  test "issue checkout fingerprint is stable and redacted" do
    company = Repo.insert!(%Company{name: "Fingerprint Co", slug: "fp-co"})

    issue =
      Repo.insert!(%Issue{
        title: "Checkout",
        company_id: company.id,
        status: :in_progress,
        lock_version: 2
      })

    assert {first_hash, first_snapshot} = Fingerprint.for_issue_checkout(issue)
    assert {^first_hash, ^first_snapshot} = Fingerprint.for_issue_checkout(issue)
    refute inspect(first_snapshot) =~ "secret"
    assert first_snapshot["issue_id"] == issue.id
  end

  test "run fingerprint changes with durable source state and excludes prompt metadata" do
    company = Repo.insert!(%Company{name: "Run FP Co", slug: "run-fp-co"})
    issue = Repo.insert!(%Issue{title: "Run", company_id: company.id, lock_version: 1})

    run =
      Repo.insert!(%Run{
        company_id: company.id,
        issue_id: issue.id,
        status: "failed",
        error_reason: "provider secret=abc"
      })

    {hash, snapshot} = Fingerprint.for_run(run, issue)
    refute inspect(snapshot) =~ "secret=abc"
    assert snapshot["run_id"] == run.id
    assert is_binary(hash) and byte_size(hash) == 64
    {hash2, _} = Fingerprint.for_run(%{run | status: "completed"}, issue)
    refute hash == hash2
  end
end
