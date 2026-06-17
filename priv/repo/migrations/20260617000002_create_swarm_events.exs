defmodule Cympho.Repo.Migrations.CreateSwarmEvents do
  use Ecto.Migration

  def change do
    create table(:swarm_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :parent_issue_id, references(:issues, type: :binary_id, on_delete: :delete_all),
        null: false

      add :issue_id, references(:issues, type: :binary_id, on_delete: :nilify_all)
      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)

      add :event_type, :string, null: false
      add :status, :string, null: false, default: "info"
      add :message, :text, null: false
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:swarm_events, [:company_id, :inserted_at])
    create index(:swarm_events, [:parent_issue_id, :occurred_at])
    create index(:swarm_events, [:issue_id])
    create index(:swarm_events, [:agent_id])
    create index(:swarm_events, [:event_type])

    create constraint(
      :swarm_events,
      :valid_swarm_event_status,
      check: "status IN ('info', 'success', 'warning', 'error')"
    )
  end
end
