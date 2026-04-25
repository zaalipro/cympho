defmodule Cympho.Repo.Migrations.CreateCompanyInvites do
  use Ecto.Migration

  def change do
    create table(:company_invites, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :inviter_id, references(:users, type: :binary_id, on_delete: :nilify_all), null: false
      add :email, :string, null: false
      add :role, :string, null: false, default: "member"
      add :token, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:company_invites, [:company_id])
    create index(:company_invites, [:token], unique: true)
    create index(:company_invites, [:email])
    create index(:company_invites, [:status])
  end
end
