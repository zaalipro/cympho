defmodule Cympho.Wakes do
  @moduledoc """
  The Wakes context handles agent wake triggers and comment-driven notifications.

  Wake dispatch triggers agent heartbeats on relevant events:
  - Comment on an in_progress issue wakes the assigned agent
  - All blockers done on a blocked issue wakes the assignee
  - All children done on a parent issue wakes the parent assignee
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Wakes.AgentWake
  alias Cympho.Issues.Issue
  alias Cympho.Comments.Comment
  alias Cympho.HeartbeatEngine.WakeupQueue
  require Logger

  @doc """
  Notifies the agent assigned to an issue about a new comment.
  Wakes the agent if the issue is in :in_progress or :blocked status and has an assignee.

  Takes a Comment struct and:
  1. Checks the issue's status and assignee
  2. Logs the wake attempt in agent_wakes
  3. Triggers an immediate heartbeat for the assignee

  Returns {:ok, agent_wake} if wake was triggered, {:error, reason} otherwise.
  """
  @spec notify_comment(Comment.t()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def notify_comment(%Comment{} = comment) do
    issue = Repo.get!(Issue, comment.issue_id) |> Repo.preload(:assignee)

    cond do
      issue.status not in [:in_progress, :blocked, :in_review] ->
        {:error, :issue_not_active}

      is_nil(issue.assignee_id) ->
        {:error, :no_assignee}

      true ->
        reason = determine_comment_reason(comment, issue)

        do_wake_agent(
          issue.assignee_id,
          issue.id,
          reason,
          comment.author_type,
          comment.author_id,
          %{comment_id: comment.id}
        )
    end
  end

  defp determine_comment_reason(comment, _issue) do
    body = comment.body || ""

    if String.contains?(body, "@") do
      "issue_comment_mentioned"
    else
      "issue_commented"
    end
  end

  @doc """
  Notifies the agent assigned to a blocked issue when all blockers are resolved.
  Called after an issue transitions to :done - checks if any dependent issues
  had this issue as a blocker and all their blockers are now done.
  """
  @spec notify_blockers_resolved(Issue.t()) :: [
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
        ]
  def notify_blockers_resolved(%Issue{} = blocker_issue) do
    dependent_ids =
      Repo.all(
        from bb in "issue_blockers",
          where: bb.blocking_issue_id == type(^blocker_issue.id, Ecto.UUID),
          select: bb.blocked_issue_id
      )
      |> Enum.map(&load_uuid/1)

    Enum.map(dependent_ids, fn dependent_id ->
      case Repo.get(Issue, dependent_id) do
        nil ->
          {:error, :issue_not_found}

        dependent ->
          dependent = Repo.preload(dependent, [:assignee, :blocked_by])

          if all_blockers_done?(dependent) and dependent.status == :blocked and
               dependent.assignee_id do
            do_wake_agent(
              dependent.assignee_id,
              dependent.id,
              "issue_blockers_resolved",
              "system",
              blocker_issue.id,
              %{blocker_id: blocker_issue.id}
            )
          else
            {:error, :not_fully_unblocked}
          end
      end
    end)
  end

  @doc """
  Notifies the agent assigned to a parent issue when all children are completed.
  Called after a child issue transitions to :done.
  """
  @spec notify_children_completed(Issue.t()) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def notify_children_completed(%Issue{} = child_issue) do
    if is_nil(child_issue.parent_id) do
      {:error, :no_parent}
    else
      parent = Repo.get!(Issue, child_issue.parent_id) |> Repo.preload([:assignee, :children])

      cond do
        is_nil(parent.assignee_id) ->
          {:error, :no_assignee}

        not all_children_done?(parent) ->
          {:error, :children_not_all_done}

        parent.status not in [:in_progress, :blocked, :todo] ->
          {:error, :parent_not_active}

        true ->
          do_wake_agent(
            parent.assignee_id,
            parent.id,
            "issue_children_completed",
            "system",
            child_issue.id,
            %{child_id: child_issue.id}
          )
      end
    end
  end

  @doc """
  Low-level function to wake an agent directly. Persists the wake to the
  WakeupQueue, which broadcasts to the agent's heartbeat process via PubSub.
  Returns once the row is durable; the heartbeat trigger and dispatcher
  pickup happen asynchronously off the broadcast.
  """
  @spec do_wake_agent(
          String.t(),
          String.t() | nil,
          String.t(),
          String.t() | nil,
          String.t() | nil,
          map()
        ) ::
          {:ok, AgentWake.t()} | {:error, atom() | Ecto.Changeset.t()}
  def do_wake_agent(agent_id, issue_id, reason, triggered_by_type, triggered_by_id, metadata) do
    attrs = %{
      agent_id: agent_id,
      issue_id: issue_id,
      reason: reason,
      triggered_by_type: triggered_by_type,
      triggered_by_id: triggered_by_id,
      metadata: metadata
    }

    case WakeupQueue.enqueue(attrs) do
      {:ok, agent_wake} ->
        Logger.info("Wakes: enqueued wake for agent #{agent_id}, reason: #{reason}")
        {:ok, agent_wake}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns the list of wakes for a given agent.
  """
  def list_agent_wakes(agent_id) do
    AgentWake
    |> where(agent_id: ^agent_id)
    |> order_by([w], desc: w.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns the list of wakes for a given issue.
  """
  def list_issue_wakes(issue_id) do
    AgentWake
    |> where(issue_id: ^issue_id)
    |> order_by([w], desc: w.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single agent wake by id.
  """
  def get_agent_wake!(id), do: Repo.get!(AgentWake, id)

  defp all_blockers_done?(%Issue{} = issue) do
    blockers = issue.blocked_by || []
    Enum.all?(blockers, fn blocker -> blocker.status == :done end)
  end

  defp all_children_done?(%Issue{} = issue) do
    children = issue.children || []

    if children == [] do
      Logger.warning("all_children_done?: children not preloaded for issue #{issue.id}")
    end

    Enum.all?(children, fn child -> child.status == :done end)
  end

  defp load_uuid(id) do
    if is_binary(id) and byte_size(id) == 16 do
      Ecto.UUID.load!(id)
    else
      id
    end
  end
end
