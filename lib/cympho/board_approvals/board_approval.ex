defmodule Cympho.BoardApprovals.BoardApproval do
  @moduledoc """
  Board-level approval workflows for governance decisions.
  Separate from issue approvals, these require board member review.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Cympho.BoardApprovals.BoardApprovalVote
  alias Cympho.Agents.Agent
  alias Cympho.Companies.Company

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "board_approvals" do
    field :title, :string
    field :description, :string
    field :category, :string
    field :status, :string, default: "pending"
    field :proposal_data, :map, default: %{}
    field :decision_reasoning, :string
    field :review_deadline, :utc_datetime

    belongs_to :requested_by, Agent, foreign_key: :requested_by_agent_id
    belongs_to :company, Company

    has_many :votes, BoardApprovalVote, foreign_key: :board_approval_id

    timestamps(type: :utc_datetime)
  end

  def categories,
    do: [
      "agent_hire",
      "agent_termination",
      "agent_promotion",
      "budget_increase",
      "policy_change",
      "security_exception",
      "principal_permission",
      "strategic_initiative",
      "other"
    ]

  def changeset(board_approval, attrs) do
    board_approval
    |> cast(attrs, [
      :title,
      :description,
      :category,
      :status,
      :proposal_data,
      :decision_reasoning,
      :review_deadline,
      :requested_by_agent_id,
      :company_id
    ])
    |> validate_required([:title, :category, :company_id])
    |> validate_inclusion(:category, categories())
    |> validate_inclusion(:status, ["pending", "approved", "denied", "cancelled", "expired"])
    |> validate_deadline()
  end

  def approve_changeset(board_approval, attrs) do
    board_approval
    |> cast(attrs, [:status, :decision_reasoning])
    |> validate_required([:status, :decision_reasoning])
    |> validate_inclusion(:status, ["approved", "denied"])
    |> validate_transition(board_approval.status)
  end

  def vote_summary(%__MODULE__{} = board_approval) do
    board_approval
    |> Ecto.assoc(:votes)
    |> Cympho.Repo.all()
    |> Enum.group_by(& &1.vote)
    |> Enum.map(fn {vote, votes} -> {vote, length(votes)} end)
    |> Map.new()
  end

  @doc """
  Checks whether an approval meets the configured threshold.

  Threshold types (read from company governance_config):
    - "any"        : any single approve vote is enough
    - "percentage" : approve_pct >= threshold_value (default 0.6)
    - "all"        : every cast vote must be approve (unanimous)
    - "count"      : at least N approve votes needed

  Falls back to percentage at 0.6 when no config is set.
  """
  def approval_threshold_met?(%__MODULE__{} = board_approval, opts \\ []) do
    summary = vote_summary(board_approval)
    approve_count = Map.get(summary, "approve", 0)
    deny_count = Map.get(summary, "deny", 0)
    total_votes = approve_count + deny_count + Map.get(summary, "abstain", 0)

    if total_votes == 0 do
      false
    else
      threshold_type = Keyword.get(opts, :threshold_type, "percentage")
      threshold_value = Keyword.get(opts, :threshold_value, 0.6)

      case threshold_type do
        "any" ->
          approve_count >= 1

        "percentage" ->
          approve_count / total_votes >= threshold_value

        "all" ->
          deny_count == 0 and approve_count > 0

        "count" ->
          approve_count >= (threshold_value || 1)

        _ ->
          approve_count / total_votes >= 0.6
      end
    end
  end

  def expired?(%__MODULE__{review_deadline: nil}), do: false

  def expired?(%__MODULE__{review_deadline: deadline, status: status}) do
    status == "pending" and DateTime.compare(DateTime.utc_now(), deadline) == :gt
  end

  defp validate_deadline(changeset) do
    deadline = get_change(changeset, :review_deadline)

    if deadline do
      if DateTime.compare(deadline, DateTime.utc_now()) != :gt do
        add_error(changeset, :review_deadline, "must be in the future")
      else
        changeset
      end
    else
      changeset
    end
  end

  defp validate_transition(changeset, current_status) do
    new_status = get_change(changeset, :status)

    if current_status == "pending" and new_status in ["approved", "denied"] do
      changeset
    else
      add_error(changeset, :status, "cannot transition from #{current_status} to #{new_status}")
    end
  end
end
