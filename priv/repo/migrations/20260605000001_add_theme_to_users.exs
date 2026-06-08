defmodule Cympho.Repo.Migrations.AddThemeToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :theme, :string, null: false, default: "claude"
    end
  end
end
