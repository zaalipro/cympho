defmodule Cympho.Comments do
  @moduledoc """
  The Comments context for managing comments on issues.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Comments.Comment
  alias Cympho.Issues.Issue
  alias Cympho.Activities
  alias Cympho.Wakes

  @doc """
  Returns the list of comments for a given issue.
  """
  def list_comments(issue_id) do
    Comment
    |> where(issue_id: ^issue_id)
    |> order_by([c], asc: c.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single comment by id.
  """
  def get_comment!(id), do: Repo.get!(Comment, id)

  @doc """
  Creates a comment for an issue.
  After creation, triggers Wakes.notify_comment to wake the assigned agent if applicable.
  """
  def create_comment(attrs \\ %{}) do
    case %Comment{}
         |> Comment.changeset(attrs)
         |> Repo.insert() do
      {:ok, comment} ->
        Activities.log_activity(%{issue_id: comment.issue_id, actor_type: comment.author_type, actor_id: comment.author_id, action: "comment_added", metadata: %{comment_id: comment.id}})
        case Repo.get(Issue, comment.issue_id) do
          nil -> :ok
          issue ->
            issue = Repo.preload(issue, :comments)
            Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:comment_created, issue})
        end

        # Wake the assigned agent if the issue is active
        _ = Wakes.notify_comment(comment)

        {:ok, comment}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates a comment.
  """
  def update_comment(%Comment{} = comment, attrs) do
    case comment
         |> Comment.changeset(attrs)
         |> Repo.update() do
      {:ok, comment} ->
        case Repo.get(Issue, comment.issue_id) do
          nil -> :ok
          issue ->
            issue = Repo.preload(issue, :comments)
            Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:comment_updated, issue})
        end

        {:ok, comment}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes a comment.
  """
  def delete_comment(%Comment{} = comment) do
    issue_id = comment.issue_id

    case Repo.delete(comment) do
      {:ok, _comment} ->
        case Repo.get(Issue, issue_id) do
          nil -> :ok
          issue ->
            issue = Repo.preload(issue, :comments)
            Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:comment_deleted, issue})
        end

        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Subscribes to issue updates for real-time comment updates.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "issues")
  end
end
