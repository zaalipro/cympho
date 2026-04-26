defmodule Cympho.Repo.Migrations.AddHealthStatusToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add_if_not_exists :health_status, :string, default: "healthy"
    end
  end
end
