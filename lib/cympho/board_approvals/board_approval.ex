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

    belongs_to :requested_by, Agent
    belongs_to :company, Company

    has_many :votes, BoardApprovalVote, foreign_key: :board_approval_id

    timestamps(type: :utc_datetime)
  end

  def categories,
    do: [
      "agent_hire",
      "agent_termination",
      "agent_promotion",
      "agent_hire",
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
      :requested_by_id,
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

  def approval_threshold_met?(%__MODULE__{} = board_approval, threshold \\ 0.6) do
    summary = vote_summary(board_approval)
    approve_count = Map.get(summary, "approve", 0)
    total_votes = Enum.sum(Map.values(summary))

    if total_votes > 0 do
      approve_count / total_votes >= threshold
    else
      false
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
