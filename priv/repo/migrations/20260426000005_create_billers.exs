defmodule Cympho.Repo.Migrations.CreateBillers do
  use Ecto.Migration

  def change do
    create table(:billers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :provider, :string, null: false

      add :billing_cycle, :string, null: false, default: "monthly"
      add :billing_day, :integer, null: false, default: 1

      add :config, :map, default: %{}
      add :is_active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:billers, [:company_id])
    create unique_index(:billers, [:company_id, :provider])
    create index(:billers, [:is_active])
  end
end
