defmodule Cympho.Repo.Migrations.AddMoreKeysetPaginationIndexes do
  use Ecto.Migration

  # Completes the keyset-pagination index coverage started in
  # AddKeysetPaginationIndexes. Each composite is (scope, sort_cols..., id) so
  # Cympho.Pagination resolves the feed with a single index range scan and the
  # id tiebreak stays in the index rather than becoming a heap filter. A plain
  # btree serves DESC keyset scans by reading backward.
  def change do
    # My Issues feed orders by [updated_at desc, id desc], scoped by assignee
    # (active/watching tabs) or company (all/created_by_me tabs).
    create index(:issues, [:company_id, :updated_at, :id])
    create index(:issues, [:assignee_id, :updated_at, :id])

    # inserted_at-desc, company-scoped.
    create index(:budgets, [:company_id, :inserted_at, :id])

    # inserted_at-asc, company-scoped.
    create index(:goals, [:company_id, :inserted_at, :id])

    # name-asc, company-scoped.
    create index(:projects, [:company_id, :name, :id])
    create index(:skills, [:company_id, :name, :id])

    # key-asc, company-scoped.
    create index(:secrets, [:company_id, :key, :id])

    # Approvals page orders by [inserted_at desc, id desc]; its company scope is a
    # join to the requesting agent, so index the sort columns on the table itself.
    create index(:approvals, [:inserted_at, :id])
  end
end
