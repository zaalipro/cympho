defmodule Cympho.Repo.Migrations.AddInstructionsPathToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :instructions_path, :string, null: true
    end
  end
end
