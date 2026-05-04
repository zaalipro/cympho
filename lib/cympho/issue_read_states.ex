defmodule Cympho.IssueReadStates do
  @moduledoc """
  Context for managing issue read states per user.

  Tracks when each user last read an issue and which comment they last read.
  This enables granular unread tracking - users see which comments are new since their last visit.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.IssueReadStates.IssueReadState

  @pubsub Cympho.PubSub
  @topic "issue_read_states"

  @doc """
  Subscribe to issue read state updates for a user.
  """
  def subscribe(user_id) do
    Phoenix.PubSub.subscribe(@pubsub, "#{@topic}:#{user_id}")
  end

  defp broadcast_change(user_id, msg) do
    Phoenix.PubSub.broadcast(@pubsub, "#{@topic}:#{user_id}", msg)
  end

  @doc """
  Get the read state for a specific user and issue.
  """
  def get_read_state(user_id, issue_id) do
    Repo.get_by(IssueReadState, user_id: user_id, issue_id: issue_id)
  end

  @doc """
  Get the read state or return a default (not read) struct.
  """
  def get_read_state_or_default(user_id, issue_id) do
    case get_read_state(user_id, issue_id) do
      nil ->
        %IssueReadState{
          user_id: user_id,
          issue_id: issue_id,
          last_read_at: nil,
          last_read_comment_id: nil
        }

      state ->
        state
    end
  end

  @doc """
  Get unread comments for a user on a specific issue.
  Returns {read_state, list of new comments}.
  """
  def get_unread_comments(user_id, issue_id) do
    case get_read_state(user_id, issue_id) do
      nil ->
        # Never read - all comments are unread
        comments = Cympho.Comments.list_comments(issue_id)
        {nil, comments}

      state ->
        last_read_comment_id = state.last_read_comment_id

        if last_read_comment_id do
          # Find all comments after the last read comment
          all_comments = Cympho.Comments.list_comments(issue_id)

          new_comments =
            Enum.drop_while(all_comments, fn c -> c.id != last_read_comment_id end) |> tl()

          {state, new_comments}
        else
          # Has read state but no last_read_comment_id - use last_read_at
          all_comments = Cympho.Comments.list_comments(issue_id)

          new_comments =
            Enum.filter(all_comments, fn c ->
              DateTime.compare(c.inserted_at, state.last_read_at) == :gt
            end)

          {state, new_comments}
        end
    end
  end

  @doc """
  Check if an issue has unread comments for a user.
  """
  def has_unread?(user_id, issue_id) do
    {_state, new_comments} = get_unread_comments(user_id, issue_id)
    length(new_comments) > 0
  end

  @doc """
  Get count of unread comments for an issue for a user.
  """
  def unread_count(user_id, issue_id) do
    {_state, new_comments} = get_unread_comments(user_id, issue_id)
    length(new_comments)
  end

  @doc """
  Mark an issue as read up to (and including) a specific comment.
  """
  def mark_read(user_id, issue_id, last_read_comment_id \\ nil)

  def mark_read(user_id, issue_id, last_read_comment_id) when is_binary(last_read_comment_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case get_read_state(user_id, issue_id) do
      nil ->
        %IssueReadState{}
        |> IssueReadState.changeset(%{
          user_id: user_id,
          issue_id: issue_id,
          last_read_at: now,
          last_read_comment_id: last_read_comment_id
        })
        |> Repo.insert()
        |> case do
          {:ok, state} ->
            broadcast_change(user_id, {:issue_read_state_updated, issue_id})
            {:ok, state}

          error ->
            error
        end

      existing ->
        existing
        |> IssueReadState.changeset(%{
          last_read_at: now,
          last_read_comment_id: last_read_comment_id
        })
        |> Repo.update()
        |> case do
          {:ok, state} ->
            broadcast_change(user_id, {:issue_read_state_updated, issue_id})
            {:ok, state}

          error ->
            error
        end
    end
  end

  def mark_read(user_id, issue_id, nil) do
    # No specific comment - mark based on latest comment for this issue
    comments = Cympho.Comments.list_comments(issue_id)
    last_comment = List.last(comments)
    last_comment_id = if last_comment, do: last_comment.id, else: nil
    mark_read(user_id, issue_id, last_comment_id)
  end

  @doc """
  Mark all issues as read for a user (bulk operation).
  """
  def mark_all_read(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Get all issues the user has viewed (has read states)
    existing_states =
      Repo.all(
        from rs in IssueReadState,
          where: rs.user_id == ^user_id,
          select: rs
      )

    # For each issue, update to mark as read with latest comment
    results =
      Enum.map(existing_states, fn state ->
        comments = Cympho.Comments.list_comments(state.issue_id)
        last_comment = List.last(comments)
        last_comment_id = if last_comment, do: last_comment.id, else: nil

        state
        |> IssueReadState.changeset(%{
          last_read_at: now,
          last_read_comment_id: last_comment_id
        })
        |> Repo.update()
      end)

    # Broadcast update for each changed issue
    Enum.each(results, fn
      {:ok, state} -> broadcast_change(user_id, {:issue_read_state_updated, state.issue_id})
      _ -> :ok
    end)

    {:ok, length(results)}
  end

  @doc """
  Mark an issue as read and return the new read state.
  Called when a user views an issue detail page.
  """
  def ensure_read(user_id, issue_id) do
    comments = Cympho.Comments.list_comments(issue_id)
    last_comment = List.last(comments)
    last_comment_id = if last_comment, do: last_comment.id, else: nil
    mark_read(user_id, issue_id, last_comment_id)
  end

  @doc """
  Broadcast read state update to users who have read this issue but haven't read past the new comment.
  Called when a new comment is created so those users see updated unread counts.
  """
  def notify_new_comment(issue_id, comment_id) do
    # Get all users who have a read_state for this issue where last_read_comment_id is before the new comment
    user_ids =
      Repo.all(
        from rs in IssueReadState,
          where: rs.issue_id == ^issue_id,
          where: rs.last_read_comment_id < ^comment_id,
          select: rs.user_id
      )
      |> Enum.uniq()

    # Broadcast to each user's topic
    Enum.each(user_ids, fn user_id ->
      broadcast_change(user_id, {:issue_read_state_updated, issue_id})
    end)

    :ok
  end
end
