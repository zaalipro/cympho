defmodule Cympho.Repo.Migrations.CreateIssueReadStates do
  use Ecto.Migration

  def change do
    create table(:issue_read_states, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false
      add :last_read_at, :utc_datetime, null: false
      add :last_read_comment_id, references(:comments, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:issue_read_states, [:user_id])
    create index(:issue_read_states, [:issue_id])
    create index(:issue_read_states, [:user_id, :issue_id], unique: true)
  end
end