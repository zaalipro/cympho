defmodule Cympho.Repo.Migrations.AlignBudgetScopeRelations do
  use Ecto.Migration

  def up do
    # scope_id was historically the runtime target. Preserve it when it names a
    # target in the same company, then backfill from the relational field only
    # when that is the sole valid same-company target.
    execute("""
    UPDATE budgets AS b
    SET agent_id = b.scope_id,
        project_id = NULL
    FROM agents AS a
    WHERE b.scope_type = 'agent'
      AND a.id = b.scope_id
      AND a.company_id = b.company_id
    """)

    execute("""
    UPDATE budgets AS b
    SET scope_id = b.agent_id,
        project_id = NULL
    FROM agents AS a
    WHERE b.scope_type = 'agent'
      AND a.id = b.agent_id
      AND a.company_id = b.company_id
      AND NOT EXISTS (
        SELECT 1
        FROM agents AS scoped_agent
        WHERE scoped_agent.id = b.scope_id
          AND scoped_agent.company_id = b.company_id
      )
    """)

    execute("""
    UPDATE budgets AS b
    SET project_id = b.scope_id,
        agent_id = NULL
    FROM projects AS p
    WHERE b.scope_type = 'project'
      AND p.id = b.scope_id
      AND p.company_id = b.company_id
    """)

    execute("""
    UPDATE budgets AS b
    SET scope_id = b.project_id,
        agent_id = NULL
    FROM projects AS p
    WHERE b.scope_type = 'project'
      AND p.id = b.project_id
      AND p.company_id = b.company_id
      AND NOT EXISTS (
        SELECT 1
        FROM projects AS scoped_project
        WHERE scoped_project.id = b.scope_id
          AND scoped_project.company_id = b.company_id
      )
    """)

    execute("""
    UPDATE budgets
    SET scope_id = company_id,
        project_id = NULL,
        agent_id = NULL
    WHERE scope_type = 'company'
    """)

    execute("""
    UPDATE budgets
    SET project_id = NULL,
        agent_id = NULL
    WHERE scope_type = 'custom'
    """)

    # Invalid relational targets cannot be repaired without guessing tenant
    # ownership. Disarm them and any owned runtime policy instead.
    execute("""
    UPDATE budgets AS b
    SET status = 'cancelled',
        agent_id = NULL,
        project_id = NULL
    WHERE b.scope_type = 'agent'
      AND NOT EXISTS (
        SELECT 1
        FROM agents AS a
        WHERE a.id = b.scope_id
          AND a.company_id = b.company_id
      )
    """)

    execute("""
    UPDATE budgets AS b
    SET status = 'cancelled',
        agent_id = NULL,
        project_id = NULL
    WHERE b.scope_type = 'project'
      AND NOT EXISTS (
        SELECT 1
        FROM projects AS p
        WHERE p.id = b.scope_id
          AND p.company_id = b.company_id
      )
    """)

    execute("""
    UPDATE budget_policies AS p
    SET scope = b.scope_type,
        scope_id = CASE WHEN b.scope_type = 'company' THEN NULL ELSE b.scope_id END,
        is_active = COALESCE(b.status IN ('active', 'exhausted'), FALSE)
    FROM budgets AS b
    WHERE p.budget_id = b.id
      AND p.company_id = b.company_id
      AND b.scope_type IN ('company', 'agent', 'project')
    """)

    execute("""
    UPDATE budget_policies AS p
    SET is_active = FALSE
    FROM budgets AS b
    WHERE p.budget_id = b.id
      AND p.company_id = b.company_id
      AND b.scope_type = 'custom'
    """)

    # A cross-company ownership link is not merely inactive: budget_id has a
    # partial unique index, so retaining the forged link would prevent the
    # budget's real company from creating its policy. Detach the link as well
    # as disarming the policy. Preserve its legacy scope metadata because it
    # belongs to p.company_id and cannot be reconciled safely from the foreign
    # budget without importing another tenant's target.
    execute("""
    UPDATE budget_policies AS p
    SET budget_id = NULL,
        is_active = FALSE
    FROM budgets AS b
    WHERE p.budget_id = b.id
      AND p.company_id IS DISTINCT FROM b.company_id
    """)
  end

  def down do
    # This migration only repairs redundant target columns and disarms rows
    # whose intended tenant cannot be recovered safely.
    :ok
  end
end
