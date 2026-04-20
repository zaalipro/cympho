defmodule Cympho.Repo.Migrations.CreateIssueBlockers do
  use Ecto.Migration

  def change do
    create table(:issue_blockers, primary_key: {:blocked_issue_id, :blocking_issue_id}) do
      add :blocked_issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false
      add :blocking_issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:issue_blockers, [:blocked_issue_id])
    create index(:issue_blockers, [:blocking_issue_id])

    create constraint(:issue_blockers, :no_self_block,
             check: "blocked_issue_id != blocking_issue_id")
  end
end