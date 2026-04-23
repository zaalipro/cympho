defmodule Cympho.Repo.Migrations.AddVerificationTokenToTelegramLinks do
  use Ecto.Migration

  def change do
    alter table(:telegram_links) do
      add :verification_token, :string
    end

    create index(:telegram_links, [:verification_token])
  end
end
