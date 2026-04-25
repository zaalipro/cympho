defmodule Cympho.Wakes.AgentWake do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Agents.Agent
  alias Cympho.Issues.Issue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_wakes" do
    belongs_to :agent, Agent
    belongs_to :issue, Issue

    field :reason, :string
    field :triggered_by_type, :string
    field :triggered_by_id, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @reasons ~w(issue_commented issue_comment_mentioned issue_blockers_resolved issue_children_completed execution_policy_stage_transition)

  def changeset(agent_wake, attrs) do
    agent_wake
    |> cast(attrs, [
      :agent_id,
      :issue_id,
      :reason,
      :triggered_by_type,
      :triggered_by_id,
      :metadata
    ])
    |> validate_required([:agent_id, :reason])
    |> validate_inclusion(:reason, @reasons)
    |> validate_inclusion(:triggered_by_type, ["agent", "user", "system"])
  end

  def reasons, do: @reasons
end
