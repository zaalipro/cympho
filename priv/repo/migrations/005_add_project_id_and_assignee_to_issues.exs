defmodule Cympho.Repo.Migrations.AddProjectIdAndAssigneeToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all), null: true
      add :assignee, :string, null: true
    end

    create index(:issues, [:project_id])
    create index(:issues, [:assignee])
  end
end
