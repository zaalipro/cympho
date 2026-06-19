defmodule Cympho.HeartbeatEngine.WakeupQueue do
  @moduledoc """
  DB-backed wakeup queue with coalescing.

  Multiple wake events for the same agent/issue pair are coalesced into a single
  wake record. When a new wake arrives for an agent that already has a pending wake,
  the existing record is updated with the latest reason and metadata instead of
  creating a duplicate.
  """

  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Wakes.AgentWake
  require Logger

  # Default cap on pending wakes per agent. Without this a runaway agent
  # (or a noisy upstream) can insert wakes faster than the agent consumes
  # them and grow the `agent_wakes` table without bound. Reads/writes scale
  # O(pending) within the dequeue path, so the cap is also a latency floor.
  # Read at runtime so tests can adjust it via Application.put_env.
  @default_max_pending_wakes_per_agent 100
  @default_recent_duplicate_window_seconds 90
  @recent_duplicate_exempt_reasons ~w(manual_dispatch runtime_retry company_resumed)

  defp max_pending_wakes_per_agent do
    Application.get_env(:cympho, :wakeup_queue, [])
    |> Keyword.get(:max_pending_per_agent, @default_max_pending_wakes_per_agent)
  end

  defp recent_duplicate_window_seconds do
    Application.get_env(:cympho, :wakeup_queue, [])
    |> Keyword.get(:recent_duplicate_window_seconds, @default_recent_duplicate_window_seconds)
  end

  @doc """
  Enqueues a wake event, coalescing if a pending wake already exists for this agent/issue pair.

  Returns `{:ok, agent_wake}` with either the new or updated record. When the
  per-agent pending cap is exceeded and there's no existing wake to coalesce
  with, returns `{:error, :wakeup_queue_full}`. When the same wake was just
  consumed, returns `{:error, :recent_duplicate_wake}` to avoid stale payload
  loops re-opening an issue immediately.
  """
  @spec enqueue(map()) ::
          {:ok, AgentWake.t()}
          | {:error, Ecto.Changeset.t() | :wakeup_queue_full | :recent_duplicate_wake}
  def enqueue(%{agent_id: agent_id, issue_id: issue_id, reason: reason} = attrs) do
    triggered_by_type = attr(attrs, :triggered_by_type, "system") || "system"
    triggered_by_id = attr(attrs, :triggered_by_id)
    metadata = attr(attrs, :metadata, %{}) || %{}

    existing =
      AgentWake
      |> where([w], w.agent_id == ^agent_id and w.reason == ^reason and w.status == "pending")
      |> where_issue(issue_id)
      |> order_by([w], desc: w.inserted_at)
      |> limit(1)
      |> Repo.one()

    result =
      case existing do
        nil ->
          cap = max_pending_wakes_per_agent()

          cond do
            recent_consumed_duplicate?(
              agent_id,
              issue_id,
              reason,
              attrs_fingerprint(triggered_by_type, triggered_by_id, metadata)
            ) ->
              Logger.debug(
                "WakeupQueue: suppressing recent duplicate wake for agent #{agent_id}, issue #{inspect(issue_id)}, reason #{reason}"
              )

              {:error, :recent_duplicate_wake}

            pending_count(agent_id) >= cap ->
              Logger.warning(
                "WakeupQueue: rejecting wake for agent #{agent_id}, queue full (cap=#{cap})"
              )

              {:error, :wakeup_queue_full}

            true ->
              %AgentWake{}
              |> AgentWake.changeset(%{
                agent_id: agent_id,
                issue_id: issue_id,
                reason: reason,
                status: "pending",
                triggered_by_type: triggered_by_type,
                triggered_by_id: triggered_by_id,
                metadata: metadata
              })
              |> Repo.insert()
          end

        wake ->
          Logger.debug("WakeupQueue: coalescing wake for agent #{agent_id}, issue #{issue_id}")

          wake
          |> AgentWake.changeset(%{
            triggered_by_type: triggered_by_type,
            triggered_by_id: triggered_by_id,
            metadata: merge_metadata(wake.metadata, metadata)
          })
          |> Repo.update()
      end

    case result do
      {:ok, wake} ->
        Phoenix.PubSub.broadcast(
          Cympho.PubSub,
          "wakeups:#{agent_id}",
          {:wakeup_enqueued, agent_id, wake}
        )

        {:ok, wake}

      other ->
        other
    end
  end

  @doc """
  Returns the PubSub topic on which `enqueue/1` broadcasts wake events for an agent.
  Subscribers receive `{:wakeup_enqueued, agent_id, %AgentWake{}}` on enqueue.
  """
  @spec topic_for_agent(String.t()) :: String.t()
  def topic_for_agent(agent_id), do: "wakeups:#{agent_id}"

  @doc """
  Dequeues the next wake event for a given agent.
  Returns the oldest pending wake for the agent, or nil.
  """
  @spec dequeue(String.t()) :: {:ok, AgentWake.t()} | {:error, :empty}
  def dequeue(agent_id) do
    wake =
      Repo.one(
        from w in AgentWake,
          where: w.agent_id == ^agent_id and w.status == "pending",
          order_by: [asc: w.inserted_at, asc: w.id],
          limit: 1
      )

    case wake do
      nil -> {:error, :empty}
      wake -> {:ok, wake}
    end
  end

  @doc """
  Returns the count of pending wakes for an agent.
  """
  @spec pending_count(String.t()) :: non_neg_integer()
  def pending_count(agent_id) do
    Repo.one(
      from w in AgentWake,
        where: w.agent_id == ^agent_id and w.status == "pending",
        select: count(w.id)
    )
  end

  @doc """
  Lists pending wakes for an agent, ordered by most recent first.
  """
  @spec list_pending(String.t(), keyword()) :: [AgentWake.t()]
  def list_pending(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    AgentWake
    |> where([w], w.agent_id == ^agent_id and w.status == "pending")
    |> order_by([w], desc: w.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Marks a wake as consumed after an agent has started processing it.
  """
  @spec mark_consumed(AgentWake.t()) :: {:ok, AgentWake.t()} | {:error, Ecto.Changeset.t()}
  def mark_consumed(%AgentWake{} = wake) do
    wake
    |> AgentWake.changeset(%{status: "consumed", consumed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc """
  Marks all pending wakes for an agent/issue pair as consumed.
  """
  @spec consume_for(String.t(), String.t()) :: :ok
  def consume_for(agent_id, issue_id) do
    now = DateTime.utc_now()

    AgentWake
    |> where([w], w.agent_id == ^agent_id and w.status == "pending")
    |> where_issue(issue_id)
    |> Repo.update_all(set: [status: "consumed", consumed_at: now])

    :ok
  end

  defp where_issue(query, nil), do: where(query, [w], is_nil(w.issue_id))
  defp where_issue(query, issue_id), do: where(query, [w], w.issue_id == ^issue_id)

  defp recent_consumed_duplicate?(agent_id, issue_id, reason, fingerprint) do
    seconds = recent_duplicate_window_seconds()

    if guarded_recent_duplicate_reason?(reason) and is_integer(seconds) and seconds > 0 do
      cutoff = DateTime.utc_now() |> DateTime.add(-seconds, :second)

      AgentWake
      |> where([w], w.agent_id == ^agent_id)
      |> where([w], w.reason == ^reason and w.status == "consumed")
      |> where([w], not is_nil(w.consumed_at) and w.consumed_at > ^cutoff)
      |> where_issue(issue_id)
      |> order_by([w], desc: w.consumed_at)
      |> limit(20)
      |> Repo.all()
      |> Enum.any?(&(wake_fingerprint(&1) == fingerprint))
    else
      false
    end
  end

  defp guarded_recent_duplicate_reason?(reason) do
    reason not in @recent_duplicate_exempt_reasons
  end

  defp wake_fingerprint(%AgentWake{} = wake) do
    attrs_fingerprint(
      wake.triggered_by_type || "system",
      wake.triggered_by_id,
      wake.metadata || %{}
    )
  end

  defp attrs_fingerprint(triggered_by_type, triggered_by_id, metadata) do
    {triggered_by_type || "system", triggered_by_id || "", metadata_fingerprint(metadata)}
  end

  defp metadata_fingerprint(metadata) when is_map(metadata) do
    metadata
    |> first_present([
      :dedupe_key,
      "dedupe_key",
      :comment_id,
      "comment_id",
      :review_id,
      "review_id"
    ])
    |> case do
      nil when map_size(metadata) == 0 ->
        :empty

      nil ->
        {:metadata_hash, :erlang.phash2(normalize_metadata(metadata))}

      value ->
        {:key, to_string(value)}
    end
  end

  defp metadata_fingerprint(_metadata), do: :empty

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} when not is_nil(value) -> value
        _ -> nil
      end
    end)
  end

  defp normalize_metadata(value) when is_map(value) do
    value
    |> Enum.map(fn {key, value} -> {to_string(key), normalize_metadata(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp normalize_metadata(value) when is_list(value), do: Enum.map(value, &normalize_metadata/1)
  defp normalize_metadata(value), do: value

  defp attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, to_string(key), default))
  end

  defp merge_metadata(existing, new) do
    existing = existing || %{}
    new = new || %{}

    existing
    |> Map.merge(new)
    |> put_coalesced_count(existing)
    |> put_coalesced_ids(existing, new, "comment_id", "coalesced_comment_ids")
    |> put_coalesced_ids(existing, new, "review_id", "coalesced_review_ids")
  end

  defp put_coalesced_count(merged, existing) do
    count = metadata_integer(existing, "coalesced_count", 1) + 1
    Map.put(merged, "coalesced_count", count)
  end

  defp put_coalesced_ids(merged, existing, new, key, aggregate_key) do
    ids =
      []
      |> append_metadata_values(existing, aggregate_key)
      |> append_metadata_values(existing, key)
      |> append_metadata_values(new, aggregate_key)
      |> append_metadata_values(new, key)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.take(-20)

    if ids == [] do
      merged
    else
      Map.put(merged, aggregate_key, ids)
    end
  end

  defp append_metadata_values(values, metadata, key) do
    case Map.get(metadata, key) || Map.get(metadata, String.to_atom(key)) do
      nil -> values
      value when is_list(value) -> values ++ value
      value -> values ++ [value]
    end
  end

  defp metadata_integer(metadata, key, default) do
    case Map.get(metadata, key) || Map.get(metadata, String.to_atom(key)) do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> parse_positive_integer(value, default)
      _ -> default
    end
  end

  defp parse_positive_integer(value, default) do
    case Integer.parse(value) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> default
    end
  end
end
