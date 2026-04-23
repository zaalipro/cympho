defmodule Cympho.Repo.Migrations.AddSettingsToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :settings, :map, default: %{}
    end
  end
end
