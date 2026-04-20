defmodule Cympho.Repo.Migrations.ExpandIssueStatuses do
  use Ecto.Migration

  def up do
    alter table(:issues) do
      modify :status, :string, from: :string
    end

    execute """
    UPDATE issues SET status = 'todo' WHERE status = 'open'
    """, """
    UPDATE issues SET status = 'open' WHERE status = 'todo'
    """

    execute """
    UPDATE issues SET status = 'done' WHERE status = 'closed'
    """, """
    UPDATE issues SET status = 'closed' WHERE status = 'done'
    """

    flush()

    alter table(:issues) do
      modify :status, :string, null: false, default: "backlog"
    end
  end

  def down do
    alter table(:issues) do
      modify :status, :string, from: :string
    end

    execute """
    UPDATE issues SET status = 'open' WHERE status = 'todo'
    """, """
    UPDATE issues SET status = 'todo' WHERE status = 'open'
    """

    execute """
    UPDATE issues SET status = 'closed' WHERE status = 'done'
    """, """
    UPDATE issues SET status = 'done' WHERE status = 'closed'
    """

    flush()

    alter table(:issues) do
      modify :status, :string, null: false, default: "open"
    end
  end
end