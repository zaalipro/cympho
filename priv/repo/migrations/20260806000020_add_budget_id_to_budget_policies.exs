defmodule Cympho.Repo.Migrations.AddBudgetIdToBudgetPolicies do
  use Ecto.Migration

  def up do
    alter table(:budget_policies) do
      add :budget_id, references(:budgets, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:budget_policies, [:budget_id])

    create unique_index(:budget_policies, [:budget_id],
             where: "budget_id IS NOT NULL",
             name: :budget_policies_budget_id_uidx
           )

    # Claim unowned policies that already mirror a UI budget's scope so
    # post-migration sync reuses the same row instead of creating a duplicate.
    # Onboarding company hard-stop policies have no Budgets row and stay
    # budget_id-null (unowned), so UI budgets cannot claim or disarm them.
    execute("""
    UPDATE budget_policies AS p
    SET budget_id = b.id
    FROM budgets AS b
    WHERE p.budget_id IS NULL
      AND p.company_id = b.company_id
      AND p.scope = b.scope_type
      AND (
        (p.scope = 'company' AND (p.scope_id IS NULL OR p.scope_id = b.company_id)
          AND (b.scope_id IS NULL OR b.scope_id = b.company_id))
        OR (p.scope <> 'company' AND p.scope_id IS NOT NULL AND p.scope_id = b.scope_id)
      )
      AND NOT EXISTS (
        SELECT 1 FROM budget_policies p2
        WHERE p2.budget_id = b.id
      )
    """)
  end

  def down do
    drop_if_exists unique_index(:budget_policies, [:budget_id], name: :budget_policies_budget_id_uidx)
    drop_if_exists index(:budget_policies, [:budget_id])

    alter table(:budget_policies) do
      remove :budget_id
    end
  end
end
