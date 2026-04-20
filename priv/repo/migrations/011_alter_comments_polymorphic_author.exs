defmodule Cympho.Repo.Migrations.AlterCommentsPolymorphicAuthor do
  use Ecto.Migration

  def change do
    alter table(:comments) do
      remove :author
      add :author_type, :string, null: false
      add :author_id, :string, null: false
    end
  end
end