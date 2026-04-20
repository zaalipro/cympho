defmodule Cympho.Repo.Migrations.AddProjectIdToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all), null: true
    end

    create index(:issues, [:project_id])
  end
end