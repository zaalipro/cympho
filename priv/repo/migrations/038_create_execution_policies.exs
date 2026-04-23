defmodule Cympho.Repo.Migrations.CreateExecutionPolicies do
  use Ecto.Migration

  def change do
    create table(:execution_policies, primary_key: false) do
      add :id, :binary_id, primary_key: true, null: false
      add :name, :string, null: false
      add :stage_configs, {:array, :map}, default: []

      timestamps(type: :utc_datetime)
    end
  end
end
