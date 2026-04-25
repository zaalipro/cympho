defmodule Cympho.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  def change do
    create table(:skills, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :identifier, :string, null: false
      add :name, :string, null: false
      add :description, :text
      add :version, :string
      add :author, :string
      add :manifest, :map, null: false, default: %{}
      add :enabled, :boolean, default: true, null: false
      add :settings, :map, default: %{}
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all)
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:skills, [:identifier])
    create index(:skills, [:company_id])
    create index(:skills, [:project_id])
    create unique_index(:skills, [:identifier, :company_id])
  end
end
