defmodule Cympho.Repo.Migrations.AddGoalHierarchyAndIssueGoalLink do
  use Ecto.Migration

  def change do
    alter table(:goals) do
      add :parent_id, references(:goals, type: :binary_id, on_delete: :nilify_null)
    end

    create index(:goals, [:parent_id])
    create index(:goals, [:company_id])

    alter table(:issues) do
      add :goal_id, references(:goals, type: :binary_id, on_delete: :nilify_null)
    end

    create index(:issues, [:goal_id])
  end
end
