defmodule Cympho.Issues do
  @moduledoc """
  The Issues context for managing issues and their CRUD operations.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Issues.Issue
  alias Cympho.Issues.StateMachine
  alias Cympho.Comments

  @doc """
  Returns the list of issues.
  """
  def list_issues do
    Repo.all(Issue) |> Repo.preload([:comments, :blocked_by, :blocks])
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
    %Issue{}
    |> Issue.changeset(attrs)
    |> Repo.insert()
    |> then(fn {:ok, issue} ->
      Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:issue_created, issue})
      {:ok, Repo.preload(issue, [:comments, :blocked_by, :blocks])}
    end)
  end

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
      |> Repo.update()
    else
      {:error, :invalid_transition}
    end
  end

  defp do_update_issue(%Issue{} = issue, attrs) do
    issue
    |> Issue.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Transitions an issue to a new status, validating against the state machine.
  Returns {:ok, issue} or {:error, :invalid_transition}.
  """
  def transition_issue(%Issue{} = issue, new_status) do
    update_issue(issue, %{status: new_status})
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
    Enum.any?(blocked_by, fn blocker -> blocker.status != :closed end)
  end

  @doc """
  Gets the list of open issues that are blocking this issue.
  """
  def active_blockers(%Issue{} = issue) do
    blocked_by = issue.blocked_by || []
    Enum.filter(blocked_by, fn blocker -> blocker.status != :closed end)
  end

  @doc """
  Adds a blocker relationship: blocker_issue blocks blocked_issue.
  """
  def add_blocker(%Issue{} = blocked_issue, %Issue{} = blocker_issue) do
    if blocked_issue.id == blocker_issue.id do
      {:error, :cannot_block_self}
    else
      Repo.insert_all("issue_blockers", [
        %{
          blocked_issue_id: blocked_issue.id,
          blocking_issue_id: blocker_issue.id,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ], on_conflict: :nothing)
      {:ok, Repo.preload(blocked_issue, [:comments, :blocked_by, :blocks])}
    end
  end

  @doc """
  Removes a blocker relationship.
  """
  def remove_blocker(%Issue{} = blocked_issue, %Issue{} = blocker_issue) do
    from(bb in "issue_blockers",
      where: bb.blocked_issue_id == ^blocked_issue.id and bb.blocking_issue_id == ^blocker_issue.id
    )
    |> Repo.delete_all()

    {:ok, Repo.preload(blocked_issue, [:comments, :blocked_by, :blocks])}
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
