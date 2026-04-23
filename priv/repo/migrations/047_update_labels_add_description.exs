defmodule Cympho.Repo.Migrations.UpdateLabelsAddDescription do
  use Ecto.Migration

  def change do
    alter table(:labels) do
      add :description, :string
    end
  end
end
