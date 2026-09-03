defmodule Cympho.Repo.Migrations.AddRecoveryResolutionNote do
  use Ecto.Migration

  def change do
    alter table(:recovery_cases) do
      add :resolution_note, :text
    end

    create constraint(:recovery_cases, :recovery_cases_resolution_note_size_check,
             check: "resolution_note IS NULL OR char_length(resolution_note) <= 1000"
           )
  end
end
