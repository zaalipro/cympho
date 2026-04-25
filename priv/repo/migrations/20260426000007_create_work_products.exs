defmodule Cympho.Repo.Migrations.CreateWorkProducts do
  use Ecto.Migration

  def change do
    create table(:work_products, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)

      add :name, :string, null: false
      add :content_type, :string, null: false
      add :content, :text
      add :file_path, :string

      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:work_products, [:issue_id])
    create index(:work_products, [:agent_id])
  end
end
