defmodule Cympho.Repo.Migrations.AddLogoToCompanies do
  use Ecto.Migration

  def change do
    alter table(:companies) do
      add :logo_url, :string
    end
  end
end
