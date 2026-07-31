defmodule Cympho.Repo.Migrations.AddWorkModeToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :work_mode, :string, null: false, default: "standard"
    end

    create constraint(:issues, :issues_work_mode_check,
             check: "work_mode IN ('standard', 'planning', 'ask')"
           )
  end
end
