defmodule Cympho.Inbox do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Inbox.InboxState
  alias Cympho.Wakes

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
    |> preload_inbox_items()
  end

  def status_counts_for_company(company_id) do
    from(s in InboxState,
      join: a in Cympho.Agents.Agent,
      on: a.id == s.agent_id,
      where: a.company_id == ^company_id,
      group_by: s.status,
      select: {s.status, count(s.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  def status_counts_for_agent(agent_id) do
    from(s in InboxState,
      where: s.agent_id == ^agent_id,
      group_by: s.status,
      select: {s.status, count(s.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  def counts_by_agent_for_company(company_id) do
    from(s in InboxState,
      join: a in Cympho.Agents.Agent,
      on: a.id == s.agent_id,
      where: a.company_id == ^company_id,
      group_by: [s.agent_id, s.status],
      select: {s.agent_id, s.status, count(s.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {agent_id, status, count}, acc ->
      Map.update(acc, agent_id, %{status => count}, &Map.put(&1, status, count))
    end)
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
    query |> Repo.all() |> preload_inbox_items()
  end

  defp preload_inbox_items(items) do
    items
    |> Repo.preload([:agent, issue: [:comments, :assignee, :project]])
    |> attach_review_nudges()
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

  def notify_entry_updated(issue_id, agent_id) do
    case get_inbox_state(issue_id, agent_id) do
      nil ->
        :ok

      state ->
        broadcast_change(agent_id, {:inbox_updated, state})
        :ok
    end
  end

  def ensure_inbox_entry(issue_id, agent_id, opts \\ []) do
    refresh? = Keyword.get(opts, :refresh?, false)

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
            state = maybe_refresh_state(state, refresh?)
            broadcast_change(agent_id, {:inbox_created, state})
            {:ok, state}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp maybe_refresh_state(state, false), do: state

  defp maybe_refresh_state(state, true) do
    case state |> InboxState.restore_changeset() |> Repo.update() do
      {:ok, updated} ->
        broadcast_change(state.agent_id, {:inbox_updated, updated})
        updated

      {:error, _changeset} ->
        state
    end
  end

  defp attach_review_nudges([]), do: []

  defp attach_review_nudges(items) do
    issue_ids = items |> Enum.map(& &1.issue_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    nudges_by_pair =
      issue_ids
      |> Wakes.list_review_nudges()
      |> Enum.group_by(&{&1.issue_id, &1.agent_id})
      |> Map.new(fn {pair, [wake | _]} -> {pair, review_nudge_map(wake)} end)

    Enum.map(items, fn item ->
      %{item | review_nudge: Map.get(nudges_by_pair, {item.issue_id, item.agent_id})}
    end)
  end

  defp review_nudge_map(wake) do
    metadata = wake.metadata || %{}

    %{
      wake_id: wake.id,
      status: wake.status,
      summary: metadata["summary"] || "Review evidence needed",
      blocker_labels: List.wrap(metadata["blocker_labels"]),
      prompt: metadata["prompt"],
      queued_at: wake.inserted_at
    }
  end
end
