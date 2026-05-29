defmodule Cympho.Repo.Migrations.DropExecutionStageResults do
  use Ecto.Migration

  # The `execution_stage_results` table backed `Cympho.ExecutionPolicies.ExecutionStageResult`,
  # a schema that was never instantiated, queried, or referenced anywhere
  # (spec 03, REQ-005). It is a leaf table — nothing references it — so the
  # drop is safe.
  def up do
    drop_if_exists table(:execution_stage_results)
  end

  def down do
    # Intentionally not recreated: the table backed an unused schema removed in
    # spec 03. Restore it from migration 20260425181501 if it is ever needed.
    :ok
  end
end
