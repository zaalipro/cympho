defmodule Cympho.Comments do
  @moduledoc """
  The Comments context for managing comments on issues.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Comments.Comment
  alias Cympho.Issues.Issue

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
  """
  def create_comment(attrs \\ %{}) do
    %Comment{}
    |> Comment.changeset(attrs)
    |> Repo.insert()
    |> then(fn {:ok, comment} ->
      issue = Repo.get!(Issue, comment.issue_id) |> Repo.preload(:comments)
      Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:comment_created, issue})
      {:ok, comment}
    end)
  end

  @doc """
  Updates a comment.
  """
  def update_comment(%Comment{} = comment, attrs) do
    comment
    |> Comment.changeset(attrs)
    |> Repo.update()
    |> then(fn {:ok, comment} ->
      issue = Repo.get!(Issue, comment.issue_id) |> Repo.preload(:comments)
      Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:comment_updated, issue})
      {:ok, comment}
    end)
  end

  @doc """
  Deletes a comment.
  """
  def delete_comment(%Comment{} = comment) do
    issue_id = comment.issue_id
    Repo.delete(comment)
    |> then(fn {:ok, _comment} ->
      issue = Repo.get!(Issue, issue_id) |> Repo.preload(:comments)
      Phoenix.PubSub.broadcast(Cympho.PubSub, "issues", {:comment_deleted, issue})
      :ok
    end)
  end

  @doc """
  Subscribes to issue updates for real-time comment updates.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "issues")
  end
end
