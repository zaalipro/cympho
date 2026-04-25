defmodule Cympho.Repo.Migrations.AddBoardMembershipAndGovernanceConfig do
  use Ecto.Migration

  def up do
    alter table(:company_memberships) do
      add_if_not_exists :is_board_member, :boolean, default: false, null: false
    end

    create_if_not_exists index(:company_memberships, [:company_id, :is_board_member],
             where: "is_board_member = true",
             name: :company_memberships_board_members_idx)

    alter table(:companies) do
      add_if_not_exists :governance_config, :jsonb, default: "{}", null: false
    end
  end

  def down do
    alter table(:company_memberships) do
      remove_if_exists :is_board_member, :boolean
    end

    drop_if_exists index(:company_memberships, name: :company_memberships_board_members_idx)

    alter table(:companies) do
      remove_if_exists :governance_config, :jsonb
    end
  end
end
