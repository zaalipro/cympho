defmodule Cympho.Budgets do
  @moduledoc """
  The Budgets context for managing budget tracking and hard-stop enforcement.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Budgets.Budget
  alias Cympho.{GovernanceAuditLogs, Activities, BoardApprovals}

  @doc """
  Returns the list of budgets.
  """
  def list_budgets(opts \\ %{}) do
    query = from(b in Budget, order_by: [desc: b.inserted_at])

    query =
      Enum.reduce(opts, query, fn
        {:scope_type, type}, q ->
          where(q, [b], b.scope_type == ^type)

        {:scope_id, id}, q ->
          where(q, [b], b.scope_id == ^id)

        {:company_id, id}, q ->
          where(q, [b], b.company_id == ^id)

        {:project_id, id}, q ->
          where(q, [b], b.project_id == ^id)

        {:agent_id, id}, q ->
          where(q, [b], b.agent_id == ^id)

        {:status, status}, q ->
          where(q, [b], b.status == ^status)

        {:active, true}, q ->
          where(q, [b], b.status == "active")

        _, q ->
          q
      end)

    Repo.all(query)
  end

  @doc """
  Gets a single budget.
  """
  def get_budget!(id), do: Repo.get!(Budget, id)

  def get_budget(id) do
    case Repo.get(Budget, id) do
      nil -> {:error, :not_found}
      budget -> {:ok, budget}
    end
  end

  @doc """
  Creates a budget.

  If the company's governance config requires `budget_increase` approval and the
  limit exceeds the configured budget threshold, a BoardApproval is created
  instead and `{:pending_approval, approval}` is returned.
  """
  def create_budget(attrs, actor \\ nil) do
    changeset = Budget.changeset(%Budget{}, attrs)

    if changeset.valid? do
      case check_budget_approval_needed(attrs, nil) do
        {:ok, :approval_needed, company} ->
          create_pending_budget_approval(company, attrs, actor)

        {:ok, :not_needed} ->
          do_create_budget(changeset, actor)

        {:error, :company_not_found} ->
          do_create_budget(changeset, actor)
      end
    else
      {:error, changeset}
    end
  end

  defp do_create_budget(changeset, actor) do
    changeset
    |> Repo.insert()
    |> case do
      {:ok, budget} ->
        GovernanceAuditLogs.log_action(
          "budget_created",
          actor,
          "Budget created: #{budget.name}",
          resource: budget,
          metadata: %{
            limit: budget.limit_amount,
            currency: budget.currency,
            scope: "#{budget.scope_type}:#{budget.scope_id}"
          }
        )

        Phoenix.PubSub.broadcast(Cympho.PubSub, "budgets", {:budget_created, budget})
        {:ok, budget}

      error ->
        error
    end
  end

  @doc """
  Updates a budget.

  If the company's governance config requires `budget_increase` approval and the
  new limit exceeds the old limit, a BoardApproval is created instead and
  `{:pending_approval, approval}` is returned.
  """
  def update_budget(%Budget{} = budget, attrs, actor \\ nil) do
    if budget_increase_exceeds_threshold?(budget, attrs) do
      company = Cympho.Repo.get(Cympho.Companies.Company, budget.company_id)

      if company && BoardApprovals.governance_required?(company, "budget_increase") do
        create_pending_budget_update_approval(company, budget, attrs, actor)
      else
        do_update_budget(budget, attrs, actor)
      end
    else
      do_update_budget(budget, attrs, actor)
    end
  end

  defp do_update_budget(budget, attrs, actor) do
    budget
    |> Budget.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        GovernanceAuditLogs.log_action(
          "budget_updated",
          actor,
          "Budget updated: #{updated.name}",
          resource: updated,
          metadata: %{
            changes: Map.keys(attrs)
          }
        )

        Phoenix.PubSub.broadcast(Cympho.PubSub, "budgets", {:budget_updated, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Records spending against a budget.
  """
  def record_spend(%Budget{} = budget, amount, description, actor \\ nil) do
    budget
    |> Budget.spend_changeset(amount)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        GovernanceAuditLogs.log_action(
          "budget_spent",
          actor,
          "Spent #{amount} #{budget.currency}: #{description}",
          resource: updated,
          reasoning: description,
          metadata: %{
            amount: amount,
            currency: budget.currency,
            new_spent: updated.spent_amount,
            remaining: Budget.available_amount(updated)
          }
        )

        check_threshold_alert(updated, actor)
        check_hard_stop(updated, actor)

        Activities.log_cost_event(budget.scope_id, amount, budget.currency, %{
          budget_id: budget.id,
          description: description,
          remaining: Budget.available_amount(updated)
        })

        Phoenix.PubSub.broadcast(Cympho.PubSub, "budgets", {:budget_spent, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Checks if an action can proceed based on budget constraints.
  Returns {:ok, budget} or {:error, :budget_exhausted} or {:error, :budget_not_found}
  """
  def check_budget_constraint(scope_type, scope_id, amount \\ Decimal.new(0)) do
    case get_active_budget(scope_type, scope_id) do
      nil ->
        {:ok, nil}

      %Budget{} = budget ->
        if Budget.active?(budget) do
          available = Budget.available_amount(budget)

          if Decimal.gte?(available, amount) do
            {:ok, budget}
          else
            {:error, :budget_exhausted}
          end
        else
          {:error, :budget_exhausted}
        end
    end
  end

  @doc """
  Checks budget constraints and raises if exhausted.
  """
  def enforce_budget_constraint!(scope_type, scope_id, amount \\ Decimal.new(0)) do
    case check_budget_constraint(scope_type, scope_id, amount) do
      {:ok, _} -> :ok
      {:error, :budget_exhausted} -> raise "Budget exhausted for #{scope_type}:#{scope_id}"
    end
  end

  @doc """
  Deletes a budget.
  """
  def delete_budget(%Budget{} = budget, actor \\ nil) do
    Repo.delete(budget)
    |> case do
      {:ok, deleted} ->
        GovernanceAuditLogs.log_action(
          "budget_deleted",
          actor,
          "Budget deleted: #{deleted.name}",
          resource: deleted,
          metadata: %{
            limit: deleted.limit_amount,
            spent: deleted.spent_amount
          }
        )

        Phoenix.PubSub.broadcast(Cympho.PubSub, "budgets", {:budget_deleted, deleted})
        {:ok, deleted}

      error ->
        error
    end
  end

  @doc """
  Subscribes to budget events.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "budgets")
  end

  defp get_active_budget(scope_type, scope_id) do
    from(b in Budget,
      where: b.scope_type == ^scope_type and b.scope_id == ^scope_id and b.status == "active",
      order_by: [desc: b.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  defp check_threshold_alert(%Budget{} = budget, actor) do
    if Budget.at_threshold?(budget) do
      GovernanceAuditLogs.log_action(
        "budget_threshold_reached",
        actor,
        "Budget threshold alert: #{budget.name} at #{Budget.utilization_percentage(budget)}%",
        resource: budget,
        metadata: %{
          threshold: budget.threshold_alert_percentage,
          utilization: Budget.utilization_percentage(budget)
        }
      )

      Activities.log_budget_threshold(
        budget.scope_id,
        "threshold_alert",
        budget.spent_amount,
        budget.limit_amount
      )

      Phoenix.PubSub.broadcast(
        Cympho.PubSub,
        "budgets",
        {:budget_threshold_reached, budget}
      )
    end
  end

  defp check_hard_stop(%Budget{} = budget, actor) do
    if Budget.exhausted?(budget) and budget.hard_stop do
      GovernanceAuditLogs.log_action(
        "budget_limit_reached",
        actor,
        "Budget hard-stop triggered: #{budget.name}",
        resource: budget,
        reasoning: "Budget limit reached and hard-stop is enabled",
        metadata: %{
          limit: budget.limit_amount,
          spent: budget.spent_amount
        }
      )

      Phoenix.PubSub.broadcast(Cympho.PubSub, "budgets", {:budget_hard_stop, budget})
    end
  end

  # ── Governance gate helpers ──

  defp check_budget_approval_needed(attrs, nil) do
    company_id = attrs[:company_id] || attrs["company_id"]

    if company_id do
      case Cympho.Repo.get(Cympho.Companies.Company, company_id) do
        nil -> {:error, :company_not_found}
        company -> check_budget_approval_needed(attrs, company)
      end
    else
      {:error, :company_not_found}
    end
  end

  defp check_budget_approval_needed(attrs, %Cympho.Companies.Company{} = company) do
    if BoardApprovals.governance_required?(company, "budget_increase") do
      threshold = get_budget_threshold(company)
      limit = parse_decimal(attrs[:limit_amount] || attrs["limit_amount"])

      if limit && Decimal.gt?(limit, threshold) do
        {:ok, :approval_needed, company}
      else
        {:ok, :not_needed}
      end
    else
      {:ok, :not_needed}
    end
  end

  defp get_budget_threshold(%Cympho.Companies.Company{governance_config: config}) do
    config
    |> (fn c -> Map.get(c, "budget_limit_threshold") || Map.get(c, :budget_limit_threshold) end).()
    |> parse_decimal()
    |> case do
      nil -> Decimal.new(0)
      threshold -> threshold
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(%Decimal{} = d), do: d
  defp parse_decimal(v) when is_integer(v), do: Decimal.new(v)
  defp parse_decimal(v) when is_float(v), do: Decimal.from_float(v)
  defp parse_decimal(v) when is_binary(v), do: Decimal.new(v)

  defp budget_increase_exceeds_threshold?(%Budget{} = budget, attrs) do
    new_limit = attrs[:limit_amount] || attrs["limit_amount"]

    if new_limit do
      new_dec = parse_decimal(new_limit)
      new_dec && Decimal.gt?(new_dec, budget.limit_amount || Decimal.new(0))
    else
      false
    end
  end

  defp create_pending_budget_approval(company, attrs, actor) do
    approval_attrs = %{
      title: "Budget creation approval: #{attrs[:name] || attrs["name"] || "Untitled"}",
      description: "Budget creation requires board approval. Limit: #{attrs[:limit_amount] || attrs["limit_amount"]}",
      category: "budget_increase",
      company_id: company.id,
      proposal_data: %{
        action: "create_budget",
        budget_attrs: stringify_keys(attrs)
      }
    }

    BoardApprovals.create_board_approval(approval_attrs, actor)
    |> case do
      {:ok, approval} ->
        GovernanceAuditLogs.log_action(
          "budget_pending_approval",
          actor,
          "Budget creation pending board approval",
          resource: approval,
          metadata: %{limit: attrs[:limit_amount] || attrs["limit_amount"]}
        )

        {:pending_approval, approval}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp create_pending_budget_update_approval(company, budget, attrs, actor) do
    approval_attrs = %{
      title: "Budget increase approval: #{budget.name}",
      description: "Budget limit increase from #{budget.limit_amount} to #{attrs[:limit_amount] || attrs["limit_amount"]} requires board approval.",
      category: "budget_increase",
      company_id: company.id,
      proposal_data: %{
        action: "update_budget",
        budget_id: budget.id,
        old_limit: Decimal.to_string(budget.limit_amount),
        new_limit: to_string(attrs[:limit_amount] || attrs["limit_amount"]),
        update_attrs: stringify_keys(attrs)
      }
    }

    BoardApprovals.create_board_approval(approval_attrs, actor)
    |> case do
      {:ok, approval} ->
        GovernanceAuditLogs.log_action(
          "budget_update_pending_approval",
          actor,
          "Budget update pending board approval: #{budget.name}",
          resource: approval,
          metadata: %{
            budget_id: budget.id,
            old_limit: budget.limit_amount,
            new_limit: attrs[:limit_amount] || attrs["limit_amount"]
          }
        )

        {:pending_approval, approval}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
