defmodule Cympho.Repo.Migrations.AddExecutionPolicyToIssues do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :execution_policy_id, references(:execution_policies, type: :binary_id, on_delete: :nilify_all)
      add :execution_state, :map, default: "{}"
    end

    create index(:issues, [:execution_policy_id])
  end
end
