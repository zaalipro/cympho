defmodule Cympho.BoardApprovals.BoardApproval do
  @moduledoc """
  Board-level approval workflows for governance decisions.
  Separate from issue approvals, these require board member review.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.BoardApprovals.BoardApprovalVote
  alias Cympho.Agents.Agent
  alias Cympho.Companies.Company
  alias Cympho.Recovery.RecoveryCase

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

    field :executed_at, :utc_datetime
    field :executor_node, :string
    field :execution_claim_token, Ecto.UUID
    field :execution_lease_expires_at, :utc_datetime
    # "claimed" while an executor owns it, "executed" once it succeeded,
    # "failed" once retries were exhausted. `executed_at` alone could not tell
    # a claimed-then-failed approval from one that actually ran.
    field :execution_state, :string

    belongs_to :requested_by, Agent, foreign_key: :requested_by_agent_id
    belongs_to :company, Company
    belongs_to :recovery_case, RecoveryCase

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
      "stranded_work_recovery",
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
      :company_id,
      :recovery_case_id
    ])
    |> validate_required([:title, :category, :company_id])
    |> validate_inclusion(:category, categories())
    |> validate_inclusion(:status, ["pending", "approved", "denied", "cancelled", "expired"])
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:requested_by_agent_id)
    |> foreign_key_constraint(:recovery_case_id)
    |> unique_constraint(:recovery_case_id, name: :board_approvals_recovery_case_index)
    |> validate_recovery_linkage()
    |> validate_proposal_bounds()
    |> validate_deadline()
    |> prepare_changes(&validate_recovery_company/1)
  end

  def approve_changeset(board_approval, attrs) do
    board_approval
    |> cast(attrs, [:status, :decision_reasoning])
    |> validate_required([:status, :decision_reasoning])
    |> validate_inclusion(:status, ["approved", "denied"])
    |> validate_transition(board_approval.status)
    |> validate_approval_deadline(board_approval)
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

    cond do
      total_votes == 0 ->
        false

      total_votes < Keyword.get(opts, :min_quorum, 3) ->
        false

      true ->
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
    status == "pending" and DateTime.compare(DateTime.utc_now(), deadline) != :lt
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

  defp validate_approval_deadline(changeset, board_approval) do
    if get_change(changeset, :status) == "approved" and expired?(board_approval) do
      add_error(changeset, :status, "review deadline has passed")
    else
      changeset
    end
  end

  defp validate_recovery_linkage(changeset) do
    category = get_field(changeset, :category)
    recovery_case_id = get_field(changeset, :recovery_case_id)

    cond do
      category == "stranded_work_recovery" and is_nil(recovery_case_id) ->
        add_error(changeset, :recovery_case_id, "is required for stranded work recovery")

      category != "stranded_work_recovery" and not is_nil(recovery_case_id) ->
        add_error(changeset, :category, "must be stranded_work_recovery when linked to recovery")

      true ->
        changeset
    end
  end

  defp validate_proposal_bounds(changeset) do
    proposal = get_field(changeset, :proposal_data)

    cond do
      is_nil(proposal) ->
        changeset

      not is_map(proposal) ->
        add_error(changeset, :proposal_data, "must be a map")

      true ->
        case Jason.encode(proposal) do
          {:ok, encoded} when byte_size(encoded) <= 32_768 -> changeset
          {:ok, _encoded} -> add_error(changeset, :proposal_data, "is too large")
          {:error, _} -> add_error(changeset, :proposal_data, "must be JSON encodable")
        end
    end
  end

  defp validate_recovery_company(changeset) do
    case {get_field(changeset, :recovery_case_id), get_field(changeset, :company_id)} do
      {nil, _} ->
        changeset

      {recovery_case_id, company_id} when is_binary(company_id) and company_id != "" ->
        case changeset.repo.get(Cympho.Recovery.RecoveryCase, recovery_case_id) do
          %{company_id: ^company_id} -> changeset
          nil -> changeset
          _ -> add_error(changeset, :recovery_case_id, "must belong to the approval company")
        end

      {_id, _company_id} ->
        add_error(changeset, :company_id, "is required for recovery linkage")
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
