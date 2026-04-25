defmodule Cympho.Repo.Migrations.CreatePluginStates do
  use Ecto.Migration

  def change do
    create table(:plugin_states, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :plugin_id, references(:plugins, type: :binary_id, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :value, :binary, null: false
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:plugin_states, [:plugin_id])
    create index(:plugin_states, [:company_id])
    create unique_index(:plugin_states, [:plugin_id, :key])
  end
end
