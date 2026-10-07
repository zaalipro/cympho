defmodule Cympho.Repo.Migrations.AddHumanReviewerToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :last_human_reviewer_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
