defmodule Cympho.Issues do
  @moduledoc """
  The Issues context for managing issues and their CRUD operations.
  """
  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [optimistic_lock: 2, cast: 3, put_assoc: 3]
  require Logger
  alias Cympho.Repo
  alias Cympho.Issues.Issue
  alias Cympho.Issues.StateMachine
  alias Cympho.Issues.AutoAssignment
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Comments
  alias Cympho.Labels
  alias Cympho.Labels.Label
  alias Cympho.Activities

  def list_issues(opts \\ %{}) do
    Issue
    |> maybe_filter_by_project(opts)
    |> maybe_filter_by_labels(opts)
    |> Repo.all()
    |> Repo.preload([:comments, :blocked_by, :blocks, :assignee, :labels])
  end

  defp maybe_filter_by_project(query, %{project_id: project_id}) do
    where(query, project_id: ^project_id)
  end

  defp maybe_filter_by_project(query, _opts), do: query

  defp maybe_filter_by_labels(query, %{label_id: label_id}) do
    query
    |> join(:inner, [i], l in "issue_labels", on: i.id == l.issue_id)
    |> where([_, l], l.label_id == ^label_id)
  end

  defp maybe_filter_by_labels(query, %{label_ids: label_ids}) when is_list(label_ids) and length(label_ids) > 0 do
    query
    |> join(:inner, [i], l in "issue_labels", on: i.id == l.issue_id)
    |> where([_, l], l.label_id in ^label_ids)
    |> group_by([i], i.id)
    |> having([_, l], count(l.label_id) == ^length(label_ids))
  end

  defp maybe_filter_by_labels(query, _opts), do: query


  @default_page_size 25

  def list_issues_paginated(params \\ %{}) do
    page = Map.get(params, "page", "1") |> to_int_max(1, 1)
    per_page = Map.get(params, "per_page", "#{@default_page_size}") |> to_int_max(1, 100)
    status = Map.get(params, "status")
    priority = Map.get(params, "priority")

    query =
      Issue
      |> maybe_filter_by_status(status)
      |> maybe_filter_by_priority(priority)
      |> order_by(desc: :updated_at)

    total = Repo.aggregate(query, :count)
    total_pages = max(1, ceil(total / per_page))
    page = min(page, total_pages)
    offset = (page - 1) * per_page

    issues =
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> Repo.preload([:comments, :blocked_by, :blocks, :assignee])

    %{
      issues: issues,
      page: page,
      per_page: per_page,
      total: total,
      total_pages: total_pages
    }
  end

  defp maybe_filter_by_status(query, nil), do: query
  defp maybe_filter_by_status(query, ""), do: query
  defp maybe_filter_by_status(query, status), do: where(query, status: ^status)

  defp maybe_filter_by_priority(query, nil), do: query
  defp maybe_filter_by_priority(query, ""), do: query
  defp maybe_filter_by_priority(query, priority), do: where(query, priority: ^priority)

  defp to_int_max(value, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n |> max(min) |> min(max)
      :error -> min
    end
  end

  defp to_int_max(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)

  def list_issues_by_project(project_id) do
    Issue
    |> where(project_id: ^project_id)
    |> Repo.all()
    |> Repo.preload([:comments, :blocked_by, :blocks, :labels])
  end

  def get_issue!(id),
    do: Repo.get!(Issue, id) |> Repo.preload([:comments, :blocked_by, :blocks, :assignee, :labels])

  def get_issue(id) do
    case Repo.get(Issue, id) do
      nil -> {:error, :not_found}
      issue -> {:ok, Repo.preload(issue, [:comments, :blocked_by, :blocks, :assignee, :labels])}
    end
  end

  def get_issue_by_pr_url(pr_url) do
    case Repo.one(from i in Issue, where: i.github_pr_url == ^pr_url, preload: [:project]) do
      nil -> {:error, :not_found}
      issue -> {:ok, issue}
    end
  end

  def create_issue(attrs \\ %{}) do
    attrs = maybe_generate_identifier(attrs)

    case %Issue{}
         |> Issue.changeset(attrs)
         |> Repo.insert() do
      {:ok, issue} ->
        Activities.log_activity(%{issue_id: issue.id, actor_type: Map.get(attrs, :actor_type, "system"), actor_id: Map.get(attrs, :actor_id), action: "created", metadata: %{title: issue.title}})
        Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:issue_created, issue})
        {:ok, Repo.preload(issue, [:comments, :blocked_by, :blocks, :labels])}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp maybe_auto_assign(%Issue{} = issue) do
    case AutoAssignment.assign_issue(issue) do
      {:ok, assigned} ->
        assigned

      {:error, :no_eligible_agent, _} ->
        case AutoAssignment.queue_for_assignment(issue) do
          {:ok, _} -> issue
          {:error, _} -> issue
        end
    end
  end

  defp maybe_generate_identifier(%{"project_id" => project_id} = attrs) do
    if Map.has_key?(attrs, "identifier") do
      attrs
    else
      project = Repo.get!(Cympho.Projects.Project, project_id)

      max_seq =
        Repo.one(
          from i in Issue,
            where: i.project_id == ^project_id,
            select: max(fragment("CAST(SPLIT_PART(i.identifier, '-', 2) AS INTEGER)"))
        ) || 0

      seq = max_seq + 1
      Map.put(attrs, "identifier", "#{project.prefix}-#{seq}")
    end
  end

  defp maybe_generate_identifier(attrs), do: attrs

  def update_issue(%Issue{} = issue, attrs) do
    old_issue = issue
    with {:ok, updated} <- do_update_issue(issue, attrs) do
      updated = Repo.preload(updated, [:comments, :blocked_by, :blocks, :labels])
      Activities.log_issue_changes(old_issue, updated, attrs)
      Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:issue_updated, updated})
      {:ok, updated}
    end
  end

  defp do_update_issue(%Issue{} = issue, %{status: _new_status} = attrs) do
    issue
    |> Issue.changeset(attrs)
    |> optimistic_lock(:lock_version)
    |> Repo.update()
  end

  defp do_update_issue(%Issue{} = issue, attrs) do
    issue
    |> Issue.changeset(attrs)
    |> optimistic_lock(:lock_version)
    |> Repo.update()
  end

  def transition_issue(%Issue{} = issue, new_status, agent_id) when is_binary(agent_id) do
    cond do
      new_status == :in_review ->
        with {:ok, agent} <- Agents.get_agent(agent_id),
             :ok <- validate_reviewer_role(agent),
             {:ok, updated} <- do_transition(issue, new_status) do
          {:ok, updated}
        end

      new_status == :done and is_blocked?(issue) ->
        {:error, :blocked_by_active_issues}

      not StateMachine.valid_transition?(issue.status, new_status) ->
        {:error, :invalid_transition}

      true ->
        do_transition(issue, new_status)
    end
  end

  def transition_issue(%Issue{} = issue, new_status, nil) do
    cond do
      new_status == :done and is_blocked?(issue) ->
        {:error, :blocked_by_active_issues}

      not StateMachine.valid_transition?(issue.status, new_status) ->
        {:error, :invalid_transition}

      true ->
        do_transition(issue, new_status)
    end
  end

  def transition_issue(%Issue{} = issue, new_status) do
    transition_issue(issue, new_status, nil)
  end

  defp validate_reviewer_role(%Agent{} = agent) do
    if agent.role in [:cto, :ceo] do
      :ok
    else
      {:error, :chain_of_command_violation}
    end
  end

  defp do_transition(%Issue{} = issue, new_status) do
    with {:ok, updated} <- update_issue(issue, %{status: new_status}) do
      if new_status == :done, do: unblock_dependents(issue.id)
      if new_status in [:done, :cancelled], do: cancel_pending_approvals(issue.id)
      {:ok, updated}
    end
  end

  defp cancel_pending_approvals(issue_id) do
    try do
      Cympho.Approvals.cancel_pending_for_issue(issue_id)
    rescue
      e ->
        Logger.warning("cancel_pending_approvals: failed for issue #{issue_id}",
          error: inspect(e)
        )
        :ok
    end
  end

  def valid_transitions(%Issue{} = issue) do
    StateMachine.valid_transitions(issue.status)
  end

  def is_blocked?(%Issue{} = issue) do
    blocked_by = issue.blocked_by || []

    Enum.any?(blocked_by, fn blocker ->
      blocker.status != :done and blocker.status != :cancelled
    end)
  end

  def active_blockers(%Issue{} = issue) do
    blocked_by = issue.blocked_by || []

    Enum.filter(blocked_by, fn blocker ->
      blocker.status != :done and blocker.status != :cancelled
    end)
  end

  @doc """
  For each issue that this issue blocks, check if ALL of its blockers are now done.
  If so, transition it to :todo (unblocked) and wake its assignee via AgentHeartbeat.
  Adds a system comment to each unblocked issue.
  """
  def unblock_dependents(blocker_issue_id) do
    # Find all issues where this issue is a blocker
    dependent_ids =
      Repo.all(
        from bb in "issue_blockers",
          where: bb.blocking_issue_id == type(^blocker_issue_id, Ecto.UUID),
          select: bb.blocked_issue_id
      )
      |> Enum.map(&load_uuid/1)

    Enum.each(dependent_ids, fn dependent_id ->
      case get_issue(dependent_id) do
        {:ok, dependent} ->
          if dependent.status == :blocked and all_blockers_done?(dependent) do
            {:ok, updated} = update_issue(dependent, %{status: :todo})
            wake_assignee(updated)
            add_system_comment(updated, "Auto-unblocked")
          end

        {:error, _} ->
          :skip
      end
    end)
  end

  defp all_blockers_done?(%Issue{} = issue) do
    blockers = issue.blocked_by || []
    Enum.all?(blockers, fn blocker -> blocker.status == :done end)
  end

  defp wake_assignee(%Issue{} = issue) do
    if issue.assignee_id do
      try do
        case Cympho.AgentHeartbeat.trigger_heartbeat(issue.assignee_id) do
          :ok -> :ok
          {:error, reason} ->
            Logger.warning("wake_assignee: failed to trigger heartbeat for #{issue.assignee_id}",
              error: inspect(reason)
            )
            :ok
        end
      rescue
        e ->
          _ =
            Logger.warning("wake_assignee: failed to trigger heartbeat for #{issue.assignee_id}",
              error: inspect(e)
            )

          :ok
      end
    end
  end

  defp add_system_comment(%Issue{} = issue, body) do
    Comments.create_comment(%{
      body: body,
      author_type: "system",
      author_id: "00000000-0000-0000-0000-000000000000",
      issue_id: issue.id
    })
  end

  @spec load_uuid(binary()) :: binary()
  defp load_uuid(id) do
    if is_binary(id) and byte_size(id) == 16 do
      Ecto.UUID.load!(id)
    else
      id
    end
  end

  @spec dump_uuid(binary()) :: binary()
  defp dump_uuid(id) do
    Ecto.UUID.dump!(id)
  end

  def checkout_issue(issue, agent_id, required_role \\ nil)

  def checkout_issue(%Issue{} = issue, %Agent{} = agent, required_role) do
    checkout_issue(issue, agent.id, required_role)
  end

  def checkout_issue(%Agent{} = agent, %Issue{} = issue, required_role) do
    checkout_issue(issue, agent.id, required_role)
  end

  def checkout_issue(%Issue{} = issue, agent_id, required_role) do
    # Only reload if issue appears unassigned — avoids N+1 on heartbeat ticks
    # when the issue was freshly fetched as unassigned.
    current_issue = if issue.assignee_id == nil, do: Repo.reload(issue), else: issue
    agent = Agents.get_agent!(agent_id)

    cond do
      current_issue.assignee_id != nil and current_issue.assignee_id != agent_id ->
        {:error, :already_assigned}

      current_issue.assignee_id == agent_id ->
        {:ok, current_issue}

      Agents.is_agent_at_capacity?(agent) ->
        {:error, :agent_at_capacity}

      not Issue.role_authorized?(agent.role, required_role) ->
        {:error, :chain_of_command_violation}

      true ->
        new_status =
          if current_issue.status in [:backlog, :todo],
            do: :in_progress,
            else: current_issue.status

        attrs = %{assignee_id: agent_id, status: new_status}
        attrs = if required_role, do: Map.put(attrs, :assigned_role, required_role), else: attrs
        update_issue(current_issue, attrs)
        |> maybe_adjust_lock_version()
    end
  end

  def release_issue(%Issue{} = issue, target_status \\ :todo) do
    update_issue(issue, %{assignee_id: nil, status: target_status})
    |> maybe_adjust_lock_version()
  end

  defp maybe_adjust_lock_version({:ok, issue}), do: {:ok, issue}
  defp maybe_adjust_lock_version({:error, _} = error), do: error

  def add_blocker(%Issue{} = blocked_issue, %Issue{} = blocker_issue) do
    cond do
      blocked_issue.id == blocker_issue.id ->
        {:error, :cannot_block_self}

      transitively_blocked_by?(blocker_issue, blocked_issue) ->
        {:error, :circular_blocker}

      true ->
        now = DateTime.utc_now()

        Repo.transaction(fn ->
          Repo.query!("""
            INSERT INTO issue_blockers (blocked_issue_id, blocking_issue_id, inserted_at, updated_at)
            VALUES ($1, $2, $3, $4)
            ON CONFLICT DO NOTHING
          """, [dump_uuid(blocked_issue.id), dump_uuid(blocker_issue.id), now, now])

          Repo.reload(blocked_issue)
        end)
        |> case do
          {:ok, issue} ->
            issue = Repo.preload(issue, [:comments, :blocked_by, :blocks])
            Activities.log_activity(%{issue_id: blocked_issue.id, actor_type: "system", action: "blocker_added", metadata: %{blocker_id: blocker_issue.id}})
            Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:issue_updated, issue})
            {:ok, Repo.preload(issue, [:comments, :blocked_by, :blocks, :labels])}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp transitively_blocked_by?(issue, target) do
    visited = MapSet.new()
    do_transitively_blocked_by?(issue.id, target.id, visited)
  end

  defp do_transitively_blocked_by?(current_id, target_id, visited) do
    if MapSet.member?(visited, current_id) do
      false
    else
      visited = MapSet.put(visited, current_id)

      blocker_ids =
        Repo.all(
          from bb in "issue_blockers",
            where: bb.blocked_issue_id == type(^current_id, Ecto.UUID),
            select: bb.blocking_issue_id
        )

      Enum.any?(blocker_ids, fn blocker_id ->
        blocker_string = load_uuid(blocker_id)

        if blocker_string == target_id do
          true
        else
          do_transitively_blocked_by?(blocker_string, target_id, visited)
        end
      end)
    end
  end

  def remove_blocker(%Issue{} = blocked_issue, %Issue{} = blocker_issue) do
    {count, _} =
      from(bb in "issue_blockers",
        where:
          bb.blocked_issue_id == type(^blocked_issue.id, Ecto.UUID) and
            bb.blocking_issue_id == type(^blocker_issue.id, Ecto.UUID)
      )
      |> Repo.delete_all()

    if count == 0 do
      {:error, :not_found}
    else
      issue = Repo.preload(Repo.reload(blocked_issue), [:comments, :blocked_by, :blocks, :labels])
      Activities.log_activity(%{issue_id: blocked_issue.id, actor_type: "system", action: "blocker_removed", metadata: %{blocker_id: blocker_issue.id}})
      Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:issue_updated, issue})
      {:ok, issue}
    end
  end

  def add_label_to_issue(%Issue{} = issue, %Label{} = label) do
    issue = Repo.preload(issue, :labels)
    labels = issue.labels ++ [label]
    issue
    |> cast(%{}, [])
    |> put_assoc(:labels, labels)
    |> Repo.update()
  end

  def remove_label_from_issue(%Issue{} = issue, %Label{} = label) do
    issue = Repo.preload(issue, :labels)
    labels = Enum.reject(issue.labels, &(&1.id == label.id))
    issue
    |> cast(%{}, [])
    |> put_assoc(:labels, labels)
    |> Repo.update()
  end

  def set_issue_labels(%Issue{} = issue, label_ids) when is_list(label_ids) do
    labels = Labels.list_labels() |> Enum.filter(&(&1.id in label_ids))
    issue = Repo.preload(issue, :labels)
    issue
    |> cast(%{}, [])
    |> put_assoc(:labels, labels)
    |> Repo.update()
  end

  def delete_issue(%Issue{} = issue) do
    cancel_pending_approvals(issue.id)

    case Repo.delete(issue) do
      {:ok, _issue} ->
        Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:issue_deleted, issue.id})
        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def subscribe do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "issues")
  end

  def change_issue(%Issue{} = issue, attrs \\ %{}) do
    Issue.changeset(issue, attrs)
  end
end
