defmodule Cympho.Repo.Migrations.AddRepoUrlToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :repo_url, :string
    end
  end
end
