defmodule Cympho.Repo.Migrations.HardenRecoveryInvariants do
  use Ecto.Migration

  def up do
    alter table(:recovery_cases) do
      add :policy_snapshot, :map, null: false, default: %{}
    end

    # The active index is the claim mutex; this historical index makes source
    # identity/fingerprint lookups deterministic without preventing a new
    # fingerprint after a source state transition.
    create unique_index(
             :recovery_cases,
             [:company_id, :source_type, :source_id, :source_fingerprint],
             name: :recovery_cases_source_history_index
           )

    create index(:recovery_cases, [:company_id, :source_type, :source_id],
             name: :recovery_cases_source_identity_index
           )

    create constraint(:recovery_cases, :recovery_cases_fingerprint_format_check,
             check: "source_fingerprint ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:recovery_cases, :recovery_cases_fingerprint_version_check,
             check: "fingerprint_version > 0"
           )

    create constraint(:recovery_cases, :recovery_cases_policy_attempts_check,
             check: "max_attempts > 0 AND max_attempts <= 3"
           )

    create constraint(:recovery_cases, :recovery_cases_snapshot_size_check,
             check: "octet_length(source_snapshot::text) <= 16384"
           )

    create constraint(:recovery_cases, :recovery_cases_policy_size_check,
             check: "octet_length(policy_snapshot::text) <= 4096"
           )

    create constraint(:recovery_attempts, :recovery_attempts_status_check,
             check: "status IN ('claimed','succeeded','failed','skipped')"
           )

    create constraint(:recovery_attempts, :recovery_attempts_number_check,
             check: "attempt_no > 0"
           )

    create constraint(:recovery_attempts, :recovery_attempts_fingerprint_check,
             check: "source_fingerprint ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:recovery_attempts, :recovery_attempts_metadata_size_check,
             check: "octet_length(metadata::text) <= 8192"
           )

    create constraint(:board_approvals, :board_approvals_recovery_category_check,
             check: "recovery_case_id IS NULL OR category = 'stranded_work_recovery'"
           )
  end

  def down do
    drop constraint(:board_approvals, :board_approvals_recovery_category_check)
    drop constraint(:recovery_attempts, :recovery_attempts_metadata_size_check)
    drop constraint(:recovery_attempts, :recovery_attempts_fingerprint_check)
    drop constraint(:recovery_attempts, :recovery_attempts_number_check)
    drop constraint(:recovery_attempts, :recovery_attempts_status_check)
    drop constraint(:recovery_cases, :recovery_cases_policy_size_check)
    drop constraint(:recovery_cases, :recovery_cases_snapshot_size_check)
    drop constraint(:recovery_cases, :recovery_cases_policy_attempts_check)
    drop constraint(:recovery_cases, :recovery_cases_fingerprint_version_check)
    drop constraint(:recovery_cases, :recovery_cases_fingerprint_format_check)

    drop index(:recovery_cases, [:company_id, :source_type, :source_id],
           name: :recovery_cases_source_identity_index
         )

    drop index(:recovery_cases, [:company_id, :source_type, :source_id, :source_fingerprint],
           name: :recovery_cases_source_history_index
         )

    alter table(:recovery_cases) do
      remove :policy_snapshot
    end
  end
end
