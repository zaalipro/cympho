defmodule Cympho.Repo.Migrations.AddClaimsToAgentWakes do
  use Ecto.Migration

  def change do
    alter table(:agent_wakes) do
      add :claim_token, :uuid
      add :claimed_at, :utc_datetime_usec
    end

    create index(:agent_wakes, [:claimed_at, :id],
             where: "status = 'running'",
             name: :agent_wakes_running_claims_index
           )
  end
end
