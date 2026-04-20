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

  @doc """
  Returns the list of issues.
  """
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

  @doc """
  Returns the list of issues for a given project.
  """
  def list_issues_by_project(project_id) do
    Issue
    |> where(project_id: ^project_id)
    |> Repo.all()
    |> Repo.preload([:comments, :blocked_by, :blocks])
  end

  @doc """
  Gets a single issue by id.
  """
  def get_issue!(id), do: Repo.get!(Issue, id) |> Repo.preload([:comments, :blocked_by, :blocks, :assignee])

  @doc """
  Gets a single issue by id, returns {:ok, issue} or {:error, :not_found}.
  """
  def get_issue(id) do
    case Repo.get(Issue, id) do
      nil -> {:error, :not_found}
      issue -> {:ok, Repo.preload(issue, [:comments, :blocked_by, :blocks, :assignee])}
    end
  end

  @doc """
  Creates an issue.
  """
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

  @doc """
  Updates an issue.
  """
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

  @doc """
  Transitions an issue to a new status, validating against the state machine.
  Returns {:ok, issue} or {:error, :invalid_transition}.
  """
  def transition_issue(%Issue{} = issue, new_status) do
    cond do
      new_status == :done and is_blocked?(issue) ->
        {:error, :blocked_by_active_issues}

      not StateMachine.valid_transition?(issue.status, new_status) ->
        {:error, :invalid_transition}

      true ->
        update_issue(issue, %{status: new_status})
    end
  end

  @doc """
  Returns the list of valid transitions for an issue's current status.
  """
  def valid_transitions(%Issue{} = issue) do
    StateMachine.valid_transitions(issue.status)
  end

  @doc """
  Checks if the issue is blocked by any open issues.
  """
  def is_blocked?(%Issue{} = issue) do
    blocked_by = issue.blocked_by || []
    Enum.any?(blocked_by, fn blocker -> blocker.status != :done end)
  end

  @doc """
  Gets the list of open issues that are blocking this issue.
  """
  def active_blockers(%Issue{} = issue) do
    blocked_by = issue.blocked_by || []
    Enum.filter(blocked_by, fn blocker -> blocker.status != :done end)
  end

  @doc """
  Checks out an issue for an agent. Assigns the issue to the agent and transitions
  to :in_progress if the issue is in :backlog or :todo. Returns:
  - {:ok, issue} on success
  - {:error, :already_assigned} if issue is assigned to another agent
  - {:error, :stale} if lock version mismatch
  - {:error, :invalid_transition} if current status cannot transition to :in_progress
  """
  def checkout_issue(%Issue{} = issue, %Agent{} = agent) do
    checkout_issue(issue, agent.id)
  end

  def checkout_issue(%Agent{} = agent, %Issue{} = issue) do
    checkout_issue(issue, agent.id)
  end

  def checkout_issue(%Issue{} = issue, agent_id) do
    # Reload issue to get current state (assignee may have changed)
    current_issue = Repo.reload(issue)

    cond do
      current_issue.assignee_id != nil and current_issue.assignee_id != agent_id ->
        {:error, :already_assigned}

      not StateMachine.valid_transition?(current_issue.status, :in_progress) ->
        {:error, :invalid_transition}

      true ->
        update_issue(current_issue, %{assignee_id: agent_id, status: :in_progress})
        |> maybe_adjust_lock_version()
    end
  end

  @doc """
  Releases an issue, clearing the assignee and transitioning to :todo (or provided status).
  Returns {:ok, issue} or {:error, :invalid_transition}.
  """
  def release_issue(%Issue{} = issue, target_status \\ :todo) do
    update_issue(issue, %{assignee_id: nil, status: target_status})
    |> maybe_adjust_lock_version()
  end

  defp maybe_adjust_lock_version({:ok, issue}), do: {:ok, issue}
  defp maybe_adjust_lock_version({:error, _} = error), do: error

  @doc """
  Adds a blocker relationship: blocker_issue blocks blocked_issue.
  Rejects circular blocker chains.
  """
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
      binary_id = Ecto.UUID.dump!(current_id)
      blocker_ids = Repo.all(
        from bb in "issue_blockers",
        where: bb.blocked_issue_id == ^binary_id,
        select: bb.blocking_issue_id
      )
      Enum.any?(blocker_ids, fn blocker_id ->
        if blocker_id == target_id do
          true
        else
          do_transitively_blocked_by?(blocker_id, target_id, visited)
        end
      end)
    end
  end

  @doc """
  Removes a blocker relationship.
  """
  def remove_blocker(%Issue{} = blocked_issue, %Issue{} = blocker_issue) do
    count =
      from(bb in "issue_blockers",
        where: bb.blocked_issue_id == ^Ecto.UUID.dump!(blocked_issue.id) and
               bb.blocking_issue_id == ^Ecto.UUID.dump!(blocker_issue.id)
      )
      |> Repo.delete_all()
      |> elem(1)

    if count == 0 do
      {:error, :not_found}
    else
      {:ok, Repo.preload(Repo.reload(blocked_issue), [:comments, :blocked_by, :blocks])}
    end
  end

  @doc """
  Deletes an issue.
  """
  def delete_issue(%Issue{} = issue) do
    case Repo.delete(issue) do
      {:ok, _issue} ->
        Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:issue_deleted, issue.id})
        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Subscribes to issue updates.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "issues")
  end

  @doc """
  Returns a changeset for creating a new issue.
  """
  def change_issue(%Issue{} = issue, attrs \\ %{}) do
    Issue.changeset(issue, attrs)
  end
end
