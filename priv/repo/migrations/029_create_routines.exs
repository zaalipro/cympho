defmodule Cympho.Repo.Migrations.CreateRoutines do
  use Ecto.Migration

  def change do
    create table(:routines, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :name, :string, null: false
      add :description, :text, default: ""
      add :status, :string, default: "active", null: false
      add :concurrency_policy, :string, default: "coalesce_if_active", null: false
      add :catch_up_policy, :string, default: "skip_missed", null: false
      add :priority, :string, default: "medium", null: false

      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:routines, [:agent_id])
    create index(:routines, [:project_id])
    create index(:routines, [:status])
  end
end
