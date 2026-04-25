defmodule Cympho.Repo.Migrations.AddAuthenticationToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :password_hash, :string
      add :company_id, references(:companies, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:users, [:company_id])
  end
end
