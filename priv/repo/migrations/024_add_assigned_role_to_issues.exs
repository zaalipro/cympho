defmodule Cympho.Repo.Migrations.AddAssignedRoleToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :assigned_role, :string
    end
  end
end
