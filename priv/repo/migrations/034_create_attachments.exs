defmodule Cympho.Repo.Migrations.CreateAttachments do
  use Ecto.Migration

  def change do
    create table(:attachments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :file_size, :integer, null: false
      add :path, :string, null: false
      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false
      add :comment_id, references(:comments, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:attachments, [:issue_id])
    create index(:attachments, [:comment_id])
  end
end
