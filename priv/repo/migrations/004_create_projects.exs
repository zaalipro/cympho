defmodule Cympho.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :name, :string, null: false
      add :description, :string, null: true
      add :status, :string, default: "active", null: false
      add :prefix, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:projects, [:status])
    create index(:projects, [:prefix])
  end
end