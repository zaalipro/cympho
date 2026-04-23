defmodule Cympho.Repo.Migrations.AddUniqueConstraintToIssueBlockers do
  use Ecto.Migration

  def change do
    create unique_index(:issue_blockers, [:blocking_issue_id, :blocked_issue_id],
             name: :issue_blockers_unique_blocker)
  end
end