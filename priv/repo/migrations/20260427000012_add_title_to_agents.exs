defmodule Cympho.Repo.Migrations.AddTitleToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add_if_not_exists :title, :string
    end
  end
end
