defmodule Cympho.GovernanceAuditLogs.GovernanceAuditLog do
  @moduledoc """
  Audit log for governance decisions and actions.
  Tracks all governance-related activities for compliance and review.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "governance_audit_logs" do
    field :action_type, :string
    field :actor_type, :string
    field :actor_id, :binary_id
    field :resource_type, :string
    field :resource_id, :binary_id
    field :decision, :string
    field :reasoning, :string
    field :metadata, :map, default: %{}
    field :ip_address, :string
    field :user_agent, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [
      :action_type,
      :actor_type,
      :actor_id,
      :resource_type,
      :resource_id,
      :decision,
      :reasoning,
      :metadata,
      :ip_address,
      :user_agent
    ])
    |> validate_required([
      :action_type,
      :actor_type,
      :actor_id,
      :decision
    ])
    |> validate_inclusion(:actor_type, ["user", "agent", "system"])
    |> validate_inclusion(:action_type, [
      "approval_created",
      "approval_resolved",
      "approval_cancelled",
      "policy_created",
      "policy_updated",
      "policy_deleted",
      "budget_created",
      "budget_updated",
      "budget_spent",
      "budget_limit_reached",
      "budget_threshold_reached",
      "agent_paused",
      "agent_resumed",
      "agent_terminated",
      "agent_hired",
      "agent_promoted",
      "permission_granted",
      "permission_revoked",
      "board_proposal_created",
      "board_vote_cast",
      "board_proposal_cancelled",
      "board_decision",
      "guard_denied",
      "issue_gated"
    ])
  end
end
