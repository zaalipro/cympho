defmodule Cympho.Issues do
  @moduledoc """
  The Issues context for managing issues and their CRUD operations.
  """
  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [optimistic_lock: 3]
  alias Cympho.Repo
  alias Cympho.Issues.Issue
  alias Cympho.Issues.StateMachine
  alias Cympho.Comments

  @doc """
  Returns the list of issues.
  """
  def list_issues(opts \\ %{}) do
    Issue
    |> maybe_filter_by_project(opts)
    |> Repo.all()
    |> Repo.preload([:comments, :blocked_by, :blocks])
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
  def get_issue!(id), do: Repo.get!(Issue, id) |> Repo.preload([:comments, :blocked_by, :blocks])

  @doc """
  Gets a single issue by id, returns {:ok, issue} or {:error, :not_found}.
  """
  def get_issue(id) do
    case Repo.get(Issue, id) do
      nil -> {:error, :not_found}
      issue -> {:ok, Repo.preload(issue, [:comments, :blocked_by, :blocks])}
    end
  end

  @doc """
  Creates an issue.
  """
  def create_issue(attrs \\ %{}) do
    attrs = maybe_generate_identifier(attrs)
    %Issue{}
    |> Issue.changeset(attrs)
    |> Repo.insert()
    |> then(fn {:ok, issue} ->
      Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:issue_created, issue})
      {:ok, Repo.preload(issue, [:comments, :blocked_by, :blocks])}
    end)
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

  defp do_update_issue(%Issue{} = issue, %{status: new_status} = attrs) do
    if StateMachine.valid_transition?(issue.status, new_status) do
      issue
      |> Issue.changeset(attrs)
      |> optimistic_lock(:lock_version, [:lock_version])
      |> Repo.update()
    else
      {:error, :invalid_transition}
    end
  end

  defp do_update_issue(%Issue{} = issue, attrs) do
    issue
    |> Issue.changeset(attrs)
    |> optimistic_lock(:lock_version, [:lock_version])
    |> Repo.update()
  end

  @doc """
  Transitions an issue to a new status, validating against the state machine.
  Returns {:ok, issue} or {:error, :invalid_transition}.
  """
  def transition_issue(%Issue{} = issue, new_status) do
    if new_status == :done and is_blocked?(issue) do
      {:error, :blocked_by_active_issues}
    else
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
        Repo.transaction(fn ->
          Repo.insert_all("issue_blockers", [
            %{
              blocked_issue_id: blocked_issue.id,
              blocking_issue_id: blocker_issue.id,
              inserted_at: DateTime.utc_now(),
              updated_at: DateTime.utc_now()
            }
          ], on_conflict: :nothing)

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
      blocker_ids = Repo.all(from bb in "issue_blockers", where: bb.blocked_issue_id == ^current_id, select: bb.blocking_issue_id)
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
        where: bb.blocked_issue_id == ^blocked_issue.id and bb.blocking_issue_id == ^blocker_issue.id
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
    Repo.delete(issue)
    |> then(fn {:ok, _issue} ->
      Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:issue_deleted, issue.id})
      :ok
    end)
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
