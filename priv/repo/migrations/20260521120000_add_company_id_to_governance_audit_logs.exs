defmodule Cympho.Repo.Migrations.AddCompanyIdToGovernanceAuditLogs do
  use Ecto.Migration

  # Adds the missing tenancy scope to audit logs. Nullable first so we can
  # backfill safely; a follow-up migration can flip to NOT NULL once the
  # column is populated across deployed environments.
  def change do
    alter table(:governance_audit_logs) do
      add :company_id, references(:companies, on_delete: :nothing, type: :binary_id), null: true
    end

    create index(:governance_audit_logs, [:company_id])

    # Backfill: derive company_id from the related resource for the common
    # resource_type strings produced by GovernanceAuditLogs.extract_resource_info/1
    # (lowercase last segment of the struct module name). Resources where the
    # join target row is missing stay NULL — they were orphans pre-PR2.
    flush()
    execute(&backfill_company_id/0, fn -> :ok end)
  end

  defp backfill_company_id do
    repo = Cympho.Repo

    # Only resource_type strings whose target table actually carries
    # company_id directly. Other resource types (e.g. "approval") stay NULL
    # until a follow-up backfill scopes them through their indirect parents.
    backfills = [
      {"issue", "issues"},
      {"agent", "agents"},
      {"decision", "decisions"},
      {"budget", "budgets"},
      {"boardapproval", "board_approvals"}
    ]

    Enum.each(backfills, fn {resource_type, table} ->
      repo.query!(
        """
        UPDATE governance_audit_logs g
        SET company_id = r.company_id
        FROM #{table} r
        WHERE g.company_id IS NULL
          AND g.resource_type = $1
          AND g.resource_id = r.id
        """,
        [resource_type]
      )
    end)

    # When the resource is the company itself, resource_id IS the company_id.
    repo.query!(
      """
      UPDATE governance_audit_logs
      SET company_id = resource_id
      WHERE company_id IS NULL
        AND resource_type = 'company'
        AND resource_id IS NOT NULL
      """,
      []
    )

    :ok
  end
end
