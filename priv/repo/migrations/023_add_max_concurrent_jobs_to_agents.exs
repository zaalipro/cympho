defmodule Cympho.Repo.Migrations.AddMaxConcurrentJobsToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :max_concurrent_jobs, :integer, default: 3, null: false
    end
  end
end