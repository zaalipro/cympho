defmodule Cympho.Repo.Migrations.AddIdentifierAndBillingCodeToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :identifier, :string
      add :billing_code, :string
    end

    create unique_index(:issues, [:project_id, :identifier],
             name: :issues_project_id_identifier_index,
             where: "identifier IS NOT NULL"
           )

    create index(:issues, [:billing_code])
  end
end
