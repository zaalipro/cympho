defmodule Cympho.Repo.Migrations.AddNoProgressFailureCountToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :no_progress_failure_count, :integer, default: 0, null: false
    end
  end
end
