defmodule Cympho.Repo.Migrations.CreateFinanceEvents do
  use Ecto.Migration

  def change do
    create table(:finance_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :event_type, :string, null: false
      add :amount_usd, :decimal, precision: 18, scale: 8, null: false
      add :currency, :string, null: false, default: "USD"

      add :token_usage_id, references(:token_usages, type: :binary_id, on_delete: :nilify_all)

      add :description, :text
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:finance_events, [:company_id])
    create index(:finance_events, [:event_type])
    create index(:finance_events, [:token_usage_id])
    create index(:finance_events, [:inserted_at])
  end
end
