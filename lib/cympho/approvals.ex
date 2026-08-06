defmodule Cympho.Approvals do
  @moduledoc """
  The Approvals context for managing approval requests.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Approvals.Approval
  alias Cympho.Approvals.ApprovalIssue
  alias Cympho.Activities
  alias Cympho.Decisions

  def list_approvals(opts \\ %{}) do
    query = from(a in Approval, order_by: [desc: a.inserted_at])

    query =
      case Map.get(opts, :status) do
        nil -> query
        status -> from(a in query, where: a.status == ^status)
      end

    query =
      case Map.get(opts, :company_id) do
        nil ->
          query

        company_id ->
          from(a in query,
            join: agent in assoc(a, :requested_by),
            where: agent.company_id == ^company_id
          )
      end

    Repo.all(query)
    |> Repo.preload([:requested_by, :issues])
  end

  def list_approvals_page(opts \\ %{}) do
    query = from(a in Approval)

    query =
      case Map.get(opts, :status) do
        nil -> query
        status -> from(a in query, where: a.status == ^status)
      end

    query =
      case Map.get(opts, :company_id) do
        nil ->
          query

        company_id ->
          from(a in query,
            join: agent in assoc(a, :requested_by),
            where: agent.company_id == ^company_id
          )
      end

    Cympho.Pagination.page(query, after: Map.get(opts, :after))
    |> then(fn p -> %{p | entries: Repo.preload(p.entries, [:requested_by, :issues])} end)
  end

  def count_pending_for_company(company_id) when is_binary(company_id) do
    from(a in Approval,
      join: agent in assoc(a, :requested_by),
      where: agent.company_id == ^company_id and a.status == :pending,
      select: count(a.id)
    )
    |> Repo.one()
  end

  def count_pending_for_company(_company_id), do: 0

  def get_approval!(id) do
    Repo.get!(Approval, id)
    |> Repo.preload([:requested_by, :resolved_by, :issues])
  end

  def get_approval(id) do
    case Repo.get(Approval, id) do
      nil -> {:error, :not_found}
      approval -> {:ok, Repo.preload(approval, [:requested_by, :resolved_by, :issues])}
    end
  end

  def get_company_approval(company_id, id) do
    query =
      from(a in Approval,
        join: agent in assoc(a, :requested_by),
        where: a.id == ^id and agent.company_id == ^company_id
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      approval ->
        {:ok, Repo.preload(approval, [:requested_by, :resolved_by, :issues])}
    end
  end

  def create_approval(attrs) do
    issue_ids = Map.get(attrs, :issue_ids) || Map.get(attrs, "issue_ids") || []

    attrs = Map.drop(attrs, [:issue_ids, "issue_ids"])

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:approval, Approval.create_changeset(%Approval{}, attrs))
    |> Ecto.Multi.run(:link_issues, fn repo, %{approval: approval} ->
      links =
        Enum.map(issue_ids, fn issue_id ->
          %{
            approval_id: approval.id,
            issue_id: issue_id
          }
        end)

      if links == [] do
        {:ok, []}
      else
        repo.insert_all(ApprovalIssue, links)
        {:ok, links}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{approval: approval}} ->
        approval = Repo.preload(approval, [:requested_by, :issues])

        Enum.each(issue_ids, fn issue_id ->
          Activities.log_activity(%{
            issue_id: issue_id,
            actor_type: "agent",
            actor_id: Map.get(attrs, :requested_by_id) || Map.get(attrs, "requested_by_id"),
            action: "approval_created",
            metadata: %{approval_id: approval.id}
          })
        end)

        broadcast_approval(approval, {:approval_created, approval})

        {:ok, approval}

      {:error, _operation, changeset, _changes} ->
        {:error, changeset}
    end
  end

  def resolve_approval(id, status, opts \\ %{}) do
    approval = Repo.get!(Approval, id)

    attrs = %{
      status: status,
      resolved_by_user_id: Map.get(opts, :resolved_by_user_id),
      resolution_reason: Map.get(opts, :resolution_reason)
    }

    approval
    |> Approval.resolve_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        updated = Repo.preload(updated, [:requested_by, :resolved_by, :issues])

        actor = {"user", Map.get(opts, :resolved_by_user_id)}
        Decisions.record_issue_decision(updated, actor)

        Enum.each(updated.issues, fn issue ->
          Activities.log_activity(%{
            issue_id: issue.id,
            actor_type: "user",
            actor_id: Map.get(opts, :resolved_by_user_id),
            action: "approval_resolved",
            metadata: %{approval_id: updated.id, status: to_string(status)}
          })
        end)

        broadcast_approval(updated, {:approval_resolved, updated})

        maybe_wake_agent(updated)
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def cancel_approval(id) do
    approval = Repo.get!(Approval, id)

    if approval.status == :pending do
      approval
      |> Approval.cancel_changeset()
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          broadcast_approval(updated, {:approval_cancelled, updated})

          {:ok, updated}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, :not_pending}
    end
  end

  def cancel_pending_for_issue(issue_id) do
    query =
      from(a in Approval,
        join: ai in ApprovalIssue,
        on: ai.approval_id == a.id,
        where: ai.issue_id == ^issue_id and a.status == :pending
      )

    {count, _} = Repo.update_all(query, set: [status: :cancelled])

    if count > 0 do
      company_id = issue_company_id_for_approval(issue_id)

      Cympho.PubSubGuard.company_broadcast(
        company_id,
        "approvals",
        {:approvals_cancelled_for_issue, issue_id}
      )
    end

    {:ok, count}
  end

  def list_approvals_for_issue(issue_id) do
    from(a in Approval,
      join: ai in ApprovalIssue,
      on: ai.approval_id == a.id,
      where: ai.issue_id == ^issue_id,
      order_by: [desc: a.inserted_at]
    )
    |> Repo.all()
    |> Repo.preload([:requested_by, :resolved_by, :issues])
  end

  def subscribe(company_id) when is_binary(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:approvals")
  end

  def subscribe(_company_id), do: :ok

  defp maybe_wake_agent(%Approval{} = approval) do
    approval = Repo.preload(approval, :requested_by)

    if approval.requested_by do
      try do
        Cympho.AgentHeartbeat.trigger_heartbeat(approval.requested_by.id)
      rescue
        _ -> :ok
      end
    end
  end

  # Fail-closed: never publish the unscoped "approvals" topic or company::approvals.
  defp broadcast_approval(%Approval{} = approval, message) do
    Cympho.PubSubGuard.company_broadcast(approval_company_id(approval), "approvals", message)
  end

  defp approval_company_id(%Approval{} = approval) do
    approval = Repo.preload(approval, [:issues, :requested_by])

    case approval.issues do
      [%{company_id: company_id} | _] when is_binary(company_id) and company_id != "" ->
        company_id

      _ ->
        case approval.requested_by do
          %Cympho.Agents.Agent{company_id: company_id}
          when is_binary(company_id) and company_id != "" ->
            company_id

          _ ->
            nil
        end
    end
  end

  defp issue_company_id_for_approval(issue_id) do
    Repo.one(from i in Cympho.Issues.Issue, where: i.id == ^issue_id, select: i.company_id)
  end
end
