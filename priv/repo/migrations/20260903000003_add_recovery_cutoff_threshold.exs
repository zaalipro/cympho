defmodule Cympho.Repo.Migrations.AddRecoveryCutoffThreshold do
  use Ecto.Migration

  def change do
    alter table(:recovery_cases) do
      add :stale_threshold_minutes, :integer, null: false, default: 15
    end

    create constraint(:recovery_cases, :recovery_cases_stale_threshold_check,
             check: "stale_threshold_minutes > 0"
           )
  end
end
