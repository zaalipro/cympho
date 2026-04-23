defmodule Cympho.Repo.Migrations.AddSettingsToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add_if_not_exists :settings, :map, default: %{}
    end
  end
end
