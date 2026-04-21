defmodule Cympho.Repo.Migrations.AddGithubPrUrlToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :github_pr_url, :string
    end
  end
end