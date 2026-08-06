defmodule Cympho.Repo.Migrations.CreateEvaluationTables do
  use Ecto.Migration

  def change do
    create table(:evaluation_suites, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :identifier, :string, null: false
      add :description, :text

      # prompt_contract | custom
      add :kind, :string, null: false, default: "prompt_contract"
      add :role, :string

      # Deterministic fixture cases (empty for prompt_contract role suites)
      add :cases, :map, null: false, default: %{}
      add :config, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:evaluation_suites, [:company_id, :identifier])
    create index(:evaluation_suites, [:company_id])
    create index(:evaluation_suites, [:company_id, :kind])

    create table(:evaluation_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :suite_id, references(:evaluation_suites, type: :binary_id, on_delete: :delete_all),
        null: false

      # pending | running | completed | failed
      add :status, :string, null: false, default: "pending"
      # manual | rerun | scheduled
      add :trigger, :string, null: false, default: "manual"

      add :parent_run_id, references(:evaluation_runs, type: :binary_id, on_delete: :nilify_all)

      # Immutable redacted provenance: model/prompt/skill hashes, suite hash, runtime
      add :provenance, :map, null: false, default: %{}
      add :summary, :map, null: false, default: %{}
      add :redacted_metadata, :map, null: false, default: %{}

      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:evaluation_runs, [:company_id])
    create index(:evaluation_runs, [:company_id, :suite_id])
    create index(:evaluation_runs, [:company_id, :status])
    create index(:evaluation_runs, [:parent_run_id])
    create index(:evaluation_runs, [:suite_id, :inserted_at])

    create table(:evaluation_results, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:evaluation_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :suite_id, references(:evaluation_suites, type: :binary_id, on_delete: :delete_all),
        null: false

      add :case_key, :string, null: false
      add :case_label, :string
      add :kind, :string
      add :expectation, :string
      add :passed, :boolean, null: false, default: false
      add :audit_status, :string
      add :audit_summary, :text
      add :gap_fields, {:array, :string}, null: false, default: []
      add :validated_fields, {:array, :string}, null: false, default: []
      add :redacted_trace, :map, null: false, default: %{}
      add :score, :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:evaluation_results, [:company_id])
    create index(:evaluation_results, [:run_id])
    create unique_index(:evaluation_results, [:run_id, :case_key])
    create index(:evaluation_results, [:suite_id, :case_key])

    create table(:evaluation_feedback, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:evaluation_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :result_id, references(:evaluation_results, type: :binary_id, on_delete: :nilify_all)

      # agree | disagree | neutral
      add :vote, :string, null: false
      add :reason, :text
      add :actor_type, :string, null: false, default: "user"
      add :actor_id, :binary_id

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:evaluation_feedback, [:company_id])
    create index(:evaluation_feedback, [:run_id])
    create index(:evaluation_feedback, [:result_id])
    create index(:evaluation_feedback, [:company_id, :run_id, :inserted_at])
  end
end
