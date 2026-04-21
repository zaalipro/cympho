defmodule Cympho.Repo.Migrations.AddUniqueIndexToGithubPrUrl do
  use Ecto.Migration

  def change do
    create index(:issues, [:github_pr_url], unique: true, where: "github_pr_url IS NOT NULL")
  end
end