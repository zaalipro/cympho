defmodule Cympho.Repo.Migrations.CreateRecentSearches do
  use Ecto.Migration

  def change do
    create table(:recent_searches, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :query, :string, null: false
      add :filters, :map, default: "{}"
      add :search_count, :integer, default: 1
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false
      add :company_id, references(:companies, on_delete: :delete_all, type: :binary_id), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:recent_searches, [:user_id])
    create index(:recent_searches, [:company_id])
    create index(:recent_searches, [:user_id, :updated_at])
  end
end
