defmodule Cympho.GovernanceAuditLogs.GovernanceAuditLog do
  @moduledoc """
  Audit log for governance decisions and actions.
  Tracks all governance-related activities for compliance and review.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company

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
    field :tool_call_trace_id, :binary_id

    belongs_to :company, Company

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
      :user_agent,
      :tool_call_trace_id,
      :company_id
    ])
    |> validate_required([
      :action_type,
      :actor_type,
      :actor_id,
      :decision
    ])
    |> validate_inclusion(:actor_type, ["user", "agent", "system"])
    |> validate_length(:action_type, min: 1)
  end
end
