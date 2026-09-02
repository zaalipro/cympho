defmodule Cympho.Repo.Migrations.CreateRecoveryCases do
  use Ecto.Migration

  def change do
    create table(:recovery_cases, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :restrict), null: false
      add :issue_id, references(:issues, type: :binary_id, on_delete: :restrict), null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :source_type, :string, null: false
      add :source_id, :string, null: false
      add :source_run_id, references(:heartbeat_runs, type: :binary_id, on_delete: :nilify_all)
      add :parent_case_id, references(:recovery_cases, type: :binary_id, on_delete: :nilify_all)
      add :root_case_id, references(:recovery_cases, type: :binary_id, on_delete: :nilify_all)
      add :source_fingerprint, :string, null: false
      add :fingerprint_version, :integer, null: false, default: 1
      add :source_snapshot, :map, null: false, default: %{}
      add :source_status, :string, null: false
      add :state, :string, null: false, default: "detected"
      add :attempt_count, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 3
      add :next_attempt_at, :utc_datetime
      add :claim_token, :uuid
      add :claimed_at, :utc_datetime
      add :lease_expires_at, :utc_datetime
      add :claimed_by, :string
      add :last_error, :text
      add :last_attempt_at, :utc_datetime
      add :recovered_at, :utc_datetime
      add :exhausted_at, :utc_datetime
      add :escalated_at, :utc_datetime
      add :resolved_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create table(:recovery_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :recovery_case_id,
          references(:recovery_cases, type: :binary_id, on_delete: :delete_all), null: false

      add :attempt_no, :integer, null: false
      add :status, :string, null: false, default: "claimed"
      add :action, :string, null: false
      add :source_fingerprint, :string, null: false
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :next_retry_at, :utc_datetime
      add :error_reason, :text
      add :node, :string
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    alter table(:board_approvals) do
      add :recovery_case_id, references(:recovery_cases, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:recovery_cases, [:company_id, :state, :next_attempt_at])
    create index(:recovery_cases, [:state, :lease_expires_at])
    create index(:recovery_cases, [:issue_id, :state])
    create index(:recovery_cases, [:root_case_id])
    create index(:recovery_attempts, [:recovery_case_id, :inserted_at])
    create index(:recovery_attempts, [:status, :next_retry_at])
    create unique_index(:recovery_attempts, [:recovery_case_id, :attempt_no])

    create unique_index(:recovery_cases, [:company_id, :source_type, :source_id],
             where: "state IN ('detected','scheduled','claimed','exhausted','escalated')",
             name: :recovery_cases_active_source_index
           )

    create unique_index(
             :recovery_cases,
             [:company_id, :source_type, :source_id, :source_fingerprint],
             name: :recovery_cases_source_fingerprint_index
           )

    create unique_index(:board_approvals, [:recovery_case_id],
             where: "recovery_case_id IS NOT NULL",
             name: :board_approvals_recovery_case_index
           )

    create constraint(:recovery_cases, :recovery_cases_state_check,
             check:
               "state IN ('detected','scheduled','claimed','recovered','exhausted','escalated','resolved','superseded')"
           )

    create constraint(:recovery_cases, :recovery_cases_source_type_check,
             check: "source_type IN ('heartbeat_run','issue_checkout')"
           )

    create constraint(:recovery_cases, :recovery_cases_attempt_count_check,
             check: "attempt_count >= 0"
           )

    create constraint(:recovery_cases, :recovery_cases_max_attempts_check,
             check: "max_attempts > 0"
           )

    create constraint(:recovery_cases, :recovery_cases_claim_lease_check,
             check:
               "state <> 'claimed' OR (claim_token IS NOT NULL AND claimed_at IS NOT NULL AND lease_expires_at IS NOT NULL)"
           )
  end
end
