defmodule Cympho.Agents.AgentConfigRevision do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Agents.Agent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_config_revisions" do
    field :version, :integer
    field :role, :string
    field :adapter, :string
    field :instructions, :string
    field :config, :map, default: %{}
    field :runtime_config, :map, default: %{}
    field :studio_score, :integer
    field :studio_status, :string
    field :studio_audits, :map, default: %{}
    field :source, :string, default: "manual"

    belongs_to :agent, Agent
    field :created_by_agent_id, :binary_id
    field :created_by_user_id, :binary_id
    field :restored_from_revision_id, :binary_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(agent_config_revision, attrs) do
    agent_config_revision
    |> cast(attrs, [
      :agent_id,
      :version,
      :role,
      :adapter,
      :instructions,
      :config,
      :runtime_config,
      :studio_score,
      :studio_status,
      :studio_audits,
      :source,
      :created_by_agent_id,
      :created_by_user_id,
      :restored_from_revision_id
    ])
    |> validate_required([:agent_id, :version])
    |> unique_constraint([:agent_id, :version])
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> foreign_key_constraint(:restored_from_revision_id)
  end
end
