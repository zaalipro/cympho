defmodule Cympho.Repo.Migrations.AddLastReviewerIdToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :last_reviewer_id,
          references(:agents, on_delete: :nilify_all, type: :binary_id),
          null: true
    end

    create index(:issues, [:last_reviewer_id])
  end
end
