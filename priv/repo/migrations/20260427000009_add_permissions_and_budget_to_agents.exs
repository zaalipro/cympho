defmodule Cympho.Repo.Migrations.AddPermissionsAndBudgetToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add_if_not_exists :permissions, :map, default: %{}
      add_if_not_exists :budget, :map, default: %{}
    end
  end
end
