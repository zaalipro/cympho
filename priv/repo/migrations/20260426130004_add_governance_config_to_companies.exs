defmodule Cympho.Repo.Migrations.AddGovernanceConfigToCompanies do
  use Ecto.Migration

  def change do
    alter table(:companies) do
      add :governance_config, :map, default: %{}
    end
  end
end
