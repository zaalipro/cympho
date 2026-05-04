defmodule Cympho.Repo.Migrations.AddGithubPrNumberToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :github_pr_number, :integer
    end
  end
end
