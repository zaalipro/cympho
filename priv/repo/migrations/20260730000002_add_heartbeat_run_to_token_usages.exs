defmodule Cympho.Repo.Migrations.AddHeartbeatRunToTokenUsages do
  use Ecto.Migration

  def change do
    alter table(:token_usages) do
      add :heartbeat_run_id,
          references(:heartbeat_runs, type: :binary_id, on_delete: :nilify_all)
    end

    create unique_index(:token_usages, [:heartbeat_run_id], where: "heartbeat_run_id IS NOT NULL")
  end
end
