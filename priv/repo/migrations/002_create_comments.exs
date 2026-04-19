defmodule Cympho.Repo.Migrations.CreateComments do
  use Ecto.Migration

  def change do
    create table(:comments, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :body, :text, null: false
      add :author, :string, null: false
      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:comments, [:issue_id])
  end
end
