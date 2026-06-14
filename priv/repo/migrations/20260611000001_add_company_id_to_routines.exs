defmodule Cympho.Repo.Migrations.AddCompanyIdToRoutines do
  use Ecto.Migration

  def change do
    alter table(:routines) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all)
    end

    create index(:routines, [:company_id])
  end
end
