defmodule Cympho.Repo.Migrations.CreateIssueDocuments do
  use Ecto.Migration

  def change do
    create table(:issue_documents, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :key, :string, null: false
      add :title, :string, null: false
      add :format, :string, default: "markdown", null: false
      add :body, :text, default: "", null: false
      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:issue_documents, [:issue_id, :key])
    create index(:issue_documents, [:issue_id])

    create table(:issue_document_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true, autogenerate: true
      add :body, :text, null: false
      add :title, :string, null: false
      add :document_id, references(:issue_documents, type: :binary_id, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create index(:issue_document_revisions, [:document_id])
  end
end
