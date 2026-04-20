defmodule Cympho.Repo.Migrations.AddAssigneeToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :assignee, :string, null: true
    end

    create index(:issues, [:assignee])
  end
end