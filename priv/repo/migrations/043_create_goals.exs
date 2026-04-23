defmodule Cympho.Repo.Migrations.CreateGoals do
  use Ecto.Migration

  def change do
    create table(:goals, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :title, :string, null: false
      add :description, :text
      add :status, :string, default: "active", null: false
      add :priority, :string, default: "medium", null: false
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:goals, [:status])
    create index(:goals, [:project_id])
  end
end
