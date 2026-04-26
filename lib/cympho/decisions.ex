defmodule Cympho.Decisions do
  @moduledoc """
  The Decisions context for tracking governance decisions with reversal support.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Decisions.{Decision, DecisionReversal}
  alias Cympho.GovernanceAuditLogs

  @doc """
  Returns the list of decisions.
  """
  def list_decisions(opts \\ %{}) do
    query = from(d in Decision, order_by: [desc: d.effective_at])

    query =
      Enum.reduce(opts, query, fn
        {:company_id, id}, q ->
          where(q, [d], d.company_id == ^id)

        {:decision_type, type}, q ->
          where(q, [d], d.decision_type == ^type)

        {:decision_key, key}, q ->
          where(q, [d], d.decision_key == ^key)

        {:status, status}, q ->
          where(q, [d], d.status == ^status)

        {:actor_type, type}, q ->
          where(q, [d], d.actor_type == ^type)

        {:actor_id, id}, q ->
          where(q, [d], d.actor_id == ^id)

        {:resource_type, type}, q ->
          where(q, [d], d.resource_type == ^type)

        {:resource_id, id}, q ->
          where(q, [d], d.resource_id == ^id)

        {:active, true}, q ->
          where(q, [d], d.status == "active")

        {:reversible, true}, q ->
          where(q, [d], d.reversible == true and is_nil(d.reversed_by_id))

        _, q ->
          q
      end)

    Repo.all(query)
    |> Repo.preload([:company, :child_decisions, :reversals])
  end

  @doc """
  Gets a single decision.
  """
  def get_decision!(id), do: Repo.get!(Decision, id)

  def get_decision(id) do
    case Repo.get(Decision, id) do
      nil -> {:error, :not_found}
      decision -> {:ok, Repo.preload(decision, [:company, :child_decisions, :reversals, :parent_decision])}
    end
  end

  @doc """
  Gets an active decision by key and parent.
  """
  def get_active_decision(decision_key, parent_decision_id \\ nil, company_id) do
    query =
      from(d in Decision,
        where:
          d.decision_key == ^decision_key and
            d.parent_decision_id == ^parent_decision_id and
            d.company_id == ^company_id and
            d.status == "active",
        order_by: [desc: d.effective_at],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      decision -> {:ok, decision}
    end
  end

  @doc """
  Creates a new decision.
  """
  def create_decision(attrs, actor \\ nil) do
    %Decision{}
    |> Decision.create_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, decision} ->
        decision = Repo.preload(decision, :company)

        GovernanceAuditLogs.log_action(
          "decision_created",
          actor || extract_actor(decision),
          "Decision recorded: #{decision.decision_type} - #{decision.outcome}",
          resource: decision,
          reasoning: decision.reasoning,
          metadata: Map.merge(decision.context, %{
            decision_key: decision.decision_key,
            resource: "#{decision.resource_type}:#{decision.resource_id}",
            reversible: decision.reversible
          })
        )

        Phoenix.PubSub.broadcast(Cympho.PubSub, "decisions", {:decision_created, decision})

        maybe_mark_parent_superseded(decision)

        {:ok, decision}

      error ->
        error
    end
  end

  @doc """
  Records a decision from a board approval.
  """
  def record_board_decision(board_approval, actor) do
    {actor_type, actor_id} =
      case actor do
        {type, id} when is_binary(type) and is_binary(id) -> {type, id}
        nil -> {"system", "00000000-0000-0000-0000-000000000000"}
      end

    attrs = %{
      decision_type: "board_approval",
      decision_key: "board_#{board_approval.id}",
      outcome: board_approval.status,
      reasoning: Map.get(board_approval, :decision_reasoning),
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: "board_approval",
      resource_id: board_approval.id,
      context: %{
        category: board_approval.category,
        proposal_data: board_approval.proposal_data
      },
      company_id: board_approval.company_id,
      metadata: %{
        board_approval_id: board_approval.id,
        requested_by_agent_id: board_approval.requested_by_agent_id
      }
    }

    create_decision(attrs, actor)
  end

  @doc """
  Records a decision from an issue approval.
  """
  def record_issue_decision(approval, actor) do
    attrs = %{
      decision_type: "issue_approval",
      decision_key: "issue_approval_#{approval.id}",
      outcome: approval.status,
      reasoning: approval.resolution_reason,
      actor_type: safe_actor_type(actor),
      actor_id: safe_actor_id(actor),
      resource_type: "approval",
      resource_id: approval.id,
      context: %{
        approval_id: approval.id,
        type: approval.type
      },
      metadata: %{
        approval_id: approval.id,
        requested_by_agent_id: approval.requested_by_agent_id
      }
    }

    create_decision(attrs, actor)
  end

  @doc """
  Records a governance decision (agent pause/resume/terminate).
  """
  def record_governance_decision(agent, action, outcome, actor) do
    attrs = %{
      decision_type: "agent_governance",
      decision_key: "agent_#{agent.id}_#{action}",
      outcome: outcome,
      reasoning: agent.governance_reasoning,
      actor_type: safe_actor_type(actor),
      actor_id: safe_actor_id(actor),
      resource_type: "agent",
      resource_id: agent.id,
      context: %{
        action: action,
        agent_name: agent.name,
        agent_role: agent.role
      },
      company_id: agent.company_id,
      reversible: action != "terminate",
      metadata: %{
        agent_id: agent.id,
        previous_status: agent.governance_status
      }
    }

    create_decision(attrs, actor)
  end

  @doc """
  Reverses a decision.
  """
  def reverse_decision(decision_id, reasoning, actor) do
    original_decision = Repo.get!(Decision, decision_id)

    if Decision.can_reverse?(original_decision) do
      Repo.transaction(fn ->
        attrs = %{
          decision_type: original_decision.decision_type,
          decision_key: "#{original_decision.decision_key}_reversal",
          outcome: "reversed",
          reasoning: reasoning,
          actor_type: elem(actor, 0),
          actor_id: elem(actor, 1),
          resource_type: original_decision.resource_type,
          resource_id: original_decision.resource_id,
          parent_decision_id: original_decision.id,
          context: Map.put(original_decision.context, :reversal_reasoning, reasoning),
          reversible: false,
          company_id: original_decision.company_id,
          metadata: Map.put(original_decision.metadata, :reversing_original_decision_id, original_decision.id)
        }

        with {:ok, reversing_decision} <-
               %Decision{}
               |> Decision.create_changeset(attrs)
               |> Repo.insert(),
             {:ok, _updated_original} <-
               original_decision
               |> Decision.reversal_changeset(%{reversed_by_id: reversing_decision.id})
               |> Repo.update(),
             {:ok, _reversal_link} <-
               %DecisionReversal{}
               |> DecisionReversal.changeset(%{
                 reasoning: reasoning,
                 actor_type: safe_actor_type(actor),
                 actor_id: safe_actor_id(actor),
                 original_decision_id: original_decision.id,
                 reversing_decision_id: reversing_decision.id,
                 company_id: original_decision.company_id
               })
               |> Repo.insert() do
          reversing_decision
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    else
      {:error, :not_reversible}
    end
  end

  @doc """
  Checks if a decision exists and is active for the given key.
  """
  def has_active_decision?(decision_key, parent_decision_id \\ nil, company_id) do
    case get_active_decision(decision_key, parent_decision_id, company_id) do
      {:ok, decision} -> Decision.active?(decision) and not Decision.expired?(decision)
      _ -> false
    end
  end

  @doc """
  Marks expired decisions as expired.
  """
  def mark_expired_decisions do
    from(d in Decision,
      where: d.status == "active" and d.expires_at < ^DateTime.utc_now()
    )
    |> Repo.update_all(set: [status: "expired"])
  end

  @doc """
  Subscribes to decision events.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "decisions")
  end

  @nil_uuid "00000000-0000-0000-0000-000000000000"

  defp extract_actor(%Decision{actor_type: type, actor_id: id}), do: {type, id}
  defp extract_actor(_), do: {"system", @nil_uuid}

  defp safe_actor_type(nil), do: "system"
  defp safe_actor_type({type, _}), do: type
  defp safe_actor_type(_), do: "unknown"

  defp safe_actor_id(nil), do: nil
  defp safe_actor_id({_, id}), do: id
  defp safe_actor_id(_), do: nil

  defp maybe_mark_parent_superseded(%Decision{parent_decision_id: nil}), do: :ok

  defp maybe_mark_parent_superseded(%Decision{parent_decision_id: parent_id} = decision) do
    if decision.outcome in ["approved", "implemented"] do
      from(d in Decision, where: d.id == ^parent_id)
      |> Repo.update_all(set: [status: "superseded"])

      Phoenix.PubSub.broadcast(Cympho.PubSub, "decisions", {:decision_superseded, parent_id})
    end

    :ok
  end
end
