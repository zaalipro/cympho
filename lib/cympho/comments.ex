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
  alias Cympho.IssueReadStates

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
  def get_comment(id) do
    case Repo.get(Comment, id) do
      nil -> {:error, :not_found}
      comment -> {:ok, comment}
    end
  end

  def get_company_comment(company_id, id) when is_binary(company_id) do
    comment =
      Repo.one(
        from c in Comment,
          join: i in Issue,
          on: i.id == c.issue_id,
          where: i.company_id == ^company_id and c.id == ^id
      )

    case comment do
      nil -> {:error, :not_found}
      comment -> {:ok, comment}
    end
  end

  def get_company_comment(_company_id, _id), do: {:error, :not_found}

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
        Activities.log_activity(%{
          issue_id: comment.issue_id,
          actor_type: comment.author_type,
          actor_id: comment.author_id,
          action: "comment_added",
          metadata: %{comment_id: comment.id}
        })

        case Repo.get(Issue, comment.issue_id) do
          nil ->
            :ok

          issue ->
            issue = Repo.preload(issue, :comments)

            Cympho.RateLimiting.dedup_pubsub(
              Cympho.PubSub,
              "company:#{issue.company_id}:comments",
              {:comment_created, issue}
            )
        end

        CymphoWeb.Events.broadcast_comment(comment, :comment_created)

        # Notify users with read state about the new comment for unread tracking
        _ = IssueReadStates.notify_new_comment(comment.issue_id, comment.id)

        # Wake the assigned agent if the issue is active
        _ = Wakes.notify_comment(comment)
        maybe_reconcile_review_nudges(comment)

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
          nil ->
            :ok

          issue ->
            issue = Repo.preload(issue, :comments)

            Cympho.RateLimiting.dedup_pubsub(
              Cympho.PubSub,
              "company:#{issue.company_id}:comments",
              {:comment_updated, issue}
            )
        end

        CymphoWeb.Events.broadcast_comment(comment, :comment_updated)

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
          nil ->
            :ok

          issue ->
            issue = Repo.preload(issue, :comments)

            Cympho.RateLimiting.dedup_pubsub(
              Cympho.PubSub,
              "company:#{issue.company_id}:comments",
              {:comment_deleted, issue}
            )
        end

        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Subscribes to issue updates for real-time comment updates.
  """
  def subscribe(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:comments")
  end

  defp maybe_reconcile_review_nudges(comment) do
    unless auto_nudge_system_comment?(comment) do
      _ = Cympho.ReviewNudges.reconcile_issue(comment.issue_id)
    end

    :ok
  end

  defp auto_nudge_system_comment?(%Comment{author_type: "system", body: body})
       when is_binary(body) do
    String.starts_with?(body, "Auto-nudge ")
  end

  defp auto_nudge_system_comment?(_comment), do: false
end
