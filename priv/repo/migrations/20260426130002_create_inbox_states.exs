defmodule Cympho.Repo.Migrations.CreateInboxStates do
  use Ecto.Migration

  def change do
    create table(:inbox_states, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status, :string, default: "unread", null: false
      add :dismissed_at, :utc_datetime
      add :archived_at, :utc_datetime
      add :read_at, :utc_datetime
      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:inbox_states, [:issue_id, :agent_id], name: :inbox_states_issue_id_agent_id_index)
    create index(:inbox_states, [:agent_id])
    create index(:inbox_states, [:status])
  end
end
