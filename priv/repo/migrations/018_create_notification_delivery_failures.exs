defmodule Cympho.Repo.Migrations.CreateNotificationDeliveryFailures do
  use Ecto.Migration

  def change do
    create table(:notification_delivery_failures, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :channel_type, :string, null: false
      add :payload, :map, default: %{}
      add :attempt, :integer, default: 1, null: false
      add :error_reason, :text
      add :failed_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:notification_delivery_failures, [:user_id])
    create index(:notification_delivery_failures, [:event_type])
    create index(:notification_delivery_failures, [:failed_at])
  end
end