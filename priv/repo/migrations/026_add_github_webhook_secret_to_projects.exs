defmodule Cympho.Repo.Migrations.AddGithubWebhookSecretToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :github_webhook_secret, :string
    end
  end
end