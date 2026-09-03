defmodule Cympho.BoardApprovals do
  @moduledoc """
  The BoardApprovals context for managing board-level governance workflows.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.BoardApprovals.{BoardApproval, BoardApprovalEffect, BoardApprovalVote}
  alias Cympho.GovernanceAuditLogs
  alias Cympho.Decisions
  alias Cympho.AuditTrail.Instrumenter
  alias Cympho.Recovery
  alias Cympho.Recovery.RecoveryCase

  @nil_uuid "00000000-0000-0000-0000-000000000000"
  @execution_lease_seconds 300
  @resolution_batch_limit 100

  @doc """
  Atomically claims an approved approval for execution. A claim has a unique
  token and a bounded lease, so a different node can recover it after the
  original executor disappears or comes back under a different node name.
  """
  def claim_for_execution(approval_id) when is_binary(approval_id) do
    node_name = to_string(node())
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    lease_expires_at = DateTime.add(now, @execution_lease_seconds, :second)
    claim_token = Ecto.UUID.generate()

    query =
      from ba in BoardApproval,
        where:
          ba.id == ^approval_id and ba.status == "approved" and
            (is_nil(ba.execution_state) or
               (ba.execution_state == "claimed" and
                  (is_nil(ba.execution_lease_expires_at) or
                     ba.execution_lease_expires_at <= ^now)))

    updates = [
      executed_at: now,
      executor_node: node_name,
      execution_state: "claimed",
      execution_claim_token: claim_token,
      execution_lease_expires_at: lease_expires_at
    ]

    case Repo.update_all(query, set: updates) do
      {1, _} ->
        case Repo.get_by(BoardApproval, id: approval_id, execution_claim_token: claim_token) do
          nil -> {:error, :not_found}
          approval -> {:ok, Repo.preload(approval, [:requested_by, :votes, :company])}
        end

      {0, _} ->
        {:error, :already_executed}
    end
  end

  @doc """
  Records that a claimed approval actually executed.

  Until this exists, `executed_at` is only a claim: it says an executor started,
  not that the action happened.
  """
  def mark_executed(%BoardApproval{execution_claim_token: claim_token} = approval)
      when is_binary(claim_token) do
    mark_executed(approval.id, claim_token)
  end

  def mark_executed(%BoardApproval{}), do: {:error, :claim_lost}

  def mark_executed(approval_id, claim_token)
      when is_binary(approval_id) and is_binary(claim_token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from ba in BoardApproval,
        where:
          ba.id == ^approval_id and ba.execution_state == "claimed" and
            ba.execution_claim_token == ^claim_token

    case Repo.update_all(query,
           set: [
             executed_at: now,
             execution_state: "executed",
             execution_claim_token: nil,
             execution_lease_expires_at: nil
           ]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :claim_lost}
    end
  end

  @doc false
  def renew_execution_claim(%BoardApproval{execution_claim_token: claim_token} = approval)
      when is_binary(claim_token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    lease_expires_at = DateTime.add(now, @execution_lease_seconds, :second)

    query =
      from ba in BoardApproval,
        where:
          ba.id == ^approval.id and ba.execution_state == "claimed" and
            ba.execution_claim_token == ^claim_token

    case Repo.update_all(query, set: [execution_lease_expires_at: lease_expires_at]) do
      {1, _} -> :ok
      {0, _} -> {:error, :claim_lost}
    end
  end

  def renew_execution_claim(%BoardApproval{}), do: {:error, :claim_lost}

  @doc """
  Records that a claimed approval gave up after exhausting its retries.

  The claim is deliberately kept: an approval that failed five times should be
  visible to an operator rather than silently retried on every boot. Use
  `reclaim_for_retry/1` to put it back in the queue.
  """
  def mark_execution_failed(%BoardApproval{execution_claim_token: claim_token} = approval)
      when is_binary(claim_token) do
    mark_execution_failed(approval.id, claim_token)
  end

  def mark_execution_failed(%BoardApproval{}), do: {:error, :claim_lost}

  def mark_execution_failed(approval_id, claim_token)
      when is_binary(approval_id) and is_binary(claim_token) do
    query =
      from ba in BoardApproval,
        where:
          ba.id == ^approval_id and ba.execution_state == "claimed" and
            ba.execution_claim_token == ^claim_token

    case Repo.update_all(query,
           set: [
             execution_state: "failed",
             execution_claim_token: nil,
             execution_lease_expires_at: nil
           ]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :claim_lost}
    end
  end

  @doc """
  Reverts a claim — clears `executed_at` so a future retry can proceed.
  """
  def release_claim(approval_id) when is_binary(approval_id) do
    query = from ba in BoardApproval, where: ba.id == ^approval_id

    Repo.update_all(query,
      set: [
        executed_at: nil,
        executor_node: nil,
        execution_state: nil,
        execution_claim_token: nil,
        execution_lease_expires_at: nil
      ]
    )

    :ok
  end

  @doc """
  Releases abandoned claims so boot recovery can execute them.

  Retry state lives in the executor's mailbox as a `Process.send_after/3` timer.
  A crash or a redeploy during backoff discards it, and the claim alone made the
  approval invisible to replay forever. A claim is abandoned once its lease
  expires, regardless of the node name stamped on it.

  Returns the number of approvals released.
  """
  def reclaim_abandoned_claims(opts \\ []) do
    include_current_node? = Keyword.get(opts, :include_current_node, true)
    node_name = to_string(node())
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from ba in BoardApproval,
        where:
          ba.status == "approved" and ba.execution_state == "claimed" and
            (is_nil(ba.execution_lease_expires_at) or
               ba.execution_lease_expires_at <= ^now)

    query =
      if include_current_node? do
        from ba in BoardApproval,
          where:
            ba.status == "approved" and ba.execution_state == "claimed" and
              (ba.executor_node == ^node_name or is_nil(ba.execution_lease_expires_at) or
                 ba.execution_lease_expires_at <= ^now)
      else
        query
      end

    {released, _} =
      Repo.update_all(query,
        set: [
          executed_at: nil,
          executor_node: nil,
          execution_state: nil,
          execution_claim_token: nil,
          execution_lease_expires_at: nil
        ]
      )

    released
  end

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

  def count_pending_for_company(company_id) when is_binary(company_id) do
    from(ba in BoardApproval,
      where: ba.company_id == ^company_id and ba.status == "pending",
      select: count(ba.id)
    )
    |> Repo.one()
  end

  def count_pending_for_company(_company_id), do: 0

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

  def get_company_board_approval(company_id, id) do
    query =
      from a in BoardApproval, where: a.id == ^id and a.company_id == ^company_id

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      approval ->
        {:ok, Repo.preload(approval, [:requested_by, :company, {:votes, [:user]}])}
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

        Cympho.PubSubGuard.company_broadcast(
          approval.company_id,
          "approvals",
          {:board_approval_created, approval}
        )

        _ = Cympho.OwnerAttention.notify_changed(approval.company_id)

        {:ok, approval}

      error ->
        error
    end
  end

  @doc "Inserts a stranded-work recovery approval inside an existing transaction."
  def create_recovery_approval(attrs, _opts \\ []) when is_map(attrs) do
    supplied_category = Map.get(attrs, :category) || Map.get(attrs, "category")
    recovery_case_id = Map.get(attrs, :recovery_case_id) || Map.get(attrs, "recovery_case_id")
    company_id = Map.get(attrs, :company_id) || Map.get(attrs, "company_id")

    cond do
      supplied_category not in [nil, "stranded_work_recovery", :stranded_work_recovery] ->
        {:error,
         %Ecto.Changeset{}
         |> Ecto.Changeset.add_error(:category, "must be stranded_work_recovery")}

      is_nil(recovery_case_id) ->
        {:error,
         %Ecto.Changeset{}
         |> Ecto.Changeset.add_error(:recovery_case_id, "is required")}

      not recovery_case_matches_company?(recovery_case_id, company_id) ->
        {:error,
         %Ecto.Changeset{}
         |> Ecto.Changeset.add_error(:recovery_case_id, "must belong to the approval company")}

      true ->
        attrs =
          attrs
          # String-keyed params are common at controller boundaries. Remove
          # caller-supplied category/status values before adding the
          # authoritative recovery values; otherwise a string key can shadow
          # the atom key during Ecto casting.
          |> Map.delete("category")
          |> Map.delete("status")
          |> Map.put(:category, "stranded_work_recovery")
          |> Map.put(:status, "pending")

        %BoardApproval{}
        |> BoardApproval.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, approval} ->
            {:ok, approval}

          {:error, changeset} = error ->
            if recovery_unique_error?(changeset) do
              case Repo.one(
                     from a in BoardApproval,
                       where:
                         a.recovery_case_id == ^recovery_case_id and
                           a.company_id == ^company_id,
                       lock: "FOR UPDATE"
                   ) do
                %BoardApproval{
                  category: "stranded_work_recovery",
                  status: "pending",
                  company_id: ^company_id
                } = existing ->
                  {:ok, existing}

                _ ->
                  error
              end
            else
              error
            end
        end
    end
  end

  defp recovery_unique_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp recovery_unique_error?(_), do: false

  defp recovery_case_matches_company?(case_id, company_id)
       when is_binary(case_id) and is_binary(company_id) and company_id != "" do
    case Repo.get(Cympho.Recovery.RecoveryCase, case_id) do
      %{company_id: ^company_id} -> true
      _ -> false
    end
  end

  defp recovery_case_matches_company?(_, _), do: false

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

    transaction_result =
      Repo.transaction(fn ->
        board_approval = lock_pending_board_approval_for_transition!(board_approval_id)

        vote_record =
          %BoardApprovalVote{}
          |> BoardApprovalVote.changeset(attrs)
          |> Repo.insert()
          |> case do
            {:ok, vote_record} -> vote_record
            {:error, changeset} -> Repo.rollback(changeset)
          end

        actor = {"system", @nil_uuid}
        resolved = maybe_auto_approve_locked(board_approval)
        decision = if resolved, do: insert_board_decision!(resolved, actor)
        {vote_record, board_approval, resolved, decision}
      end)

    case transaction_result do
      {:ok, {vote_record, board_approval, resolved, decision}} ->
        board_approval = Repo.preload(board_approval, [:requested_by, :company])

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

        # Record audit event for board vote
        _ =
          Instrumenter.record_board_vote(
            board_approval,
            vote,
            "user",
            user_id
          )

        Cympho.PubSubGuard.company_broadcast(
          board_approval.company_id,
          "approvals",
          {:board_vote_cast, vote_record}
        )

        if resolved do
          publish_resolution(resolved, {"system", @nil_uuid}, decision, :unchanged)
        end

        {:ok, vote_record}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resolves a board approval proposal.
  """
  def resolve_board_approval(board_approval_id, status, attrs, actor) do
    transaction_result =
      Repo.transaction(fn ->
        board_approval = lock_pending_board_approval_for_transition!(board_approval_id)

        if status == "approved" and BoardApproval.expired?(board_approval) do
          {:ok, expired} =
            board_approval
            |> Ecto.Changeset.change(%{
              status: "expired",
              decision_reasoning: "Review deadline passed"
            })
            |> Repo.update()

          recovery_effect = resolve_recovery_case_locked!(expired, expired.decision_reasoning)
          {:expired, expired, recovery_effect}
        else
          updated =
            board_approval
            |> BoardApproval.approve_changeset(Map.put(attrs, :status, status))
            |> Repo.update()
            |> case do
              {:ok, updated} -> updated
              {:error, changeset} -> Repo.rollback(changeset)
            end

          decision = insert_board_decision!(updated, actor)
          recovery_effect = resolve_recovery_case_locked!(updated, updated.decision_reasoning)
          {:resolved, updated, decision, recovery_effect}
        end
      end)

    case transaction_result do
      {:ok, {:expired, expired, recovery_effect}} ->
        publish_expiration(expired, recovery_effect)
        {:error, :approval_expired}

      {:ok, {:resolved, updated, decision, recovery_effect}} ->
        {:ok, publish_resolution(updated, actor, decision, recovery_effect)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_board_decision!(board_approval, actor) do
    board_approval
    |> Decisions.board_decision_changeset(actor)
    |> Repo.insert()
    |> case do
      {:ok, decision} -> decision
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc """
  Cancels a pending board approval.
  """
  def cancel_board_approval(board_approval_id, actor \\ nil) do
    transaction_result =
      Repo.transaction(fn ->
        board_approval_id
        |> lock_pending_board_approval_for_transition!()
        |> Ecto.Changeset.change(%{status: "cancelled"})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            recovery_effect =
              resolve_recovery_case_locked!(updated, updated.decision_reasoning)

            {updated, recovery_effect}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    case transaction_result do
      {:ok, {updated, recovery_effect}} ->
        recovery_published? = publish_recovery_resolution(recovery_effect)

        GovernanceAuditLogs.log_action(
          "board_proposal_cancelled",
          actor,
          "Board approval cancelled: #{updated.title}",
          resource: updated
        )

        Cympho.PubSubGuard.company_broadcast(
          updated.company_id,
          "approvals",
          {:board_approval_cancelled, updated}
        )

        Cympho.PubSubGuard.broadcast(
          "system:board_approvals",
          {:board_approval_cancelled, updated}
        )

        unless recovery_published? do
          _ = Cympho.OwnerAttention.notify_changed(updated.company_id)
        end

        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks and updates expired board approvals.
  """
  def check_expired_approvals do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ids =
      Repo.all(
        from ba in BoardApproval,
          where:
            ba.status == "pending" and not is_nil(ba.review_deadline) and
              ba.review_deadline <= ^now,
          order_by: [asc: ba.review_deadline],
          select: ba.id,
          limit: @resolution_batch_limit
      )

    expired =
      Enum.flat_map(ids, fn id ->
        case Repo.transaction(fn ->
               approval = lock_pending_board_approval_for_transition!(id)

               if approval.review_deadline &&
                    DateTime.compare(approval.review_deadline, now) != :gt do
                 {:ok, updated} =
                   approval
                   |> Ecto.Changeset.change(%{
                     status: "expired",
                     decision_reasoning: "Review deadline passed"
                   })
                   |> Repo.update()

                 recovery_effect =
                   resolve_recovery_case_locked!(updated, updated.decision_reasoning)

                 {updated, recovery_effect}
               else
                 nil
               end
             end) do
          {:ok, {%BoardApproval{} = approval, recovery_effect}} ->
            [{approval, recovery_effect}]

          _ ->
            []
        end
      end)

    Enum.each(expired, fn {approval, recovery_effect} ->
      publish_expiration(approval, recovery_effect)
    end)

    {length(expired), nil}
  end

  @doc "Reconciles persisted terminal recovery approvals after a restart."
  def reconcile_recovery_resolutions(opts \\ []) when is_list(opts) do
    limit = reconciliation_limit(opts)

    approvals =
      Repo.all(
        from ba in BoardApproval,
          join: recovery_case in RecoveryCase,
          on: recovery_case.id == ba.recovery_case_id,
          where:
            ba.category == "stranded_work_recovery" and
              ba.status in ["denied", "expired", "cancelled"] and
              ba.company_id == recovery_case.company_id and
              recovery_case.state in ^RecoveryCase.active_states(),
          order_by: [asc: ba.inserted_at, asc: ba.id],
          limit: ^limit
      )

    Enum.count(approvals, fn approval ->
      Recovery.handle_approval_resolution(approval) == :ok
    end)
  rescue
    _ -> 0
  end

  defp publish_expiration(%BoardApproval{} = approval, recovery_effect) do
    approval = Repo.preload(approval, [:requested_by, :company])
    recovery_published? = publish_recovery_resolution(recovery_effect)

    GovernanceAuditLogs.log_action(
      "board_decision",
      {"system", approval.company_id},
      "Board approval expired: #{approval.title}",
      resource: approval,
      metadata: %{status: "expired", category: approval.category}
    )

    Cympho.PubSubGuard.company_broadcast(
      approval.company_id,
      "approvals",
      {:board_approval_resolved, approval}
    )

    Cympho.PubSubGuard.broadcast(
      "system:board_approvals",
      {:board_approval_resolved, approval}
    )

    unless recovery_published? do
      _ = Cympho.OwnerAttention.notify_changed(approval.company_id)
    end

    :ok
  end

  @doc """
  Subscribes to board approval events.
  """
  def subscribe(company_id) when is_binary(company_id) and company_id != "" do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:approvals")
  end

  def subscribe(_company_id), do: :ok

  @doc """
  Checks whether a given governance category requires board approval
  for the company based on its governance_config.

  Returns true if the category is listed in the company's required approvals.
  Defaults to false when no governance_config is set.
  """
  def governance_required?(%Cympho.Companies.Company{} = company, category) do
    config = Map.get(company, :governance_config) || %{}

    required =
      Map.get(config, "categories") ||
        Map.get(config, "required_approvals") ||
        Map.get(config, :required_approvals) || []

    category in required
  end

  def governance_required?(company_id, category) when is_binary(company_id) do
    case Cympho.Repo.get(Cympho.Companies.Company, company_id) do
      nil -> false
      company -> governance_required?(company, category)
    end
  end

  # --- Agent Approval Workflows ---

  @doc """
  Proposes hiring a new agent. If board approval is required for the company,
  creates a pending proposal. Otherwise, hires the agent directly.
  """
  def propose_agent_hire(company_id, agent_attrs, requested_by \\ nil) do
    if governance_required?(company_id, "agent_hire") do
      create_board_approval(
        %{
          title: "Hire Agent: #{agent_attrs["name"] || agent_attrs[:name] || "Unnamed"}",
          description: "Request to hire a new agent.",
          category: "agent_hire",
          company_id: company_id,
          requested_by_agent_id: extract_agent_id(requested_by),
          proposal_data: %{
            "agent_attrs" => agent_attrs
          },
          review_deadline: DateTime.utc_now() |> DateTime.add(7 * 24 * 3600, :second)
        },
        requested_by
      )
    else
      Cympho.Agents.create_agent(agent_attrs)
    end
  end

  @doc """
  Proposes changing an agent's role. If board approval is required,
  creates a pending proposal. Otherwise, updates the role directly.
  """
  def propose_role_change(company_id, agent_id, new_role, requested_by \\ nil) do
    if governance_required?(company_id, "agent_promotion") do
      with {:ok, agent} <- Cympho.Agents.get_agent(agent_id) do
        create_board_approval(
          %{
            title: "Role Change: #{agent.name} → #{new_role}",
            description:
              "Request to change role of agent #{agent.name} from #{agent.role} to #{new_role}.",
            category: "agent_promotion",
            company_id: company_id,
            requested_by_agent_id: extract_agent_id(requested_by),
            proposal_data: %{
              "agent_id" => agent_id,
              "new_role" => to_string(new_role),
              "current_role" => to_string(agent.role)
            },
            review_deadline: DateTime.utc_now() |> DateTime.add(7 * 24 * 3600, :second)
          },
          requested_by
        )
      end
    else
      with {:ok, agent} <- Cympho.Agents.get_agent(agent_id) do
        Cympho.Agents.update_agent(agent, %{role: new_role})
      end
    end
  end

  # --- Budget Approval Workflows ---

  @doc """
  Proposes a budget increase. If board approval is required, creates a
  pending proposal. Otherwise, applies the change directly.
  """
  def propose_budget_change(company_id, budget_id, new_limit, requested_by \\ nil) do
    if governance_required?(company_id, "budget_increase") and
         budget_is_increase?(budget_id, new_limit) do
      create_board_approval(
        %{
          title: "Budget Increase: #{budget_id}",
          description: "Request to increase budget limit.",
          category: "budget_increase",
          company_id: company_id,
          requested_by_agent_id: extract_agent_id(requested_by),
          proposal_data: %{
            "action" => "update_budget",
            "budget_id" => budget_id,
            "new_limit" => new_limit,
            "update_attrs" => %{"limit_amount" => new_limit}
          },
          review_deadline: DateTime.utc_now() |> DateTime.add(7 * 24 * 3600, :second)
        },
        requested_by
      )
    else
      apply_budget_change(company_id, budget_id, new_limit)
    end
  end

  defp budget_is_increase?(budget_id, new_limit) do
    case Cympho.Budgets.get_budget(budget_id) do
      {:ok, budget} ->
        new_dec = parse_decimal(new_limit)
        new_dec != nil and Decimal.gt?(new_dec, budget.limit_amount || Decimal.new(0))

      {:error, :not_found} ->
        true
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(%Decimal{} = d), do: d
  defp parse_decimal(v) when is_integer(v), do: Decimal.new(v)
  defp parse_decimal(v) when is_float(v), do: Decimal.from_float(v)
  defp parse_decimal(v) when is_binary(v), do: Decimal.new(v)

  @doc """
  Proposes a company config change requiring board approval.
  """
  def propose_config_change(company_id, config_key, config_value, requested_by \\ nil) do
    update_attrs = %{to_string(config_key) => config_value}

    if governance_required?(company_id, "policy_change") do
      create_board_approval(
        %{
          title: "Config Change: #{config_key}",
          description: "Request to change company config #{config_key}.",
          category: "policy_change",
          company_id: company_id,
          requested_by_agent_id: extract_agent_id(requested_by),
          proposal_data: %{
            "action" => "update_company",
            "company_id" => company_id,
            "config_key" => config_key,
            "config_value" => config_value,
            "update_attrs" => stringify_keys(update_attrs)
          },
          review_deadline: DateTime.utc_now() |> DateTime.add(7 * 24 * 3600, :second)
        },
        requested_by
      )
    else
      apply_config_change(company_id, config_key, config_value)
    end
  end

  @doc """
  Proposes a strategic initiative requiring board review.
  Strategy approvals cover major plan changes, new directions, and
  significant pivots that require board-level visibility and sign-off.
  """
  def propose_strategic_initiative(
        company_id,
        title,
        description,
        proposal_data,
        requested_by \\ nil
      ) do
    if governance_required?(company_id, "strategic_initiative") do
      create_board_approval(
        %{
          title: title,
          description: description,
          category: "strategic_initiative",
          company_id: company_id,
          requested_by_agent_id: extract_agent_id(requested_by),
          proposal_data: proposal_data,
          review_deadline: DateTime.utc_now() |> DateTime.add(14 * 24 * 3600, :second)
        },
        requested_by
      )
    else
      {:ok, :auto_approved}
    end
  end

  defp apply_budget_change(company_id, budget_id, new_limit) do
    company = Cympho.Repo.get!(Cympho.Companies.Company, company_id)
    config = company.governance_config || %{}
    budgets = Map.get(config, "budgets", %{})
    updated_budgets = Map.put(budgets, budget_id, new_limit)
    updated_config = Map.put(config, "budgets", updated_budgets)

    result =
      company
      |> Ecto.Changeset.change(%{governance_config: updated_config})
      |> Cympho.Repo.update()

    case result do
      {:ok, updated} ->
        GovernanceAuditLogs.log_action(
          "budget_change_applied_directly",
          {"system", @nil_uuid},
          "Budget config applied directly (no governance required): #{budget_id}",
          resource: updated,
          metadata: %{budget_id: budget_id, new_limit: new_limit}
        )

        {:ok, updated}

      error ->
        error
    end
  end

  defp apply_config_change(company_id, config_key, config_value) do
    company = Cympho.Repo.get!(Cympho.Companies.Company, company_id)
    config = company.governance_config || %{}
    updated_config = Map.put(config, config_key, config_value)

    result =
      company
      |> Ecto.Changeset.change(%{governance_config: updated_config})
      |> Cympho.Repo.update()

    case result do
      {:ok, updated} ->
        GovernanceAuditLogs.log_action(
          "config_change_applied_directly",
          {"system", @nil_uuid},
          "Company config applied directly (no governance required): #{config_key}",
          resource: updated,
          metadata: %{config_key: config_key}
        )

        {:ok, updated}

      error ->
        error
    end
  end

  defp extract_agent_id(nil), do: nil
  defp extract_agent_id(%Cympho.Agents.Agent{id: id}), do: id
  defp extract_agent_id(id) when is_binary(id), do: id
  defp extract_agent_id({"agent", id}), do: id
  defp extract_agent_id(_), do: nil

  defp lock_pending_board_approval!(board_approval_id) do
    board_approval =
      BoardApproval
      |> where([ba], ba.id == ^board_approval_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

    if board_approval.status == "pending" do
      board_approval
    else
      Repo.rollback(:not_pending)
    end
  end

  defp lock_pending_board_approval_for_transition!(board_approval_id) do
    case Repo.get(BoardApproval, board_approval_id) do
      %BoardApproval{
        category: "stranded_work_recovery",
        recovery_case_id: recovery_case_id
      } = locator
      when is_binary(recovery_case_id) ->
        _ =
          Repo.one(
            from case_row in RecoveryCase,
              where: case_row.id == ^recovery_case_id,
              lock: "FOR UPDATE"
          )

        locked = lock_pending_board_approval!(board_approval_id)

        if locked.category == locator.category and
             locked.recovery_case_id == recovery_case_id and
             locked.company_id == locator.company_id do
          locked
        else
          Repo.rollback(:approval_changed)
        end

      _non_recovery_or_malformed ->
        lock_pending_board_approval!(board_approval_id)
    end
  end

  defp resolve_recovery_case_locked!(
         %BoardApproval{
           category: "stranded_work_recovery",
           status: status
         } = approval,
         reason
       )
       when status in ["denied", "expired", "cancelled"] do
    case Recovery.resolve_approval_case_locked(approval, reason) do
      {:error, error} -> Repo.rollback(error)
      effect -> effect
    end
  end

  defp resolve_recovery_case_locked!(%BoardApproval{}, _reason), do: :unchanged

  defp publish_recovery_resolution(:unchanged), do: false

  defp publish_recovery_resolution({:changed, _descriptor} = effect) do
    :ok = Recovery.publish_approval_resolution(effect)
    true
  end

  defp reconciliation_limit(opts) do
    case Keyword.get(opts, :limit, @resolution_batch_limit) do
      limit when is_integer(limit) and limit > 0 -> min(limit, @resolution_batch_limit)
      _ -> @resolution_batch_limit
    end
  end

  defp maybe_auto_approve_locked(%BoardApproval{} = board_approval) do
    threshold_opts = load_threshold_opts(board_approval.company_id)

    if BoardApproval.approval_threshold_met?(board_approval, threshold_opts) do
      board_approval
      |> BoardApproval.approve_changeset(%{
        status: "approved",
        decision_reasoning: "Auto-approved based on board vote threshold"
      })
      |> Repo.update()
      |> case do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback(changeset)
      end
    else
      nil
    end
  end

  defp publish_resolution(%BoardApproval{} = updated, actor, decision, recovery_effect) do
    updated = Repo.preload(updated, [:requested_by, :company])
    decision = Repo.preload(decision, :company)
    recovery_published? = publish_recovery_resolution(recovery_effect)

    GovernanceAuditLogs.log_action(
      "board_decision",
      actor,
      "Board approval #{updated.status}: #{updated.title}",
      resource: updated,
      reasoning: updated.decision_reasoning,
      metadata: %{
        status: updated.status,
        vote_summary: BoardApproval.vote_summary(updated)
      }
    )

    Decisions.dispatch_created_decision(decision, actor)

    Cympho.PubSubGuard.company_broadcast(
      updated.company_id,
      "approvals",
      {:board_approval_resolved, updated}
    )

    Cympho.PubSubGuard.broadcast(
      "system:board_approvals",
      {:board_approval_resolved, updated}
    )

    unless recovery_published? do
      _ = Cympho.OwnerAttention.notify_changed(updated.company_id)
    end

    updated
  end

  defp load_threshold_opts(company_id) do
    company = Cympho.Repo.get(Cympho.Companies.Company, company_id)
    config = (company && company.governance_config) || %{}
    board_size = length(Cympho.Companies.list_board_members(company_id))

    [
      threshold_type: Map.get(config, "threshold_type", "percentage"),
      threshold_value: Map.get(config, "threshold_value", 0.6),
      min_quorum: min(3, max(1, board_size))
    ]
  end

  @doc """
  Executes the approved action for a board approval.
  Called by BoardApprovalActionExecutor GenServer for async execution.

  The durable effect row and the database side effect commit in the same
  transaction. If the executor dies before commit, both roll back; if it dies
  after commit, a retry observes the unique effect row and does nothing.
  """
  def execute_approved_action(%BoardApproval{id: approval_id}) when is_binary(approval_id) do
    # A struct delivered over PubSub (or fabricated by a caller) is only a
    # locator. Reload the persisted row before selecting an action category so
    # stale/forged status and proposal data cannot execute governance work.
    case Repo.get(BoardApproval, approval_id) do
      %BoardApproval{status: "approved"} = persisted ->
        execute_action_once(persisted, fn -> dispatch_approved_action(persisted) end)

      _ ->
        :ok
    end
  end

  def execute_approved_action(_), do: :ok

  @doc false
  def execute_action_once(%BoardApproval{id: approval_id} = caller, action)
      when is_binary(approval_id) and is_function(action, 0) do
    case Repo.get(BoardApproval, approval_id) do
      %BoardApproval{status: "approved"} = persisted
      when caller.category == persisted.category and caller.company_id == persisted.company_id ->
        do_execute_action_once(persisted, action)

      _ ->
        {:error, :not_approved}
    end
  end

  defp do_execute_action_once(%BoardApproval{} = board_approval, action) do
    effect_key = "board_approval:#{board_approval.id}:#{board_approval.category}"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    transaction_result =
      Repo.transaction(fn ->
        {inserted, _} =
          Repo.insert_all(
            BoardApprovalEffect,
            [
              %{
                id: Ecto.UUID.generate(),
                board_approval_id: board_approval.id,
                effect_key: effect_key,
                category: board_approval.category,
                inserted_at: now,
                updated_at: now
              }
            ],
            on_conflict: :nothing,
            conflict_target: [:board_approval_id]
          )

        if inserted == 0 do
          :already_executed
        else
          case action.() do
            {:error, :already_executed} -> :already_executed
            {:error, reason} -> Repo.rollback({:effect_failed, reason})
            result -> result
          end
        end
      end)

    case transaction_result do
      {:ok, :already_executed} ->
        :ok

      {:ok, {:ok, %Cympho.Recovery.RecoveryCase{} = child} = result}
      when board_approval.category == "stranded_work_recovery" ->
        _ = Cympho.Recovery.publish_retry_applied(board_approval, child, nil, nil)
        result

      {:ok, result} ->
        result

      {:error, {:effect_failed, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_approved_action(board_approval) do
    case board_approval.category do
      "agent_hire" ->
        trigger_agent_hire(board_approval)

      "agent_termination" ->
        trigger_agent_termination(board_approval)

      "agent_promotion" ->
        trigger_agent_promotion(board_approval)

      "budget_increase" ->
        trigger_budget_increase(board_approval)

      "policy_change" ->
        trigger_policy_change(board_approval)

      "principal_permission" ->
        trigger_permission_grant(board_approval)

      "strategic_initiative" ->
        trigger_strategic_initiative(board_approval)

      "stranded_work_recovery" ->
        case Cympho.Recovery.apply_board_action(board_approval, defer_side_effects: true) do
          {:error, :stale_recovery_proposal} -> :already_executed
          other -> other
        end

      _ ->
        :ok
    end
  end

  defp trigger_agent_hire(board_approval) do
    proposal_data = board_approval.proposal_data || %{}

    agent_attrs =
      Map.get(proposal_data, "attrs") || Map.get(proposal_data, "agent_attrs") ||
        Map.get(proposal_data, "agent_params") || %{}

    case Cympho.Agents.do_create_agent(agent_attrs) do
      {:ok, agent} ->
        GovernanceAuditLogs.log_action(
          "agent_hire_executed",
          {"board_approval", board_approval.id},
          "Agent hired via board approval: #{agent.name}",
          resource: agent,
          metadata: %{board_approval_id: board_approval.id, agent_id: agent.id}
        )

        Cympho.PubSubGuard.company_broadcast(
          board_approval.company_id,
          "governance",
          {:agent_hire_approved, board_approval.id, agent}
        )

        {:ok, agent}

      {:error, changeset} ->
        GovernanceAuditLogs.log_action(
          "agent_hire_failed",
          {"board_approval", board_approval.id},
          "Agent hire failed after board approval",
          metadata: %{board_approval_id: board_approval.id, errors: inspect(changeset.errors)}
        )

        {:error, changeset}
    end
  end

  defp trigger_agent_termination(board_approval) do
    agent_id = get_in(board_approval.proposal_data, ["agent_id"])

    if agent_id do
      case Cympho.Agents.get_agent(agent_id) do
        {:ok, agent} ->
          actor = {"system", board_approval.id}
          reason = board_approval.description || "Board-approved agent termination"

          case Cympho.AgentGovernance.terminate_agent(
                 agent.id,
                 reason,
                 [requires_board_approval: false],
                 actor
               ) do
            {:ok, terminated} ->
              GovernanceAuditLogs.log_action(
                "agent_termination_executed",
                actor,
                "Agent terminated via board approval: #{terminated.name}",
                resource: terminated,
                metadata: %{board_approval_id: board_approval.id, agent_id: agent_id}
              )

              Cympho.PubSubGuard.company_broadcast(
                board_approval.company_id,
                "governance",
                {:agent_termination_approved, board_approval.id, agent_id}
              )

              {:ok, terminated}

            error ->
              error
          end

        {:error, _} ->
          {:error, :agent_not_found}
      end
    else
      {:error, :invalid_proposal_data}
    end
  end

  defp trigger_agent_promotion(board_approval) do
    agent_id = get_in(board_approval.proposal_data, ["agent_id"])
    new_role = get_in(board_approval.proposal_data, ["new_role"])

    if agent_id != nil and new_role != nil do
      case Cympho.Agents.get_agent(agent_id) do
        {:ok, agent} ->
          case Cympho.Agents.do_update_agent(agent, %{role: new_role}) do
            {:ok, updated} ->
              GovernanceAuditLogs.log_action(
                "agent_promotion_executed",
                {"board_approval", board_approval.id},
                "Agent #{agent.name} promoted to #{new_role}",
                resource: updated,
                metadata: %{
                  board_approval_id: board_approval.id,
                  agent_id: agent_id,
                  new_role: new_role
                }
              )

              Cympho.PubSubGuard.company_broadcast(
                board_approval.company_id,
                "governance",
                {:agent_promotion_approved, board_approval.id, agent_id, new_role}
              )

              {:ok, updated}

            error ->
              error
          end

        {:error, _} ->
          {:error, :agent_not_found}
      end
    else
      {:error, :invalid_proposal_data}
    end
  end

  # Budget create/update go through Cympho.Budgets, which syncs Finances.BudgetPolicy
  # so board-approved hard_stop is enforced by Runtime.preflight (not LiveView-only).
  defp trigger_budget_increase(board_approval) do
    action = get_in(board_approval.proposal_data, ["action"])
    actor = nil
    meta = %{board_approval_id: board_approval.id}

    case action do
      "create_budget" ->
        attrs =
          board_approval.proposal_data
          |> get_in(["budget_attrs"])
          |> bind_budget_company(board_approval.company_id)

        case Cympho.Budgets.create_budget(attrs, actor, skip_governance: true) do
          {:ok, budget} ->
            GovernanceAuditLogs.log_action(
              "budget_creation_executed",
              actor,
              "Budget created via board approval: #{budget.name}",
              resource: budget,
              metadata: Map.put(meta, :budget_id, budget.id)
            )

            Cympho.PubSubGuard.company_broadcast(
              board_approval.company_id,
              "governance",
              {:budget_creation_approved, board_approval.id, budget}
            )

            {:ok, budget}

          {:error, changeset} ->
            GovernanceAuditLogs.log_action(
              "budget_creation_execution_failed",
              actor,
              "Budget creation failed after board approval",
              resource: board_approval,
              metadata: Map.put(meta, :errors, traverse_errors(changeset))
            )

            {:error, changeset}
        end

      "update_budget" ->
        budget_id = get_in(board_approval.proposal_data, ["budget_id"])

        update_attrs =
          board_approval.proposal_data
          |> get_in(["update_attrs"])
          |> bind_budget_company(board_approval.company_id)

        if budget_id do
          case Cympho.Budgets.get_company_budget(board_approval.company_id, budget_id) do
            {:ok, budget} ->
              case Cympho.Budgets.update_budget(budget, update_attrs, actor,
                     skip_governance: true
                   ) do
                {:ok, updated} ->
                  GovernanceAuditLogs.log_action(
                    "budget_increase_executed",
                    actor,
                    "Budget limit increased via board approval: #{updated.name}",
                    resource: updated,
                    metadata: Map.put(meta, :budget_id, budget_id)
                  )

                  Cympho.PubSubGuard.company_broadcast(
                    board_approval.company_id,
                    "governance",
                    {:budget_increase_approved, board_approval.id, budget_id,
                     updated.limit_amount}
                  )

                  {:ok, updated}

                {:error, changeset} ->
                  GovernanceAuditLogs.log_action(
                    "budget_increase_execution_failed",
                    actor,
                    "Budget update failed after board approval",
                    resource: board_approval,
                    metadata:
                      Map.merge(meta, %{budget_id: budget_id, errors: traverse_errors(changeset)})
                  )

                  {:error, changeset}
              end

            {:error, :not_found} ->
              GovernanceAuditLogs.log_action(
                "budget_increase_execution_failed",
                nil,
                "Budget not found for approved increase",
                resource: board_approval,
                metadata: %{budget_id: budget_id}
              )

              {:error, :not_found}
          end
        else
          {:error, :missing_budget_id}
        end

      _ ->
        # Legacy: broadcast-only for backward compat
        budget_id = get_in(board_approval.proposal_data, ["budget_id"])
        new_limit = get_in(board_approval.proposal_data, ["new_limit"])

        if budget_id != nil and new_limit != nil do
          Cympho.PubSubGuard.company_broadcast(
            board_approval.company_id,
            "governance",
            {:budget_increase_approved, board_approval.id, budget_id, new_limit}
          )
        else
          {:error, :invalid_proposal_data}
        end
    end
  end

  defp trigger_policy_change(board_approval) do
    action = get_in(board_approval.proposal_data, ["action"])
    meta = %{board_approval_id: board_approval.id}

    if action == "update_company" do
      company_id = get_in(board_approval.proposal_data, ["company_id"])
      update_attrs = get_in(board_approval.proposal_data, ["update_attrs"]) || %{}

      if company_id do
        case Cympho.Repo.get(Cympho.Companies.Company, company_id) do
          nil ->
            GovernanceAuditLogs.log_action(
              "policy_change_execution_failed",
              nil,
              "Company not found for approved policy change",
              resource: board_approval,
              metadata: Map.put(meta, :company_id, company_id)
            )

            {:error, :not_found}

          company ->
            case Cympho.Companies.execute_company_update(company, update_attrs) do
              {:ok, updated} ->
                GovernanceAuditLogs.log_action(
                  "policy_change_executed",
                  nil,
                  "Company config update executed after board approval",
                  resource: updated,
                  metadata: meta
                )

                Cympho.PubSubGuard.company_broadcast(
                  board_approval.company_id,
                  "governance",
                  {:policy_change_approved, board_approval.id, updated}
                )

                {:ok, updated}

              {:error, changeset} ->
                GovernanceAuditLogs.log_action(
                  "policy_change_execution_failed",
                  nil,
                  "Company config update failed after board approval",
                  resource: board_approval,
                  metadata: Map.put(meta, :errors, traverse_errors(changeset))
                )

                {:error, changeset}
            end
        end
      else
        {:error, :missing_company_id}
      end
    else
      {:error, :unknown_action}
    end
  end

  defp trigger_permission_grant(board_approval) do
    principal_id = get_in(board_approval.proposal_data, ["principal_id"])
    permission = get_in(board_approval.proposal_data, ["permission"])

    if principal_id != nil and permission != nil do
      Cympho.PubSubGuard.company_broadcast(
        board_approval.company_id,
        "governance",
        {:permission_grant_approved, board_approval.id, principal_id, permission}
      )
    else
      {:error, :invalid_proposal_data}
    end
  end

  defp trigger_strategic_initiative(board_approval) do
    GovernanceAuditLogs.log_action(
      "strategic_initiative_approved",
      {"board_approval", board_approval.id},
      "Strategic initiative approved: #{board_approval.title}",
      resource: board_approval,
      reasoning: board_approval.description,
      metadata: %{
        board_approval_id: board_approval.id,
        proposal_data: board_approval.proposal_data
      }
    )

    Cympho.PubSubGuard.company_broadcast(
      board_approval.company_id,
      "governance",
      {:strategic_initiative_approved, board_approval.id, board_approval.proposal_data}
    )

    {:ok, board_approval}
  end

  defp traverse_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp bind_budget_company(attrs, company_id) when is_map(attrs) do
    attrs
    |> stringify_keys()
    |> Map.put("company_id", company_id)
  end

  defp bind_budget_company(_attrs, company_id), do: %{"company_id" => company_id}
end
