defmodule Cympho.BoardApprovals do
  @moduledoc """
  The BoardApprovals context for managing board-level governance workflows.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.BoardApprovals.{BoardApproval, BoardApprovalVote}
  alias Cympho.GovernanceAuditLogs

  @doc """
  Returns the list of board approvals.
  """
  def list_board_approvals(opts \\ %{}) do
    query = from(ba in BoardApproval, order_by: [desc: ba.inserted_at])

    query =
      Enum.reduce(opts, query, fn
        {:company_id, id}, q ->
          where(q, [ba], ba.company_id == ^id)

        {:status, status}, q ->
          where(q, [ba], ba.status == ^status)

        {:category, category}, q ->
          where(q, [ba], ba.category == ^category)

        {:pending, true}, q ->
          where(q, [ba], ba.status == "pending")

        _, q ->
          q
      end)

    Repo.all(query)
    |> Repo.preload([:requested_by, :votes, :company])
  end

  @doc """
  Gets a single board approval.
  """
  def get_board_approval!(id) do
    Repo.get!(BoardApproval, id)
    |> Repo.preload([:requested_by, {:votes, [:user]}, :company])
  end

  def get_board_approval(id) do
    case Repo.get(BoardApproval, id) do
      nil -> {:error, :not_found}
      approval -> {:ok, Repo.preload(approval, [:requested_by, :company, {:votes, [:user]}])}
    end
  end

  @doc """
  Creates a board approval proposal.
  """
  def create_board_approval(attrs, actor \\ nil) do
    %BoardApproval{}
    |> BoardApproval.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, approval} ->
        approval = Repo.preload(approval, [:requested_by, :company])

        GovernanceAuditLogs.log_action(
          "board_proposal_created",
          actor || approval.requested_by,
          "Board approval requested: #{approval.title}",
          resource: approval,
          reasoning: approval.description,
          metadata: %{
            category: approval.category,
            proposal_data: approval.proposal_data
          }
        )

        Phoenix.PubSub.broadcast(Cympho.PubSub, "board_approvals", {:board_approval_created, approval})
        {:ok, approval}

      error ->
        error
    end
  end

  @doc """
  Records a board member vote on a proposal.
  """
  def cast_vote(board_approval_id, user_id, vote, reasoning \\ nil) do
    attrs = %{
      board_approval_id: board_approval_id,
      user_id: user_id,
      vote: vote,
      reasoning: reasoning
    }

    %BoardApprovalVote{}
    |> BoardApprovalVote.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, vote_record} ->
        board_approval = get_board_approval!(board_approval_id)

        GovernanceAuditLogs.log_action(
          "board_vote_cast",
          {"user", user_id},
          "Board vote cast: #{vote} on #{board_approval.title}",
          resource: board_approval,
          reasoning: reasoning,
          metadata: %{
            vote: vote,
            board_approval_id: board_approval_id
          }
        )

        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "board_approvals",
          {:board_vote_cast, vote_record}
        )

        check_auto_approve(board_approval)

        {:ok, vote_record}

      error ->
        error
    end
  end

  @doc """
  Resolves a board approval proposal.
  """
  def resolve_board_approval(board_approval_id, status, attrs, actor) do
    board_approval = Repo.get!(BoardApproval, board_approval_id)

    board_approval
    |> BoardApproval.approve_changeset(Map.put(attrs, :status, status))
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        updated = Repo.preload(updated, [:requested_by, :company])

        GovernanceAuditLogs.log_action(
          "board_decision",
          actor,
          "Board approval #{status}: #{updated.title}",
          resource: updated,
          reasoning: Map.get(attrs, :decision_reasoning),
          metadata: %{
            status: status,
            vote_summary: BoardApproval.vote_summary(updated)
          }
        )

        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "board_approvals",
          {:board_approval_resolved, updated}
        )

        maybe_trigger_action(updated)

        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Cancels a pending board approval.
  """
  def cancel_board_approval(board_approval_id, actor \\ nil) do
    board_approval = Repo.get!(BoardApproval, board_approval_id)

    if board_approval.status == "pending" do
      board_approval
      |> Ecto.Changeset.change(%{status: "cancelled"})
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          GovernanceAuditLogs.log_action(
            "board_proposal_cancelled",
            actor,
            "Board approval cancelled: #{updated.title}",
            resource: updated
          )

          Phoenix.PubSub.broadcast(
            Cympho.PubSub,
            "board_approvals",
            {:board_approval_cancelled, updated}
          )

          {:ok, updated}

        error ->
          error
      end
    else
      {:error, :not_pending}
    end
  end

  @doc """
  Checks and updates expired board approvals.
  """
  def check_expired_approvals do
    from(ba in BoardApproval,
      where: ba.status == "pending" and ba.review_deadline < ^DateTime.utc_now()
    )
    |> Repo.update_all(set: [status: "expired"])
  end

  @doc """
  Subscribes to board approval events.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "board_approvals")
  end


  @doc """
  Checks whether board approval is required for a given category
  based on the company's governance config.
  """
  def governance_config_required?(%Cympho.Companies.Company{} = company, category) do
    categories =
      company
      |> Map.get(:governance_config, %{})
      |> Map.get("categories", [])

    category in categories
  end

  defp check_auto_approve(%BoardApproval{} = board_approval) do
    if BoardApproval.approval_threshold_met?(board_approval) do
      resolve_board_approval(
        board_approval.id,
        "approved",
        %{
          decision_reasoning: "Auto-approved based on board vote threshold"
        },
        {"system", "system"}
      )
    end
  end

  defp maybe_trigger_action(%BoardApproval{status: "approved"} = board_approval) do
    case board_approval.category do
      "agent_termination" ->
        trigger_agent_termination(board_approval)

      "agent_promotion" ->
        trigger_agent_promotion(board_approval)

      "budget_increase" ->
        trigger_budget_increase(board_approval)

      "principal_permission" ->
        trigger_permission_grant(board_approval)

      _ ->
        :ok
    end
  end

  defp maybe_trigger_action(_), do: :ok

  defp trigger_agent_termination(board_approval) do
    agent_id = get_in(board_approval.proposal_data, ["agent_id"])

    if agent_id do
      Phoenix.PubSub.broadcast(
        Cympho.PubSub,
        "governance",
        {:agent_termination_approved, board_approval.id, agent_id}
      )
    end
  end

  defp trigger_agent_promotion(board_approval) do
    agent_id = get_in(board_approval.proposal_data, ["agent_id"])
    new_role = get_in(board_approval.proposal_data, ["new_role"])

    if agent_id and new_role do
      Phoenix.PubSub.broadcast(
        Cympho.PubSub,
        "governance",
        {:agent_promotion_approved, board_approval.id, agent_id, new_role}
      )
    end
  end

  defp trigger_budget_increase(board_approval) do
    budget_id = get_in(board_approval.proposal_data, ["budget_id"])
    new_limit = get_in(board_approval.proposal_data, ["new_limit"])

    if budget_id and new_limit do
      Phoenix.PubSub.broadcast(
        Cympho.PubSub,
        "governance",
        {:budget_increase_approved, board_approval.id, budget_id, new_limit}
      )
    end
  end

  defp trigger_permission_grant(board_approval) do
    principal_id = get_in(board_approval.proposal_data, ["principal_id"])
    permission = get_in(board_approval.proposal_data, ["permission"])

    if principal_id and permission do
      Phoenix.PubSub.broadcast(
        Cympho.PubSub,
        "governance",
        {:permission_grant_approved, board_approval.id, principal_id, permission}
      )
    end
  end
end
