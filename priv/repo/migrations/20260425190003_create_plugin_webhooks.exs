defmodule Cympho.Repo.Migrations.CreatePluginWebhooks do
  use Ecto.Migration

  def change do
    create table(:plugin_webhooks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :plugin_id, references(:plugins, type: :binary_id, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :url, :string, null: false
      add :secret, :string
      add :enabled, :boolean, default: true
      add :last_triggered_at, :utc_datetime
      add :failure_count, :integer, default: 0
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:plugin_webhooks, [:plugin_id])
    create index(:plugin_webhooks, [:company_id])
    create index(:plugin_webhooks, [:event_type])
    create index(:plugin_webhooks, [:enabled])
  end
end
