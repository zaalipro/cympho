defmodule Cympho.Repo.Migrations.ExpandAgentStatusesAddHeartbeat do
  use Ecto.Migration

  def up do
    alter table(:agents) do
      modify :status, :string, default: "idle"
      add :last_heartbeat_at, :utc_datetime
    end
  end

  def down do
    alter table(:agents) do
      remove :last_heartbeat_at
    end

    execute "UPDATE agents SET status = 'idle' WHERE status NOT IN ('idle', 'running', 'error')"

    alter table(:agents) do
      modify :status, :string, default: "idle"
    end
  end
end
