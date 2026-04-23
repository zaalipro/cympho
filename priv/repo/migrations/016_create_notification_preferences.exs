defmodule Cympho.Repo.Migrations.CreateNotificationPreferences do
  use Ecto.Migration

  def change do
    create table(:notification_preferences, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :channel_type, :string, null: false
      add :enabled, :boolean, default: true, null: false
      add :config, :map, default: %{}, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:notification_preferences, [:user_id])
    create index(:notification_preferences, [:channel_type])
    create unique_index(:notification_preferences, [:user_id, :channel_type])
  end
end