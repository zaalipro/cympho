defmodule Cympho.Repo.Migrations.MakeIssueLabelsTimestampsNullable do
  use Ecto.Migration

  def change do
    alter table(:issue_labels) do
      modify :inserted_at, :utc_datetime, null: true
      modify :updated_at, :utc_datetime, null: true
    end
  end
end
