defmodule Cympho.Repo.Migrations.AddAdapterFailureCountToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :adapter_failure_count, :integer, default: 0, null: false
    end
  end
end
