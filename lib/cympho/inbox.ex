defmodule Cympho.Inbox do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Inbox.InboxState
  alias Cympho.Wakes

  @pubsub Cympho.PubSub
  @topic "inbox"
  @company_badge_topic "company_inbox_badges"

  def subscribe(agent_id) do
    Phoenix.PubSub.subscribe(@pubsub, "#{@topic}:#{agent_id}")
  end

  def subscribe_company_badges(company_id) when is_binary(company_id) do
    Phoenix.PubSub.subscribe(@pubsub, "#{@company_badge_topic}:#{company_id}")
  end

  def unsubscribe(agent_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, "#{@topic}:#{agent_id}")
  end

  defp broadcast_change(agent_id, msg) do
    Phoenix.PubSub.broadcast(@pubsub, "#{@topic}:#{agent_id}", msg)
  end

  defp broadcast_company_badge_change(company_id) when is_binary(company_id) do
    count = unread_count_for_company(company_id)

    Phoenix.PubSub.broadcast(
      @pubsub,
      "#{@company_badge_topic}:#{company_id}",
      {:company_inbox_count_changed, company_id, count}
    )
  end

  defp broadcast_company_badge_change(_company_id), do: :ok

  defp broadcast_agent_company_badge_change(agent_id) when is_binary(agent_id) do
    agent_id
    |> company_id_for_agent()
    |> broadcast_company_badge_change()
  end

  defp broadcast_agent_company_badge_change(_agent_id), do: :ok

  def get_inbox_state(issue_id, agent_id) do
    Repo.get_by(InboxState, issue_id: issue_id, agent_id: agent_id)
  end

  @doc """
  Preload a single inbox state into the same shape `list_inbox_for_agent_page/2`
  returns — used for targeted stream updates in the inbox LiveView.
  """
  def preload_item(%InboxState{} = state) do
    [state] |> preload_inbox_items() |> List.first()
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

  @doc "Counts company unread rows except issues already represented by owner attention."
  def unread_count_for_company_excluding_issues(company_id, issue_ids)
      when is_binary(company_id) and is_list(issue_ids) do
    query =
      from(s in InboxState,
        join: a in Cympho.Agents.Agent,
        on: a.id == s.agent_id,
        where: a.company_id == ^company_id and s.status == "unread"
      )

    query =
      case Enum.filter(issue_ids, &is_binary/1) do
        [] -> query
        ids -> where(query, [s, _a], s.issue_id not in ^ids)
      end

    query
    |> Repo.aggregate(:count)
    |> Kernel.||(0)
  end

  def unread_count_for_company_excluding_issues(_company_id, _issue_ids), do: 0

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

  @doc """
  Keyset (infinite-scroll) page of an agent's inbox, newest first. Returns a
  `Cympho.Pagination.Page` with the same preloads as `list_inbox_for_agent/2`.
  """
  def list_inbox_for_agent_page(agent_id, opts \\ []) do
    status = Keyword.get(opts, :status)

    base = from(s in InboxState, where: s.agent_id == ^agent_id)
    base = if status, do: where(base, [s], s.status == ^status), else: base

    base
    |> Cympho.Pagination.page(
      limit: Keyword.get(opts, :limit, 100),
      after: Keyword.get(opts, :after),
      cursor_fields: [{:inserted_at, :desc}, {:id, :desc}]
    )
    |> then(fn page -> %{page | entries: preload_inbox_items(page.entries)} end)
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
            broadcast_agent_company_badge_change(agent_id)
            {:ok, updated}

          error ->
            error
        end
    end
  end

  def mark_unread_read_for_agent(agent_id) when is_binary(agent_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(s in InboxState,
        where: s.agent_id == ^agent_id and s.status == "unread"
      )
      |> Repo.update_all(set: [status: "read", read_at: now, updated_at: now])

    if count > 0 do
      broadcast_change(agent_id, {:inbox_bulk_updated, agent_id})
      broadcast_agent_company_badge_change(agent_id)
    end

    {:ok, count}
  end

  def mark_unread_read_for_agent(_agent_id), do: {:error, :invalid_agent}

  def mark_unread_read_for_company(company_id) when is_binary(company_id) do
    unread_agent_ids =
      from(s in InboxState,
        join: a in Cympho.Agents.Agent,
        on: a.id == s.agent_id,
        where: a.company_id == ^company_id and s.status == "unread",
        distinct: true,
        select: s.agent_id
      )
      |> Repo.all()

    if unread_agent_ids == [] do
      {:ok, 0}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {count, _} =
        from(s in InboxState,
          where: s.agent_id in ^unread_agent_ids and s.status == "unread"
        )
        |> Repo.update_all(set: [status: "read", read_at: now, updated_at: now])

      Enum.each(unread_agent_ids, fn agent_id ->
        broadcast_change(agent_id, {:inbox_bulk_updated, agent_id})
      end)

      broadcast_company_badge_change(company_id)
      {:ok, count}
    end
  end

  def mark_unread_read_for_company(_company_id), do: {:error, :invalid_company}

  def dismiss(issue_id, agent_id) do
    case get_inbox_state(issue_id, agent_id) do
      nil ->
        {:error, :not_found}

      state ->
        case state |> InboxState.dismiss_changeset() |> Repo.update() do
          {:ok, updated} ->
            broadcast_change(agent_id, {:inbox_updated, updated})
            broadcast_agent_company_badge_change(agent_id)
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
            broadcast_agent_company_badge_change(agent_id)
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
            broadcast_agent_company_badge_change(agent_id)
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
            broadcast_agent_company_badge_change(agent_id)
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
        broadcast_agent_company_badge_change(state.agent_id)
        updated

      {:error, _changeset} ->
        state
    end
  end

  defp attach_review_nudges([]), do: []

  defp attach_review_nudges(items) do
    issue_ids = items |> Enum.map(& &1.issue_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    items_by_pair = Map.new(items, &{{&1.issue_id, &1.agent_id}, &1})
    run_counts = run_counts_by_issue(issue_ids)

    nudges_by_pair =
      issue_ids
      |> Wakes.list_review_nudges()
      |> Enum.group_by(&{&1.issue_id, &1.agent_id})
      |> Map.new(fn {pair, [wake | _]} ->
        item = Map.get(items_by_pair, pair)
        issue = item && item.issue
        run_count = Map.get(run_counts, wake.issue_id, 0)

        {pair, review_nudge_map(wake, issue, run_count)}
      end)

    Enum.map(items, fn item ->
      %{item | review_nudge: Map.get(nudges_by_pair, {item.issue_id, item.agent_id})}
    end)
  end

  defp company_id_for_agent(agent_id) do
    Repo.one(
      from a in Cympho.Agents.Agent,
        where: a.id == ^agent_id,
        select: a.company_id
    )
  end

  defp run_counts_by_issue([]), do: %{}

  defp run_counts_by_issue(issue_ids) do
    Run
    |> where([r], r.issue_id in ^issue_ids)
    |> group_by([r], r.issue_id)
    |> select([r], {r.issue_id, count(r.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp review_nudge_map(wake, issue, run_count) do
    metadata = wake.metadata || %{}
    pre_runtime? = pre_runtime_review_nudge?(issue, metadata, run_count)

    %{
      wake_id: wake.id,
      status: wake.status,
      label: review_nudge_label(pre_runtime?),
      summary: review_nudge_summary(metadata, pre_runtime?),
      blocker_labels: List.wrap(metadata["blocker_labels"]),
      prompt: metadata["prompt"],
      target_path: review_nudge_target_path(pre_runtime?),
      target_label: review_nudge_target_label(pre_runtime?),
      queued_at: wake.inserted_at
    }
  end

  defp pre_runtime_review_nudge?(%{status: status}, metadata, 0)
       when status in [:todo, "todo"] do
    metadata
    |> Map.get("blocker_keys", metadata["blocker_key"])
    |> List.wrap()
    |> Enum.any?(fn key ->
      to_string(key) in ["runtime_verification", "agent_note", "work_product"]
    end)
  end

  defp pre_runtime_review_nudge?(_issue, _metadata, _run_count), do: false

  defp review_nudge_label(true), do: "Runtime launch needed"
  defp review_nudge_label(false), do: "Review evidence needed"

  defp review_nudge_summary(_metadata, true) do
    "Runtime has not produced evidence yet. Open the launch checklist or issue preflight before asking for delivery notes."
  end

  defp review_nudge_summary(metadata, false), do: metadata["summary"] || "Review evidence needed"

  defp review_nudge_target_path(true), do: "/operations#runtime-launch-checklist"
  defp review_nudge_target_path(false), do: nil

  defp review_nudge_target_label(true), do: "Open launch checklist"
  defp review_nudge_target_label(false), do: nil
end
