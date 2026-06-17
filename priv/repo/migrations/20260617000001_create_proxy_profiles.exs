defmodule Cympho.Repo.Migrations.CreateProxyProfiles do
  use Ecto.Migration

  def change do
    create table(:proxy_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :proxy_type, :string, null: false
      add :host, :string, null: false
      add :port, :integer, null: false
      add :username, :string
      add :encrypted_password, :binary
      add :description, :text
      add :is_active, :boolean, null: false, default: true
      add :last_status, :string, null: false, default: "untested"
      add :last_ping_ms, :integer
      add :last_checked_at, :utc_datetime
      add :last_error, :text

      timestamps(type: :utc_datetime)
    end

    create index(:proxy_profiles, [:company_id, :is_active])
    create unique_index(:proxy_profiles, [:company_id, :name], where: "is_active = true")
  end
end
