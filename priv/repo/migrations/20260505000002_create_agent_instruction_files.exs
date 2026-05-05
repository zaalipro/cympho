defmodule Cympho.Repo.Migrations.CreateAgentInstructionFiles do
  use Ecto.Migration

  def change do
    create table(:agent_instruction_files, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :filename, :string, null: false
      add :content, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_instruction_files, [:agent_id, :filename])

    # Backfill from agents.runtime_config["instructions_files"] (a filename =>
    # content map). The "entry" file (AGENTS.md) is kept on agents.instructions
    # for backward compatibility — only non-entry files migrate into the new
    # table.
    execute(&backfill_up/0, &noop/0)
  end

  defp backfill_up do
    repo = Ecto.Migration.repo()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{rows: rows} =
      repo.query!(
        "SELECT id, runtime_config FROM agents WHERE runtime_config ? 'instructions_files'",
        []
      )

    Enum.each(rows, fn [agent_id, %{"instructions_files" => files}] when is_map(files) ->
      Enum.each(files, fn {filename, content} ->
        repo.query!(
          """
          INSERT INTO agent_instruction_files (id, agent_id, filename, content, inserted_at, updated_at)
          VALUES (gen_random_uuid(), $1, $2, $3, $4, $4)
          ON CONFLICT (agent_id, filename) DO NOTHING
          """,
          [agent_id, to_string(filename), to_string(content || ""), now]
        )
      end)
    end)
  end

  defp noop, do: :ok
end
