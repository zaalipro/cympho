defmodule Cympho.Repo.Migrations.CreateTelegramLinks do
  use Ecto.Migration

  def change do
    create table(:telegram_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :telegram_chat_id, :string, null: false
      add :telegram_username, :string
      add :verified, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:telegram_links, [:user_id])
    create index(:telegram_links, [:telegram_chat_id], unique: true)
  end
end