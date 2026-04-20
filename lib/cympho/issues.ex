defmodule Cympho.Issues do
  @moduledoc """
  The Issues context for managing issues and their CRUD operations.
  """
  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [optimistic_lock: 2]
  alias Cympho.Repo
  alias Cympho.Issues.Issue
  alias Cympho.Issues.StateMachine
  alias Cympho.Agents.Agent
  alias Cympho.Comments

  def list_issues(opts \\ %{}) do
    Issue
    |> maybe_filter_by_project(opts)
    |> Repo.all()
    |> Repo.preload([:comments, :blocked_by, :blocks, :assignee])
  end

  defp maybe_filter_by_project(query, %{project_id: project_id}) do
    where(query, project_id: ^project_id)
  end

  defp maybe_filter_by_project(query, _opts), do: query

  def list_issues_by_project(project_id) do
    Issue
    |> where(project_id: ^project_id)
    |> Repo.all()
    |> Repo.preload([:comments, :blocked_by, :blocks])
  end

  def get_issue!(id), do: Repo.get!(Issue, id) |> Repo.preload([:comments, :blocked_by, :blocks, :assignee])

  def get_issue(id) do
    case Repo.get(Issue, id) do
      nil -> {:error, :not_found}
      issue -> {:ok, Repo.preload(issue, [:comments, :blocked_by, :blocks, :assignee])}
    end
  end

  def create_issue(attrs \\ %{}) do
    attrs = maybe_generate_identifier(attrs)

    case %Issue{}
         |> Issue.changeset(attrs)
         |> Repo.insert() do
      {:ok, issue} ->
        Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:issue_created, issue})
        {:ok, Repo.preload(issue, [:comments, :blocked_by, :blocks])}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp maybe_generate_identifier(%{"project_id" => project_id} = attrs) do
    if Map.has_key?(attrs, "identifier") do
      attrs
    else
      project = Repo.get!(Cympho.Projects.Project, project_id)
      max_seq = Repo.one(from i in Issue, where: i.project_id == ^project_id, select: max fragment("CAST(SPLIT_PART(i.identifier, '-', 2) AS INTEGER)")) || 0
      seq = max_seq + 1
      Map.put(attrs, "identifier", "#{project.prefix}-#{seq}")
    end
  end

  defp maybe_generate_identifier(attrs), do: attrs

  def update_issue(%Issue{} = issue, attrs) do
    with {:ok, issue} <- do_update_issue(issue, attrs) do
      Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:issue_updated, issue})
      {:ok, Repo.preload(issue, [:comments, :blocked_by, :blocks])}
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

  def transition_issue(%Issue{} = issue, new_status) do
    cond do
      new_status == :done and is_blocked?(issue) ->
        {:error, :blocked_by_active_issues}

      not StateMachine.valid_transition?(issue.status, new_status) ->
        {:error, :invalid_transition}

      true ->
        with {:ok, updated} <- update_issue(issue, %{status: new_status}) do
          if new_status == :done, do: unblock_dependents(issue.id)
          {:ok, updated}
        end
    end
  end

  def valid_transitions(%Issue{} = issue) do
    StateMachine.valid_transitions(issue.status)
  end

  def is_blocked?(%Issue{} = issue) do
    blocked_by = issue.blocked_by || []
    Enum.any?(blocked_by, fn blocker -> blocker.status != :done end)
  end

  def active_blockers(%Issue{} = issue) do
    blocked_by = issue.blocked_by || []
    Enum.filter(blocked_by, fn blocker -> blocker.status != :done end)
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
      |> Enum.map(fn id ->
        if is_binary(id) and byte_size(id) == 16, do: Ecto.UUID.load!(id), else: id
      end)

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
        :ok = Cympho.AgentHeartbeat.set_working(issue.assignee_id, issue.id)
      rescue
        _ -> :ok
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

  def checkout_issue(%Issue{} = issue, %Agent{} = agent, required_role \\ nil) do
    checkout_issue(issue, agent.id, required_role)
  end

  def checkout_issue(%Agent{} = agent, %Issue{} = issue, required_role \\ nil) do
    checkout_issue(issue, agent.id, required_role)
  end

  def checkout_issue(%Issue{} = issue, agent_id, required_role) do
    current_issue = Repo.reload(issue)
    agent = Agents.get_agent!(agent_id)

    cond do
      current_issue.assignee_id != nil and current_issue.assignee_id != agent_id ->
        {:error, :already_assigned}

      current_issue.assignee_id == agent_id ->
        {:ok, current_issue}

      not Issue.role_authorized?(agent.role, required_role) ->
        {:error, :chain_of_command_violation}

      true ->
        new_status = if current_issue.status in [:backlog, :todo], do: :in_progress, else: current_issue.status
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
        blocked_binary = Ecto.UUID.dump!(blocked_issue.id)
        blocker_binary = Ecto.UUID.dump!(blocker_issue.id)
        now = DateTime.utc_now()

        Repo.transaction(fn ->
          Repo.query!("""
            INSERT INTO issue_blockers (blocked_issue_id, blocking_issue_id, inserted_at, updated_at)
            VALUES ($1, $2, $3, $4)
            ON CONFLICT DO NOTHING
          """, [blocked_binary, blocker_binary, now, now])

          Repo.reload(blocked_issue)
        end)
        |> case do
          {:ok, issue} -> {:ok, Repo.preload(issue, [:comments, :blocked_by, :blocks])}
          {:error, reason} -> {:error, reason}
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
      blocker_ids = Repo.all(
        from bb in "issue_blockers",
        where: bb.blocked_issue_id == type(^current_id, Ecto.UUID),
        select: bb.blocking_issue_id
      )
      Enum.any?(blocker_ids, fn blocker_id ->
        blocker_string =
          if is_binary(blocker_id) and byte_size(blocker_id) == 16 do
            Ecto.UUID.load!(blocker_id)
          else
            blocker_id
          end

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
        where: bb.blocked_issue_id == type(^blocked_issue.id, Ecto.UUID) and
               bb.blocking_issue_id == type(^blocker_issue.id, Ecto.UUID)
      )
      |> Repo.delete_all()

    if count == 0 do
      {:error, :not_found}
    else
      {:ok, Repo.preload(Repo.reload(blocked_issue), [:comments, :blocked_by, :blocks])}
    end
  end

  def delete_issue(%Issue{} = issue) do
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
