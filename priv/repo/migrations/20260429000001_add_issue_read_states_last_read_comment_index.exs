defmodule Cympho.Repo.Migrations.AddIssueReadStatesLastReadCommentIndex do
  use Ecto.Migration

  def change do
    create index(:issue_read_states, [:issue_id, :last_read_comment_id])
  end
end