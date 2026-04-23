defmodule Cympho.Repo.Migrations.AddUrlKeyToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :url_key, :string
    end

    create index(:agents, [:url_key])
  end
end