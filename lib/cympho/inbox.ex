defmodule Cympho.Inbox do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Inbox.InboxState

  @pubsub Cympho.PubSub
  @topic "inbox"

  def subscribe(agent_id) do
    Phoenix.PubSub.subscribe(@pubsub, "#{@topic}:#{agent_id}")
  end

  def unsubscribe(agent_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, "#{@topic}:#{agent_id}")
  end

  defp broadcast_change(agent_id, msg) do
    Phoenix.PubSub.broadcast(@pubsub, "#{@topic}:#{agent_id}", msg)
  end

  def get_inbox_state(issue_id, agent_id) do
    Repo.get_by(InboxState, issue_id: issue_id, agent_id: agent_id)
  end

  @doc """
  Total unread inbox items across all agents in the given company.
  Used by the sidebar badge.
  """
  def unread_count_for_company(company_id) do
    from(s in InboxState,
      join: a in Cympho.Agents.Agent,
      on: a.id == s.agent_id,
      where: a.company_id == ^company_id and s.status == "unread",
      select: count(s.id)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc """
  Recent inbox items across all agents in the given company. Used by the
  dashboard preview — kept small (10 by default) and preloaded with `:issue`.
  """
  def list_recent_for_company(company_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    status = Keyword.get(opts, :status)

    query =
      from(s in InboxState,
        join: a in Cympho.Agents.Agent,
        on: a.id == s.agent_id,
        where: a.company_id == ^company_id,
        order_by: [desc: s.inserted_at],
        limit: ^limit
      )

    query = if status, do: where(query, [s], s.status == ^status), else: query

    query
    |> Repo.all()
    |> Repo.preload([:issue, :agent])
  end

  def list_inbox_for_agent(agent_id, opts \\ []) do
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    query =
      from(s in InboxState,
        where: s.agent_id == ^agent_id,
        order_by: [desc: s.inserted_at],
        limit: ^limit,
        offset: ^offset
      )

    query = if status, do: where(query, status: ^status), else: query
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
    changeset =
      %InboxState{}
      |> InboxState.changeset(%{issue_id: issue_id, agent_id: agent_id, status: "unread"})

    case Repo.insert(
           changeset,
           on_conflict: :nothing,
           conflict_target: [:issue_id, :agent_id]
         ) do
      {:ok, _created} ->
        case get_inbox_state(issue_id, agent_id) do
          nil ->
            {:error, :not_found}

          state ->
            broadcast_change(agent_id, {:inbox_created, state})
            {:ok, state}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
