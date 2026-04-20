defmodule Cympho.Repo.Migrations.AddProjectIdToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all), null: true
    end

    create index(:agents, [:project_id])
  end
end