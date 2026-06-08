defmodule Cympho.Repo.Migrations.AddDueOnToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :due_on, :date
    end
  end
end
