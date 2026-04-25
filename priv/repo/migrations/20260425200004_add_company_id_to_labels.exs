defmodule Cympho.Repo.Migrations.AddCompanyIdToLabels do
  use Ecto.Migration

  def change do
    alter table(:labels) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all)
    end

    create index(:labels, [:company_id])
  end
end
