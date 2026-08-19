defmodule Cympho.Approvals do
  @moduledoc """
  The Approvals context for managing approval requests.
  """
  import Ecto.Query, warn: false
  require Logger

  alias Cympho.Repo
  alias Cympho.Approvals.Approval
  alias Cympho.Approvals.ApprovalIssue
  alias Cympho.Activities
  alias Cympho.CompanyRBAC
  alias Cympho.Decisions

  @resolution_statuses [:approved, :denied]

  @doc """
  Ordinary approvals may be resolved by company owners, company admins, or
  board members. Other company members retain read-only access.
  """
  def resolver_authorized?(user_id, company_id)
      when is_binary(user_id) and is_binary(company_id) do
    CompanyRBAC.manager?(user_id, company_id)
  end

  def resolver_authorized?(_user_id, _company_id), do: false

  def authorize_resolver(user_id, company_id) do
    if resolver_authorized?(user_id, company_id), do: :ok, else: {:error, :forbidden}
  end

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

  def resolve_company_approval(company_id, id, status, opts)
      when is_binary(company_id) and is_map(opts) do
    with :ok <- authorize_resolver(Map.get(opts, :resolved_by_user_id), company_id) do
      opts
      |> Map.put(:company_id, company_id)
      |> then(&resolve_approval(id, status, &1))
    end
  end

  def resolve_company_approval(_company_id, _id, _status, _opts), do: {:error, :forbidden}

  def resolve_approval(id, status, opts \\ %{})

  def resolve_approval(id, status, opts) when status in @resolution_statuses and is_map(opts) do
    actor = resolution_actor(Map.get(opts, :resolved_by_user_id))

    Ecto.Multi.new()
    |> Ecto.Multi.run(:approval, fn repo, _changes ->
      compare_and_set_resolution(repo, id, status, opts)
    end)
    |> Ecto.Multi.insert(:decision, fn %{approval: approval} ->
      company_id = Map.get(opts, :company_id) || approval_company_id(approval)
      Decisions.issue_decision_changeset(approval, actor, company_id)
    end)
    |> Ecto.Multi.run(:activities, fn repo, %{approval: approval} ->
      insert_resolution_activities(repo, approval, actor)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{approval: updated, decision: decision, activities: activities}} ->
        run_resolution_side_effects(updated, decision, activities, actor)
        {:ok, updated}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  def resolve_approval(_id, _status, _opts), do: {:error, :invalid_status}

  def cancel_approval(id) do
    case compare_and_set_status(Repo, id, :cancelled, %{}) do
      {:ok, updated} ->
        broadcast_approval(updated, {:approval_cancelled, updated})
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def cancel_pending_for_issue(issue_id) do
    query =
      from(a in Approval,
        join: ai in ApprovalIssue,
        on: ai.approval_id == a.id,
        where: ai.issue_id == ^issue_id and a.status == :pending
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {count, _} = Repo.update_all(query, set: [status: :cancelled, updated_at: now])

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

  def subscribe(company_id) when is_binary(company_id) and company_id != "" do
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

    case approval.requested_by do
      %Cympho.Agents.Agent{company_id: company_id}
      when is_binary(company_id) and company_id != "" ->
        company_id

      _ ->
        case approval.issues do
          [%{company_id: company_id} | _]
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

  defp compare_and_set_resolution(repo, id, status, opts) do
    expected_company_id = Map.get(opts, :company_id)

    with {:ok, _approval} <- fetch_transition_target(repo, id, expected_company_id) do
      compare_and_set_status(repo, id, status, %{
        resolved_by_user_id: Map.get(opts, :resolved_by_user_id),
        resolution_reason: Map.get(opts, :resolution_reason)
      })
    end
  end

  defp compare_and_set_status(repo, id, status, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    updates =
      attrs
      |> Map.put(:status, status)
      |> Map.put(:updated_at, now)
      |> Enum.to_list()

    query = from(a in Approval, where: a.id == ^id and a.status == :pending)

    case repo.update_all(query, set: updates) do
      {1, _} ->
        updated = repo.get!(Approval, id)
        {:ok, repo.preload(updated, [:requested_by, :resolved_by, :issues])}

      {0, _} ->
        transition_error(repo, id)
    end
  end

  defp fetch_transition_target(repo, id, nil) do
    case repo.get(Approval, id) do
      nil -> {:error, :not_found}
      approval -> {:ok, approval}
    end
  end

  defp fetch_transition_target(repo, id, company_id) do
    query =
      from(a in Approval,
        join: agent in assoc(a, :requested_by),
        where: a.id == ^id and agent.company_id == ^company_id
      )

    case repo.one(query) do
      nil -> {:error, :not_found}
      approval -> {:ok, approval}
    end
  end

  defp transition_error(repo, id) do
    case repo.get(Approval, id) do
      nil -> {:error, :not_found}
      _approval -> {:error, :not_pending}
    end
  end

  defp resolution_actor(user_id) when is_binary(user_id), do: {"user", user_id}
  defp resolution_actor(_user_id), do: nil

  defp insert_resolution_activities(repo, approval, actor) do
    Enum.reduce_while(approval.issues, {:ok, []}, fn issue, {:ok, activities} ->
      changeset =
        Activities.activity_changeset(%{
          issue_id: issue.id,
          company_id: issue.company_id,
          actor_type: elem(actor || {"system", nil}, 0),
          actor_id: elem(actor || {"system", nil}, 1),
          action: "approval_resolved",
          metadata: %{approval_id: approval.id, status: to_string(approval.status)}
        })

      case repo.insert(changeset) do
        {:ok, activity} -> {:cont, {:ok, [activity | activities]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, activities} -> {:ok, Enum.reverse(activities)}
      error -> error
    end
  end

  defp run_resolution_side_effects(updated, decision, activities, actor) do
    safely_after_commit(updated.id, "decision notifications", fn ->
      Decisions.dispatch_created_decision(decision, actor)
    end)

    Enum.each(activities, fn activity ->
      safely_after_commit(updated.id, "issue activity broadcast", fn ->
        Activities.dispatch_activity(activity)
      end)
    end)

    safely_after_commit(updated.id, "approval broadcast", fn ->
      broadcast_approval(updated, {:approval_resolved, updated})
    end)

    safely_after_commit(updated.id, "requesting-agent wake", fn -> maybe_wake_agent(updated) end)
  end

  defp safely_after_commit(approval_id, effect, fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "Approval #{approval_id} committed, but #{effect} failed: #{Exception.message(error)}"
      )
  catch
    kind, reason ->
      Logger.error(
        "Approval #{approval_id} committed, but #{effect} failed: #{inspect({kind, reason})}"
      )
  end
end
