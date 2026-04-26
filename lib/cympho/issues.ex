defmodule Cympho.Issues do
  @moduledoc """
  The Issues context for managing issues and their CRUD operations.
  """
  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [optimistic_lock: 2]
  require Logger
  alias Cympho.Repo
  alias Cympho.Issues.Issue
  alias Cympho.Issues.StateMachine
  alias Cympho.Issues.ExecutionState
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Approvals
  alias Cympho.Comments
  alias Cympho.Activities
  alias Cympho.ExecutionPolicies
  alias Cympho.ExecutionPolicies.ExecutionPolicy
  alias Cympho.Wakes
  alias Cympho.Labels.Label

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

  defp maybe_filter_by_labels(query, %{label_ids: label_ids})
       when is_list(label_ids) and length(label_ids) > 0 do
    query
    |> join(:inner, [i], l in "issue_labels", on: i.id == l.issue_id)
    |> where([_, l], l.label_id in ^label_ids)
    |> group_by([i], i.id)
    |> having([_, l], count(l.label_id) == ^length(label_ids))
  end

  defp maybe_filter_by_labels(query, _opts), do: query

  @default_page_size 25

  def list_issues_paginated(params \\ %{}) do
    page = Map.get(params, "page", "1") |> to_int_max(1, 1000)
    per_page = Map.get(params, "per_page", "#{@default_page_size}") |> to_int_max(1, 100)
    status = Map.get(params, "status")
    priority = Map.get(params, "priority")
    search = Map.get(params, "search")
    assignee_id = Map.get(params, "assignee_id")
    project_id = Map.get(params, "project_id")
    label_id = Map.get(params, "label_id")

    query =
      Issue
      |> maybe_filter_by_status(status)
      |> maybe_filter_by_priority(priority)
      |> maybe_filter_by_search(search)
      |> maybe_filter_by_assignee(assignee_id)
      |> maybe_filter_by_project_id_filter(project_id)
      |> maybe_filter_by_label_id(label_id)
      |> order_by([i], desc: i.updated_at, desc: i.inserted_at, desc: i.id)

    total = Repo.aggregate(query, :count)
    total_pages = max(1, ceil(total / per_page))
    page = min(page, total_pages)
    offset = (page - 1) * per_page

    issues =
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> Repo.preload([:comments, :blocked_by, :blocks, :assignee, :labels, :project])

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

  defp maybe_filter_by_search(query, nil), do: query
  defp maybe_filter_by_search(query, ""), do: query

  defp maybe_filter_by_search(query, search) do
    try do
      where(query, fragment("search_vector @@ plainto_tsquery('english', ?)", ^search))
    rescue
      _e in [Postgrex.Error, Ecto.Query.CompileError] ->
        Logger.warning("Search query invalid, degrading to unfiltered", search: search)
        query
    end
  end

  defp maybe_filter_by_assignee(query, nil), do: query
  defp maybe_filter_by_assignee(query, ""), do: query
  defp maybe_filter_by_assignee(query, assignee_id), do: where(query, assignee_id: ^assignee_id)

  defp maybe_filter_by_project_id_filter(query, nil), do: query
  defp maybe_filter_by_project_id_filter(query, ""), do: query

  defp maybe_filter_by_project_id_filter(query, project_id),
    do: where(query, project_id: ^project_id)

  defp maybe_filter_by_label_id(query, nil), do: query
  defp maybe_filter_by_label_id(query, ""), do: query

  defp maybe_filter_by_label_id(query, label_id) do
    query
    |> join(:inner, [i], l in "issue_labels", on: i.id == l.issue_id)
    |> where([_, l], l.label_id == type(^label_id, :binary_id))
  end

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
    do:
      Repo.get!(Issue, id) |> Repo.preload([:comments, :blocked_by, :blocks, :assignee, :labels])

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
        Activities.log_activity(%{
          issue_id: issue.id,
          company_id: issue.company_id,
          actor_type: Map.get(attrs, :actor_type, "system"),
          actor_id: Map.get(attrs, :actor_id),
          action: "created",
          metadata: %{title: issue.title}
        })

        Cympho.RateLimiting.dedup_pubsub(
          Cympho.PubSub,
          "company:#{issue.company_id}:issues",
          {:issue_created, issue}
        )

        CymphoWeb.Events.broadcast_issue_update(issue, :issue_created)
        {:ok, Repo.preload(issue, [:comments, :blocked_by, :blocks, :labels])}

      {:error, changeset} ->
        {:error, changeset}
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

      Cympho.RateLimiting.dedup_pubsub(
        Cympho.PubSub,
        "company:#{updated.company_id}:issues",
        {:issue_updated, updated}
      )

      event_type = determine_update_event_type(old_issue, updated, attrs)

      CymphoWeb.Events.broadcast_issue_update(
        updated,
        event_type,
        build_update_metadata(old_issue, updated, attrs)
      )

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
      if new_status == :done do
        unblock_dependents(issue.id)
        _ = Wakes.notify_children_completed(updated)
        maybe_complete_parent(updated)
      end

      if new_status in [:done, :cancelled], do: Approvals.cancel_pending_for_issue(issue.id)
      {:ok, updated}
    end
  end

  defp maybe_complete_parent(%Issue{parent_id: nil}), do: :ok

  defp maybe_complete_parent(%Issue{parent_id: parent_id}) do
    case Repo.get(Issue, parent_id) do
      nil ->
        :ok

      parent ->
        siblings = from(i in Issue, where: i.parent_id == ^parent_id) |> Repo.all()
        all_done? = Enum.all?(siblings, &(&1.status == :done))

        if all_done? and parent.status != :done do
          {:ok, _} = do_transition(parent, :done)
          add_system_comment(parent, "Auto-completed: all sub-issues are done")
        end

        :ok
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
          :ok ->
            :ok

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
          Repo.query!(
            """
              INSERT INTO issue_blockers (blocked_issue_id, blocking_issue_id, inserted_at, updated_at)
              VALUES ($1, $2, $3, $4)
              ON CONFLICT DO NOTHING
            """,
            [dump_uuid(blocked_issue.id), dump_uuid(blocker_issue.id), now, now]
          )

          Repo.reload(blocked_issue)
        end)
        |> case do
          {:ok, issue} ->
            issue = Repo.preload(issue, [:comments, :blocked_by, :blocks])

            Activities.log_activity(%{
              issue_id: blocked_issue.id,
              company_id: blocked_issue.company_id,
              actor_type: "system",
              action: "blocker_added",
              metadata: %{blocker_id: blocker_issue.id}
            })

            Cympho.RateLimiting.dedup_pubsub(
              Cympho.PubSub,
              "company:#{issue.company_id}:issues",
              {:issue_updated, issue}
            )

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

      Activities.log_activity(%{
        issue_id: blocked_issue.id,
        company_id: blocked_issue.company_id,
        actor_type: "system",
        action: "blocker_removed",
        metadata: %{blocker_id: blocker_issue.id}
      })

      Cympho.RateLimiting.dedup_pubsub(
        Cympho.PubSub,
        "company:#{issue.company_id}:issues",
        {:issue_updated, issue}
      )

      {:ok, issue}
    end
  end

  def delete_issue(%Issue{} = issue) do
    cancel_pending_approvals(issue.id)

    case Repo.delete(issue) do
      {:ok, _issue} ->
        Approvals.cancel_pending_for_issue(issue.id)

        Cympho.RateLimiting.dedup_pubsub(
          Cympho.PubSub,
          "company:#{issue.company_id}:issues",
          {:issue_deleted, issue.id}
        )

        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Assigns an execution policy to an issue and initializes the execution state.
  Sets the issue assignee to the executor_id.
  """
  @spec assign_execution_policy(Issue.t(), binary(), binary()) ::
          {:ok, Issue.t()}
          | {:error, :not_found | :invalid_policy_stages | :invalid_executor | Ecto.Changeset.t()}
  def assign_execution_policy(%Issue{} = issue, policy_id, executor_id) do
    case ExecutionPolicies.get_execution_policy(policy_id) do
      {:ok, %ExecutionPolicy{stage_configs: stage_configs} = policy} ->
        if length(stage_configs) == 0 do
          {:error, :invalid_policy_stages}
        else
          case Agents.get_agent(executor_id) do
            {:ok, _agent} ->
              state = ExecutionState.initialize(policy, executor_id)

              attrs = %{
                execution_policy_id: policy_id,
                execution_state: state,
                assignee_id: executor_id,
                status: :in_progress
              }

              update_issue(issue, attrs)

            {:error, _} ->
              {:error, :invalid_executor}
          end
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Handles a decision (approve/request_changes) for an issue with an execution policy.
  Advances the execution state and assigns the issue to the next participant.

  - :approve - advances to next stage or marks done if final stage
  - :request_changes - returns to executor with in_progress status
  """
  @spec execution_policy_decision(Issue.t(), :approve | :request_changes, binary()) ::
          {:ok, Issue.t()} | {:error, atom() | Ecto.Changeset.t()}
  def execution_policy_decision(%Issue{} = issue, decision, decided_by) do
    cond do
      not ExecutionState.active?(issue.execution_state) ->
        {:error, :execution_policy_not_active}

      decided_by != issue.execution_state.current_participant ->
        {:error, :unauthorized}

      true ->
        do_execution_policy_decision(issue, decision, decided_by)
    end
  end

  defp do_execution_policy_decision(%Issue{} = issue, decision, decided_by) do
    policy = ExecutionPolicies.get_execution_policy!(issue.execution_policy_id)

    case decision do
      :approve ->
        approved_state = ExecutionState.approve(issue.execution_state, decided_by)

        case ExecutionState.advance(approved_state, policy, decided_by) do
          {:done, final_state} ->
            update_issue(issue, %{
              status: :done,
              execution_state: final_state,
              assignee_id: nil
            })
            |> tap(fn {:ok, _} ->
              unblock_dependents(issue.id)
              _ = Wakes.notify_children_completed(issue)
            end)

          {:ok, next_state} ->
            next_assignee = next_state.current_participant

            update_issue(issue, %{
              execution_state: next_state,
              assignee_id: next_assignee,
              status: :in_review
            })
            |> tap(fn {:ok, _} ->
              wake_next_participant(next_assignee, issue.id)
            end)
        end

      :request_changes ->
        changes_state = ExecutionState.request_changes(issue.execution_state, decided_by)
        executor_id = issue.execution_state.return_assignee || changes_state.current_participant

        update_issue(issue, %{
          execution_state: changes_state,
          assignee_id: executor_id,
          status: :in_progress
        })
        |> tap(fn {:ok, _} ->
          wake_executor(executor_id, issue.id)
        end)
    end
  end

  defp wake_next_participant(assignee_id, issue_id) do
    if assignee_id do
      _ =
        Wakes.do_wake_agent(
          assignee_id,
          issue_id,
          "execution_policy_stage_transition",
          "system",
          nil,
          %{stage_type: "reviewer"}
        )
    end
  end

  defp wake_executor(executor_id, issue_id) do
    if executor_id do
      _ =
        Wakes.do_wake_agent(
          executor_id,
          issue_id,
          "execution_policy_stage_transition",
          "system",
          nil,
          %{stage_type: "executor", decision: "changes_requested"}
        )
    end
  end

  def add_label_to_issue(%Issue{} = issue, %Label{} = label) do
    issue = Repo.preload(issue, :labels)

    if Enum.any?(issue.labels, &(&1.id == label.id)) do
      {:ok, issue}
    else
      issue
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_assoc(:labels, issue.labels ++ [label])
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, Repo.preload(updated, [:comments, :blocked_by, :blocks, :labels])}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  def remove_label_from_issue(%Issue{} = issue, %Label{} = label) do
    issue = Repo.preload(issue, :labels)

    new_labels = Enum.reject(issue.labels, &(&1.id == label.id))

    issue
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:labels, new_labels)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, Repo.preload(updated, [:comments, :blocked_by, :blocks, :labels])}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def set_issue_labels(%Issue{} = issue, label_ids) when is_list(label_ids) do
    issue = Repo.preload(issue, :labels)
    labels = Repo.all(from l in Label, where: l.id in ^label_ids)

    issue
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:labels, labels)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, Repo.preload(updated, [:comments, :blocked_by, :blocks, :labels])}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp determine_update_event_type(old_issue, new_issue, attrs) do
    cond do
      Map.has_key?(attrs, :status) and old_issue.status != new_issue.status ->
        :issue_status_changed

      Map.has_key?(attrs, :assignee_id) and old_issue.assignee_id != new_issue.assignee_id ->
        :issue_assigned

      true ->
        :issue_updated
    end
  end

  defp build_update_metadata(old_issue, new_issue, attrs) do
    base = %{}

    base =
      if Map.has_key?(attrs, :status) do
        Map.put(base, :from, old_issue.status)
        |> Map.put(:to, new_issue.status)
      else
        base
      end

    base =
      if Map.has_key?(attrs, :assignee_id) do
        Map.put(base, :from_assignee_id, old_issue.assignee_id)
        |> Map.put(:to_assignee_id, new_issue.assignee_id)
      else
        base
      end

    base
  end

  def subscribe(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:issues")
  end

  def change_issue(%Issue{} = issue, attrs \\ %{}) do
    Issue.changeset(issue, attrs)
  end
end
