defmodule Cympho.Repo.Migrations.CreateTokenUsages do
  use Ecto.Migration

  def change do
    create table(:token_usages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :goal_id, references(:goals, type: :binary_id, on_delete: :nilify_all)
      add :issue_id, references(:issues, type: :binary_id, on_delete: :nilify_all)

      add :provider, :string, null: false
      add :model, :string, null: false

      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :total_tokens, :integer, null: false, default: 0

      add :cost_usd, :decimal, precision: 18, scale: 8, null: false, default: 0

      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:token_usages, [:company_id])
    create index(:token_usages, [:agent_id])
    create index(:token_usages, [:project_id])
    create index(:token_usages, [:goal_id])
    create index(:token_usages, [:issue_id])
    create index(:token_usages, [:provider, :model])
    create index(:token_usages, [:inserted_at])
  end
end
