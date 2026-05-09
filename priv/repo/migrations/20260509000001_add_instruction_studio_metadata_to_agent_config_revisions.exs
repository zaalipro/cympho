defmodule Cympho.Repo.Migrations.AddInstructionStudioMetadataToAgentConfigRevisions do
  use Ecto.Migration

  def change do
    alter table(:agent_config_revisions) do
      add :role, :string
      add :adapter, :string
      add :runtime_config, :map, default: %{}, null: false
      add :studio_score, :integer
      add :studio_status, :string
      add :studio_audits, :map, default: %{}, null: false
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :source, :string, default: "manual", null: false

      add :restored_from_revision_id,
          references(:agent_config_revisions, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:agent_config_revisions, [:created_by_user_id])
    create index(:agent_config_revisions, [:restored_from_revision_id])
  end
end
