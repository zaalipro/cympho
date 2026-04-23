defmodule Cympho.Repo.Migrations.AddParentIdToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :parent_id, references(:issues, type: :binary_id, on_delete: :nilify)
    end

    create index(:issues, [:parent_id])
  end
end
