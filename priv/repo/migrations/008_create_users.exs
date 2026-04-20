defmodule Cympho.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :email, :string, null: false
      add :name, :string, null: false
      add :telegram_chat_id, :string
      add :telegram_enabled, :boolean, default: false, null: false
      add :email_enabled, :boolean, default: true, null: false
      add :webhook_enabled, :boolean, default: false, null: false
      add :webhook_url, :string

      timestamps(type: :utc_datetime)
    end

    create index(:users, [:email], unique: true)
    create index(:users, [:telegram_chat_id])
  end
end
