defmodule Cympho.Repo.Migrations.AddOnboardingDraftToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :onboarding_draft, :map, null: false, default: %{}
    end
  end
end
