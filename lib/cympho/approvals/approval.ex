defmodule Cympho.Approvals.Approval do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Agents.Agent
  alias Cympho.Users.User

  @status_values [:pending, :approved, :denied, :cancelled]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "approvals" do
    field :type, :string
    field :status, Ecto.Enum, values: @status_values, default: :pending
    field :payload, :map
    field :resolution_reason, :string

    belongs_to :requested_by, Agent, foreign_key: :requested_by_agent_id
    belongs_to :resolved_by, User, foreign_key: :resolved_by_user_id

    many_to_many :issues, Cympho.Issues.Issue,
      join_through: "approval_issues",
      join_keys: [approval_id: :id, issue_id: :id],
      unique: true

    timestamps(type: :utc_datetime)
  end

  def status_values, do: @status_values

  def create_changeset(approval, attrs) do
    approval
    |> cast(attrs, [:type, :status, :payload, :requested_by_agent_id])
    |> validate_required([:type, :requested_by_agent_id])
    |> validate_inclusion(:status, @status_values)
  end

  def resolve_changeset(approval, attrs) do
    approval
    |> cast(attrs, [:status, :resolution_reason, :resolved_by_user_id])
    |> validate_inclusion(:status, [:approved, :denied])
    |> validate_resolution_transition(approval.status)
  end

  def cancel_changeset(approval) do
    approval
    |> change(%{status: :cancelled})
  end

  defp validate_resolution_transition(changeset, current_status) do
    validate_change(changeset, :status, fn _, new_status ->
      if current_status == :pending and new_status in [:approved, :denied] do
        []
      else
        [status: "cannot resolve approval in #{current_status} status"]
      end
    end)
  end
end
