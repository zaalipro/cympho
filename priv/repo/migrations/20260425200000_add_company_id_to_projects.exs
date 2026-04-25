defmodule Cympho.Repo.Migrations.AddCompanyIdToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all)
    end

    create index(:projects, [:company_id])
  end
end
