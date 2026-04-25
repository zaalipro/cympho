defmodule Cympho.Agents.AgentConfigRevision do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Agents.Agent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_config_revisions" do
    field :version, :integer
    field :instructions, :string
    field :config, :map, default: %{}

    belongs_to :agent, Agent
    field :created_by_agent_id, :binary_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(agent_config_revision, attrs) do
    agent_config_revision
    |> cast(attrs, [:agent_id, :version, :instructions, :config, :created_by_agent_id])
    |> validate_required([:agent_id, :version])
    |> unique_constraint([:agent_id, :version])
    |> foreign_key_constraint(:agent_id)
  end
end
