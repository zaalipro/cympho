defmodule Cympho.Repo.Migrations.AddRuntimeServicePreviewRef do
  use Ecto.Migration

  def change do
    alter table(:workspace_runtime_services) do
      add :preview_ref, :binary_id
    end

    create unique_index(:workspace_runtime_services, [:preview_ref])
  end
end
