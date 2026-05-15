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
    field :status, :string, default: "pending"
    field :attempt_count, :integer, default: 0
    field :last_error, :string
    field :consumed_at, :utc_datetime
    field :triggered_by_type, :string
    field :triggered_by_id, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @reasons ~w(
    issue_commented
    issue_comment_mentioned
    issue_blockers_resolved
    issue_children_completed
    execution_policy_stage_transition
    manual_dispatch
    company_resumed
    routine_triggered
    agent_handoff
    runtime_retry
    issue_created
    child_created
    child_status_changed
    final_review_required
    review_nudge_re_emit
    review_nudge_escalated
  )

  def changeset(agent_wake, attrs) do
    agent_wake
    |> cast(attrs, [
      :agent_id,
      :issue_id,
      :reason,
      :status,
      :attempt_count,
      :last_error,
      :consumed_at,
      :triggered_by_type,
      :triggered_by_id,
      :metadata
    ])
    |> validate_required([:agent_id, :reason])
    |> validate_inclusion(:reason, @reasons)
    |> validate_inclusion(:status, ~w(pending running consumed failed cancelled))
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_inclusion(:triggered_by_type, ["agent", "user", "system"])
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:issue_id)
  end

  def reasons, do: @reasons
end
