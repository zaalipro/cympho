defmodule Cympho.Agents.InstructionFile do
  @moduledoc """
  A non-entry instructions file for an agent.

  The entry file (AGENTS.md) is stored on `Cympho.Agents.Agent.instructions`
  for backward compatibility. Additional files (e.g. a per-language style
  guide) live here, one row per file, keyed by `(agent_id, filename)`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agent_instruction_files" do
    field :filename, :string
    field :content, :string, default: ""

    belongs_to :agent, Cympho.Agents.Agent

    timestamps(type: :utc_datetime)
  end

  def changeset(file, attrs) do
    file
    |> cast(attrs, [:filename, :content, :agent_id])
    |> validate_required([:filename, :agent_id])
    |> validate_length(:filename, min: 1, max: 255)
    |> unique_constraint([:agent_id, :filename])
    |> foreign_key_constraint(:agent_id)
  end
end
