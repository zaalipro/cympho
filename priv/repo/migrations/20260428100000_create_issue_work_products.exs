defmodule Cympho.Repo.Migrations.CreateIssueWorkProducts do
  use Ecto.Migration

  def change do
    create table(:issue_work_products, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false
      add :created_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)

      add :kind, :string, null: false
      add :title, :string, null: false
      add :description, :text
      add :payload, :map, default: %{}
      add :url, :string
      add :metadata, :map, default: %{}

      add :attachment_id, references(:attachments, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:issue_work_products, [:issue_id])
    create index(:issue_work_products, [:created_by_agent_id])
    create index(:issue_work_products, [:kind])
    create index(:issue_work_products, [:attachment_id])
  end
end
