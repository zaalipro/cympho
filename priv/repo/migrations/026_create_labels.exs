defmodule Cympho.Repo.Migrations.CreateLabels do
  use Ecto.Migration

  def change do
    create table(:labels, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :name, :string, null: false
      add :color, :string, null: false, default: "#6B7280"
      add :description, :string
      timestamps(type: :utc_datetime)
    end
    create unique_index(:labels, [:name])

    create table(:issue_labels, primary_key: false) do
      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false
      add :label_id, references(:labels, type: :binary_id, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end
    create index(:issue_labels, [:issue_id])
    create index(:issue_labels, [:label_id])
    create unique_index(:issue_labels, [:issue_id, :label_id])
  end
end
