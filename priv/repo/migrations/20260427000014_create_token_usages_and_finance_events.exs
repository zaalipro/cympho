defmodule Cympho.Repo.Migrations.CreateTokenUsagesAndFinanceEvents do
  use Ecto.Migration

  def change do
    create table(:token_usages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, :binary_id
      add :project_id, :binary_id
      add :goal_id, :binary_id
      add :issue_id, :binary_id

      add :provider, :string, null: false
      add :model, :string, null: false
      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :total_tokens, :integer, default: 0
      add :cost_usd, :decimal, default: "0.0"
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:token_usages, [:company_id])
    create index(:token_usages, [:agent_id])
    create index(:token_usages, [:provider, :model])

    create table(:finance_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :token_usage_id, references(:token_usages, type: :binary_id, on_delete: :nilify_all)

      add :event_type, :string, null: false
      add :amount_usd, :decimal, null: false
      add :currency, :string, default: "USD"
      add :description, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:finance_events, [:company_id])
    create index(:finance_events, [:token_usage_id])
    create index(:finance_events, [:event_type])
  end
end
