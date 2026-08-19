defmodule Cympho.Repo.Migrations.MarkCreatedByAgentAttachmentMigrationCompatible do
  use Ecto.Migration

  # Compatibility marker for databases that briefly saw this migration at
  # 20260819210000. The reversible schema change lives at its original,
  # already-applied version 20260819190000.
  def change, do: :ok
end
