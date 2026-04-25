defmodule Cympho.Repo.Migrations.AddManifestErrorsToPlugins do
  use Ecto.Migration

  def change do
    alter table(:plugins) do
      add :manifest_errors, :map, default: %{}
    end
  end
end
