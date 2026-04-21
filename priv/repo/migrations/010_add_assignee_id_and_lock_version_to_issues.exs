defmodule Cympho.Repo.Migrations.AddAssigneeIdAndLockVersionToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :assignee_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :lock_version, :integer, default: 0, null: false
    end

    create index(:issues, [:assignee_id])
  end
end