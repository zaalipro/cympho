defmodule Cympho.Repo.Migrations.AddCompanyIdToGoals do
  use Ecto.Migration

  def change do
    alter table(:goals) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all)
    end

    create index(:goals, [:company_id])
  end
end
