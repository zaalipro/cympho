defmodule Cympho.Repo.Migrations.AddIsBoardMemberToCompanyMemberships do
  use Ecto.Migration

  def change do
    alter table(:company_memberships) do
      add :is_board_member, :boolean, default: false, null: false
    end

    create index(:company_memberships, [:company_id, :is_board_member])
  end
end
