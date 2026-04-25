defmodule Cympho.Repo.Migrations.AddCompanyIdToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all)
    end

    create index(:agents, [:company_id])
  end
end
