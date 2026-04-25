defmodule Cympho.Repo.Migrations.AddGoalHierarchyAndIssueGoalLink do
  use Ecto.Migration

  def up do
    alter table(:goals) do
      add_if_not_exists :parent_id, references(:goals, type: :binary_id, on_delete: :nilify_all)
    end

    create_if_not_exists index(:goals, [:parent_id])
    create_if_not_exists index(:goals, [:company_id])

    alter table(:issues) do
      add_if_not_exists :goal_id, references(:goals, type: :binary_id, on_delete: :nilify_all)
    end

    create_if_not_exists index(:issues, [:goal_id])
  end

  def down do
    drop_if_exists index(:issues, [:goal_id])

    alter table(:issues) do
      remove_if_exists :goal_id, :binary_id
    end

    drop_if_exists index(:goals, [:company_id])
    drop_if_exists index(:goals, [:parent_id])

    alter table(:goals) do
      remove_if_exists :parent_id, :binary_id
    end
  end
end
