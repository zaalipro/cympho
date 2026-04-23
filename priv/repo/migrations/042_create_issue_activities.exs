defmodule Cympho.Repo.Migrations.CreateIssueActivities do
  use Ecto.Migration
  def change do
    create table(:issue_activities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false
      add :actor_type, :string, null: false
      add :actor_id, :string
      add :action, :string, null: false
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime, updated_at: false)
    end
    create index(:issue_activities, [:issue_id, :inserted_at])
    create index(:issue_activities, [:action])
  end
end
