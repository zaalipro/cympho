defmodule Cympho.Repo.Migrations.AddGoalTypeAndLineage do
  use Ecto.Migration

  def up do
    alter table(:goals) do
      add :goal_type, :string, default: "initiative", null: false
    end

    create index(:goals, [:goal_type])
    create index(:goals, [:company_id, :goal_type])

    # Root goals (no parent) become missions
    execute "UPDATE goals SET goal_type = 'mission' WHERE parent_id IS NULL"

    # Goals whose parent has a parent are milestones (depth >= 2)
    execute """
      UPDATE goals g SET goal_type = 'milestone'
      WHERE g.parent_id IS NOT NULL
        AND EXISTS (SELECT 1 FROM goals p WHERE p.id = g.parent_id AND p.parent_id IS NOT NULL)
    """

    alter table(:issues) do
      add :lineage, :jsonb
    end

    # Backfill lineage for existing issues.
    # Walks up to 3 levels: goal -> parent -> grandparent.
    # - Mission: root goal (no parent)
    # - Initiative: direct child of a mission
    # - Milestone: child of an initiative (grandchild of mission)
    execute """
      UPDATE issues i
      SET lineage = sub.lineage
      FROM (
        SELECT
          i2.id AS issue_id,
          jsonb_build_object(
            'goal_id',      g.id::text,
            'project_id',   g.project_id::text,
            'mission_id',   COALESCE(
                              CASE WHEN g.parent_id IS NULL THEN g.id::text END,
                              CASE WHEN pm.parent_id IS NULL THEN pm.id::text END,
                              pgm.id::text
                            ),
            'initiative_id', CASE
                              WHEN g.parent_id IS NOT NULL AND pm.parent_id IS NULL THEN g.id::text
                              WHEN g.parent_id IS NOT NULL AND pm.parent_id IS NOT NULL THEN pm.id::text
                              ELSE NULL
                            END,
            'milestone_id',  CASE
                              WHEN g.parent_id IS NOT NULL AND pm.parent_id IS NOT NULL THEN g.id::text
                              ELSE NULL
                            END
          ) AS lineage
        FROM issues i2
        JOIN goals g ON g.id = i2.goal_id
        LEFT JOIN goals pm ON pm.id = g.parent_id
        LEFT JOIN goals pgm ON pgm.id = pm.parent_id
        WHERE i2.goal_id IS NOT NULL
      ) sub
      WHERE i.id = sub.issue_id
    """
  end

  def down do
    alter table(:issues) do
      remove :lineage
    end

    drop_if_exists index(:goals, [:company_id, :goal_type])
    drop_if_exists index(:goals, [:goal_type])

    alter table(:goals) do
      remove :goal_type
    end
  end
end
