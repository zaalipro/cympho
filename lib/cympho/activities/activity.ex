defmodule Cympho.Activities.Activity do
  use Ecto.Schema
  import Ecto.Changeset
  alias Cympho.Issues.Issue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "issue_activities" do
    field :actor_type, :string
    field :actor_id, :string
    field :action, :string
    field :metadata, :map, default: %{}
    belongs_to :company, Cympho.Companies.Company
    belongs_to :issue, Issue
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @valid_actor_types ~w(agent user system)
  @valid_actions ~w(
    created
    title_changed
    description_changed
    status_changed
    priority_changed
    assigned
    unassigned
    blocker_added
    blocker_removed
    comment_added
    approval_created
    approval_resolved
    approval_approved
    approval_rejected
    approval_requested_changes
    heartbeat_started
    heartbeat_completed
    heartbeat_failed
    agent_action
    cost_incurred
    budget_threshold_exceeded
    feedback_submitted
    feedback_exported
    work_product_created
  )

  def changeset(activity, attrs) do
    activity
    |> cast(attrs, [:issue_id, :company_id, :actor_type, :actor_id, :action, :metadata])
    |> validate_required([:issue_id, :actor_type, :action])
    |> validate_inclusion(:actor_type, @valid_actor_types)
    |> validate_inclusion(:action, @valid_actions)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:company_id)
  end
end
