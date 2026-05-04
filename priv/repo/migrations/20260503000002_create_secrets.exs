defmodule Cympho.Repo.Migrations.CreateSecrets do
  use Ecto.Migration

  def change do
    create table(:secrets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :scope, :string, null: false
      add :scope_id, :binary_id
      add :key, :string, null: false
      add :encrypted_value, :binary, null: false
      add :version, :integer, null: false, default: 1
      add :description, :text
      add :is_active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:secrets, [:company_id, :scope, :scope_id])
    create index(:secrets, [:company_id, :key])
    create unique_index(:secrets, [:company_id, :scope, :scope_id, :key, :version])
  end
end
