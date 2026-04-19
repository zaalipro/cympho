defmodule Cympho.Repo.Migrations.CreateIssues do
  use Ecto.Migration

  def change do
    create table(:issues, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :title, :string, null: false
      add :description, :text, null: false
      add :status, :string, default: "open", null: false
      add :priority, :string, default: "medium", null: false

      timestamps(type: :utc_datetime)
    end

    create index(:issues, [:status])
    create index(:issues, [:priority])
  end
end
