defmodule Cympho.Repo.Migrations.CreateLabels do
  use Ecto.Migration

  def change do
    create table(:labels, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :color, :string, null: false, default: "#6b7280"
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:labels, [:project_id, :name], name: :labels_project_id_name_index)

    create table(:issue_labels, primary_key: false) do
      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false
      add :label_id, references(:labels, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:issue_labels, [:issue_id, :label_id], name: :issue_labels_unique_index)
    create index(:issue_labels, [:issue_id])
    create index(:issue_labels, [:label_id])
  end
end
