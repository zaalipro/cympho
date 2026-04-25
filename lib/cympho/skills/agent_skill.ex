defmodule Cympho.Skills.AgentSkill do
  @moduledoc """
  Join schema linking agents to plugins (skills).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Agents.Agent
  alias Cympho.Skills.Plugin

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_skills" do
    field :locked_version, :string

    belongs_to :agent, Agent
    belongs_to :plugin, Plugin

    timestamps(type: :utc_datetime)
  end

  def changeset(agent_skill, attrs) do
    agent_skill
    |> cast(attrs, [:agent_id, :plugin_id, :locked_version])
    |> validate_required([:agent_id, :plugin_id])
    |> unique_constraint([:agent_id, :plugin_id])
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:plugin_id)
  end
end
