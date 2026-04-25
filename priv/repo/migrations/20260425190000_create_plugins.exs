defmodule Cympho.Repo.Migrations.CreatePlugins do
  use Ecto.Migration

  def change do
    create table(:plugins, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :identifier, :string, null: false
      add :version, :string, null: false
      add :name, :string, null: false
      add :description, :string
      add :author, :string
      add :manifest, :map, null: false
      add :status, :string, default: "installed", null: false
      add :capabilities, {:array, :string}, default: []
      add :enabled, :boolean, default: true
      add :settings, :map, default: %{}
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all)
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:plugins, [:identifier])
    create index(:plugins, [:company_id])
    create index(:plugins, [:project_id])
    create index(:plugins, [:status])
    create unique_index(:plugins, [:identifier, :company_id])
  end
end
