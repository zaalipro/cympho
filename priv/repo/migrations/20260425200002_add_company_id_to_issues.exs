defmodule Cympho.Repo.Migrations.AddCompanyIdToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all)
    end

    create index(:issues, [:company_id])
  end
end
