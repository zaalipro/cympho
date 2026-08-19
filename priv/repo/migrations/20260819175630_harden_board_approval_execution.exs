defmodule Cympho.Repo.Migrations.HardenBoardApprovalExecution do
  use Ecto.Migration

  def up do
    alter table(:board_approvals) do
      add :execution_claim_token, :uuid
      add :execution_lease_expires_at, :utc_datetime
    end

    execute("""
    UPDATE board_approvals
    SET execution_lease_expires_at = NOW() + INTERVAL '5 minutes'
    WHERE execution_state = 'claimed'
    """)

    create index(:board_approvals, [:execution_state, :execution_lease_expires_at],
             where: "execution_state = 'claimed'",
             name: :board_approvals_claim_lease_index
           )

    create table(:board_approval_effects, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :board_approval_id,
          references(:board_approvals, type: :binary_id, on_delete: :delete_all),
          null: false

      add :effect_key, :string, null: false
      add :category, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_approval_effects, [:board_approval_id])
    create unique_index(:board_approval_effects, [:effect_key])
  end

  def down do
    drop table(:board_approval_effects)

    drop index(:board_approvals, [:execution_state, :execution_lease_expires_at],
           name: :board_approvals_claim_lease_index
         )

    alter table(:board_approvals) do
      remove :execution_claim_token
      remove :execution_lease_expires_at
    end
  end
end
