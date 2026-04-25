defmodule Cympho.Repo.Migrations.CreateIssueThreadInteractions do
  use Ecto.Migration

  def change do
    create table(:issue_thread_interactions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :payload, :map, default: %{}
      add :status, :string, default: "pending", null: false

      add :created_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :resolved_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:issue_thread_interactions, [:issue_id])
    create index(:issue_thread_interactions, [:created_by_agent_id])
    create index(:issue_thread_interactions, [:status])
    create index(:issue_thread_interactions, [:issue_id, :status])
  end
end
