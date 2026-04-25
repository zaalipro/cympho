defmodule Cympho.Repo.Migrations.AddBoardMembershipAndGovernanceConfig do
  use Ecto.Migration

  def change do
    alter table(:company_memberships) do
      add :is_board_member, :boolean, default: false, null: false
    end

    create index(:company_memberships, [:company_id, :is_board_member],
             where: "is_board_member = true",
             name: :company_memberships_board_members_idx)

    alter table(:companies) do
      add :governance_config, :jsonb, default: "{}", null: false
    end
  end
end
