defmodule Cympho.Repo.Migrations.AddTargetDateToGoals do
  use Ecto.Migration

  def change do
    alter table(:goals) do
      add :target_date, :date
    end
  end
end
