defmodule Cympho.Repo.Migrations.AddUniqueIndexToProjectsPrefix do
  use Ecto.Migration

  def change do
    drop index(:projects, [:prefix])
    create unique_index(:projects, [:prefix])
  end
end
