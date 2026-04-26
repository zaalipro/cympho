defmodule Cympho.Inbox do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Inbox.InboxState

  @pubsub Cympho.PubSub
  @topic "inbox"

  def subscribe(agent_id) do
    Phoenix.PubSub.subscribe(@pubsub, "#{@topic}:#{agent_id}")
  end

  defp broadcast_change(agent_id, msg) do
    Phoenix.PubSub.broadcast(@pubsub, "#{@topic}:#{agent_id}", msg)
  end

  def get_inbox_state(issue_id, agent_id) do
    Repo.get_by(InboxState, issue_id: issue_id, agent_id: agent_id)
  end

  def list_inbox_for_agent(agent_id, opts \\ []) do
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    query = from(s in InboxState,
      where: s.agent_id == ^agent_id,
      order_by: [desc: s.inserted_at],
      limit: ^limit,
      offset: ^offset)

    query = if status && status != "", do: where(query, status: ^status), else: query
    Repo.all(query) |> Repo.preload([:issue])
  end

  def mark_read(issue_id, agent_id) do
    case get_inbox_state(issue_id, agent_id) do
      nil ->
        {:error, :not_found}

      state ->
        case state |> InboxState.read_changeset() |> Repo.update() do
          {:ok, updated} ->
            broadcast_change(agent_id, {:inbox_updated, updated})
            {:ok, updated}

          error ->
            error
        end
    end
  end

  def dismiss(issue_id, agent_id) do
    case get_inbox_state(issue_id, agent_id) do
      nil ->
        {:error, :not_found}

      state ->
        case state |> InboxState.dismiss_changeset() |> Repo.update() do
          {:ok, updated} ->
            broadcast_change(agent_id, {:inbox_updated, updated})
            {:ok, updated}

          error ->
            error
        end
    end
  end

  def archive(issue_id, agent_id) do
    case get_inbox_state(issue_id, agent_id) do
      nil ->
        {:error, :not_found}

      state ->
        case state |> InboxState.archive_changeset() |> Repo.update() do
          {:ok, updated} ->
            broadcast_change(agent_id, {:inbox_updated, updated})
            {:ok, updated}

          error ->
            error
        end
    end
  end

  def restore(issue_id, agent_id) do
    case get_inbox_state(issue_id, agent_id) do
      nil ->
        {:error, :not_found}

      state ->
        case state |> InboxState.restore_changeset() |> Repo.update() do
          {:ok, updated} ->
            broadcast_change(agent_id, {:inbox_updated, updated})
            {:ok, updated}

          error ->
            error
        end
    end
  end

  def ensure_inbox_entry(issue_id, agent_id) do
    case get_inbox_state(issue_id, agent_id) do
      nil ->
        changeset = InboxState.changeset(%InboxState{}, %{
          issue_id: issue_id,
          agent_id: agent_id,
          status: "unread"
        })

        case Repo.insert(changeset, on_conflict: :nothing) do
          {:ok, created} ->
            broadcast_change(agent_id, {:inbox_created, created})
            {:ok, created}

          {:error, _} = error ->
            # If insert failed due to constraint violation, fetch the existing record
            case get_inbox_state(issue_id, agent_id) do
              nil -> error
              existing -> {:ok, existing}
            end
        end

      existing ->
        {:ok, existing}
    end
  end
end
