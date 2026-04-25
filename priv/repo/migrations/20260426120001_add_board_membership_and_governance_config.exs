defmodule Cympho.Repo.Migrations.AddBoardMembershipAndGovernanceConfig do
  use Ecto.Migration

  def up do
    unless column_exists?(:company_memberships, :is_board_member) do
      alter table(:company_memberships) do
        add :is_board_member, :boolean, default: false, null: false
      end
    end

    unless index_exists?(:company_memberships, :company_memberships_board_members_idx) do
      create index(:company_memberships, [:company_id, :is_board_member],
               where: "is_board_member = true",
               name: :company_memberships_board_members_idx)
    end

    unless column_exists?(:companies, :governance_config) do
      alter table(:companies) do
        add :governance_config, :jsonb, default: "{}", null: false
      end
    end
  end

  def down do
    if column_exists?(:company_memberships, :is_board_member) do
      alter table(:company_memberships) do
        remove :is_board_member
      end
    end

    if index_exists?(:company_memberships, :company_memberships_board_members_idx) do
      drop index(:company_memberships, name: :company_memberships_board_members_idx)
    end

    if column_exists?(:companies, :governance_config) do
      alter table(:companies) do
        remove :governance_config
      end
    end
  end

  defp column_exists?(table, column) do
    result = Postgrex.query!(
      Cympho.Repo,
      "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = $1 AND column_name = $2",
      [Atom.to_string(table), Atom.to_string(column)]
    )
    result.rows |> List.first() |> List.first() > 0
  end

  defp index_exists?(table, index_name) do
    result = Postgrex.query!(
      Cympho.Repo,
      "SELECT COUNT(*) FROM pg_indexes WHERE tablename = $1 AND indexname = $2",
      [Atom.to_string(table), Atom.to_string(index_name)]
    )
    result.rows |> List.first() |> List.first() > 0
  end
end
