defmodule Cympho.Budgets do
  @moduledoc """
  The Budgets context for managing budget tracking and hard-stop enforcement.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Budgets.Budget
  alias Cympho.{GovernanceAuditLogs, Activities}

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
  """
  def create_budget(attrs, actor \\ nil) do
    %Budget{}
    |> Budget.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, budget} ->
        GovernanceAuditLogs.log_action(
          "budget_created",
          actor || {"system", "system"},
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
  """
  def update_budget(%Budget{} = budget, attrs, actor \\ nil) do
    budget
    |> Budget.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        GovernanceAuditLogs.log_action(
          "budget_updated",
          actor || {"system", "system"},
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
          actor || {"system", "system"},
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
          actor || {"system", "system"},
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
        actor || {"system", "system"},
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
        actor || {"system", "system"},
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
end
