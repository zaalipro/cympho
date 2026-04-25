defmodule Cympho.Repo.Migrations.CreateCompanyMemberships do
  use Ecto.Migration

  def change do
    create table(:company_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:company_memberships, [:user_id])
    create index(:company_memberships, [:company_id])
    create unique_index(:company_memberships, [:user_id, :company_id])
  end
end
