defmodule Cympho.Repo.Migrations.ScopeMultiTenantUniqueIndexes do
  use Ecto.Migration

  # Four unique indexes were global rather than company-scoped, so one tenant's
  # rows blocked another's: company B could not create a label named "bug", use
  # the project prefix "ENG", or hold an active decision_key another company
  # already held.
  #
  # Every change here relaxes a constraint, so no data can conflict and no
  # backfill is needed.

  def up do
    drop_if_exists index(:labels, [:name], name: :labels_name_index)
    create unique_index(:labels, [:company_id, :name], name: :labels_company_id_name_index)

    drop_if_exists index(:projects, [:prefix], name: :projects_prefix_index)
    create unique_index(:projects, [:company_id, :prefix], name: :projects_company_id_prefix_index)

    drop_if_exists index(:decisions, [:decision_key, :parent_decision_id],
                     name: :decisions_decision_key_parent_decision_id_index
                   )

    # Keeps the original partial semantics (active rows only). Postgres treats
    # NULLs as distinct, so as before this constrains only rows that actually
    # have a parent — top-level decision keys stay unconstrained.
    create unique_index(:decisions, [:company_id, :decision_key, :parent_decision_id],
             where: "status = 'active'",
             name: :decisions_company_key_parent_index
           )

    # Rejecting a duplicate content_hash is deliberate — the trace suite covers
    # it under "security properties" — so this stays a unique index and is only
    # scoped to the tenant. Note the consequence that behaviour keeps: because
    # content_hash excludes company_id/agent_id/run_id and occurred_at is
    # :utc_datetime, one agent repeating an identical call inside the same
    # second is still rejected. That is the intended guard, not a gap.
    drop_if_exists index(:tool_call_traces, [:content_hash],
                     name: :tool_call_traces_content_hash_index
                   )

    create unique_index(:tool_call_traces, [:company_id, :content_hash],
             name: :tool_call_traces_company_id_content_hash_index
           )
  end

  def down do
    drop_if_exists index(:labels, [:company_id, :name], name: :labels_company_id_name_index)
    create unique_index(:labels, [:name], name: :labels_name_index)

    drop_if_exists index(:projects, [:company_id, :prefix],
                     name: :projects_company_id_prefix_index
                   )

    create unique_index(:projects, [:prefix], name: :projects_prefix_index)

    drop_if_exists index(:decisions, [:company_id, :decision_key, :parent_decision_id],
                     name: :decisions_company_key_parent_index
                   )

    create unique_index(:decisions, [:decision_key, :parent_decision_id],
             where: "status = 'active'",
             name: :decisions_decision_key_parent_decision_id_index
           )

    drop_if_exists index(:tool_call_traces, [:company_id, :content_hash],
                     name: :tool_call_traces_company_id_content_hash_index
                   )

    create unique_index(:tool_call_traces, [:content_hash],
             name: :tool_call_traces_content_hash_index
           )
  end
end
