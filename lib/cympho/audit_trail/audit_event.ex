defmodule Cympho.AuditTrail.AuditEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "audit_events" do
    field :event_type, :string
    field :actor_type, :string
    field :actor_id, :binary_id
    field :resource_type, :string
    field :resource_id, :binary_id
    field :payload, :map, default: %{}
    field :ip_address, :string

    belongs_to :company, Cympho.Companies.Company

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @valid_event_types ~w(
    issue_state_transition
    issue_created
    issue_assigned
    issue_blocked
    issue_unblocked
    agent_paused
    agent_resumed
    agent_terminated
    agent_created
    agent_updated
    agent_deleted
    orchestrator_session_started
    orchestrator_session_ended
    orchestrator_tool_call
    board_approval_vote
    board_approval_created
    budget_threshold_changed
    decision_created
    decision_reversed
    agent_action_executed
    comment_created
    work_product_attached
  )

  @valid_actor_types ~w(agent user system)

  @valid_resource_types ~w(
    issue
    agent
    orchestrator_session
    board_approval
    budget
    decision
    comment
    work_product
    company
    project
    goal
  )

  def changeset(audit_event, attrs) do
    audit_event
    |> cast(attrs, [
      :company_id,
      :event_type,
      :actor_type,
      :actor_id,
      :resource_type,
      :resource_id,
      :payload,
      :ip_address
    ])
    |> validate_required([
      :company_id,
      :event_type,
      :actor_type,
      :actor_id,
      :resource_type,
      :resource_id
    ])
    |> validate_inclusion(:event_type, @valid_event_types)
    |> validate_inclusion(:actor_type, @valid_actor_types)
    |> validate_inclusion(:resource_type, @valid_resource_types)
    |> foreign_key_constraint(:company_id)
  end
end
