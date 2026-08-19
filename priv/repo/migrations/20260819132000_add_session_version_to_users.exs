defmodule Cympho.Repo.Migrations.AddSessionVersionToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :session_version, :integer, null: false, default: 0
    end
  end
end
