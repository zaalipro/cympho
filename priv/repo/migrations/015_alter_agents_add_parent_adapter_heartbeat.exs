defmodule Cympho.Repo.Migrations.AlterAgentsAddParentAdapterHeartbeat do
  use Ecto.Migration

  def change do
    alter table(:agents, primary_key: false) do
      add :parent_id, references(:agents, type: :binary_id, on_delete: :nilify_all), null: true
      add :adapter, :string, null: true
      add :heartbeat_config, :map, default: %{}, null: false
    end

    create index(:agents, [:parent_id])
  end
end