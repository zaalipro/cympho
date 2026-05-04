defmodule Cympho.Repo.Migrations.CreatePluginLogs do
  use Ecto.Migration

  def change do
    create table(:plugin_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :plugin_id, references(:plugins, type: :binary_id, on_delete: :delete_all), null: false
      add :level, :string, default: "info", null: false
      add :message, :string, null: false
      add :metadata, :map, default: %{}
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all)
      add :timestamp, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:plugin_logs, [:plugin_id])
    create index(:plugin_logs, [:company_id])
    create index(:plugin_logs, [:timestamp])
    create index(:plugin_logs, [:level])
  end
end
