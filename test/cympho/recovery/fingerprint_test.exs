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
    assert Fingerprint.version() == 2
    assert first_snapshot["version"] == 2
    assert first_snapshot["issue_id"] == issue.id
    assert first_snapshot["checkout_liveness_at"] == DateTime.to_iso8601(issue.updated_at)

    checked_out_at = ~U[2026-07-01 10:00:00Z]
    later_update = ~U[2026-07-01 11:00:00Z]

    {_hash, checkout_snapshot} =
      Fingerprint.for_issue_checkout(%{
        issue
        | checked_out_at: checked_out_at,
          updated_at: later_update
      })

    assert checkout_snapshot["checkout_liveness_at"] == DateTime.to_iso8601(checked_out_at)
  end

  test "run fingerprint changes with durable source state and excludes prompt metadata" do
    company = Repo.insert!(%Company{name: "Run FP Co", slug: "run-fp-co"})
    issue = Repo.insert!(%Issue{title: "Run", company_id: company.id, lock_version: 1})

    heartbeat_at = ~U[2026-08-01 12:00:00Z]

    run =
      Repo.insert!(%Run{
        company_id: company.id,
        issue_id: issue.id,
        status: "running",
        last_heartbeat_at: heartbeat_at,
        error_reason: "provider secret=abc"
      })

    {hash, snapshot} = Fingerprint.for_run(run, issue)
    refute inspect(snapshot) =~ "secret=abc"
    assert snapshot["version"] == 2
    assert snapshot["liveness_at"] == DateTime.to_iso8601(heartbeat_at)
    assert snapshot["run_id"] == run.id
    assert is_binary(hash) and byte_size(hash) == 64
    {hash2, _} = Fingerprint.for_run(%{run | status: "completed"}, issue)
    refute hash == hash2
  end

  test "a durable heartbeat changes the run fingerprint" do
    company = Repo.insert!(%Company{name: "Heartbeat FP Co", slug: "heartbeat-fp-co"})
    issue = Repo.insert!(%Issue{title: "Heartbeat", company_id: company.id})

    run =
      Repo.insert!(%Run{
        company_id: company.id,
        issue_id: issue.id,
        status: "running",
        last_heartbeat_at: ~U[2020-01-01 00:00:00Z]
      })

    {old_fingerprint, _snapshot} = Fingerprint.for_run(run, issue)
    assert {:ok, _} = Cympho.HeartbeatEngine.record_heartbeat(run)
    fresh = Repo.get!(Run, run.id)
    {fresh_fingerprint, fresh_snapshot} = Fingerprint.for_run(fresh, issue)

    refute fresh_fingerprint == old_fingerprint
    assert fresh_snapshot["liveness_at"] == DateTime.to_iso8601(fresh.last_heartbeat_at)
  end

  test "pending and queued run fingerprints use insertion time for liveness" do
    inserted_at = ~U[2026-07-02 10:00:00Z]
    heartbeat_at = ~U[2026-07-02 11:00:00Z]

    for status <- ["pending", "queued"] do
      {_hash, snapshot} =
        Fingerprint.for_run(
          %{
            id: Ecto.UUID.generate(),
            company_id: Ecto.UUID.generate(),
            issue_id: Ecto.UUID.generate(),
            agent_id: Ecto.UUID.generate(),
            status: status,
            inserted_at: inserted_at,
            last_heartbeat_at: heartbeat_at
          },
          %{id: Ecto.UUID.generate(), status: :backlog, lock_version: 0}
        )

      assert snapshot["liveness_at"] == DateTime.to_iso8601(inserted_at)
    end
  end
end
