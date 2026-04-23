defmodule Cympho.Repo.Migrations.CreateApprovals do
  use Ecto.Migration

  def change do
    create table(:approvals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :payload, :map
      add :resolution_reason, :text

      add :requested_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :resolved_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:approvals, [:status])
    create index(:approvals, [:requested_by_agent_id])

    create table(:approval_issues, primary_key: false) do
      add :approval_id, references(:approvals, type: :binary_id, on_delete: :delete_all), null: false
      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false
    end

    create unique_index(:approval_issues, [:approval_id, :issue_id])
    create index(:approval_issues, [:issue_id])
  end
end
