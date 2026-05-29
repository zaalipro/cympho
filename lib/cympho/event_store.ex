defmodule Cympho.EventStore do
  @moduledoc """
  ETS-backed event store that buffers recent scoped-topic events for replay.

  Maintains an in-memory index `topic => [event_id]` (newest-first) so all
  per-topic operations are O(per_topic) rather than O(total). The actual
  event payloads live in an ETS `:set` table keyed by `event_id`.

  Supports:
    - bounded retention per topic (`@max_per_topic`)
    - global TTL eviction via periodic `:purge_tick`
    - replay from a `last_event_id` watermark for WebSocket reconnects
  """
  use GenServer

  @table :cympho_event_store
  @max_per_topic 200
  @default_limit 100
  @ttl_ms 300_000
  @purge_interval_ms 60_000
  # Cap per purge tick so a topic-heavy install can't block the GenServer.
  # Topics not touched this tick get processed next tick (60s later).
  @max_topics_per_purge_tick 200

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def append(topic, payload) do
    GenServer.call(__MODULE__, {:append, topic, payload})
  end

  def fetch_since(topic, last_event_id, limit \\ @default_limit)

  def fetch_since(topic, nil, limit),
    do: GenServer.call(__MODULE__, {:fetch_latest, topic, limit})

  def fetch_since(topic, last_event_id, limit),
    do: GenServer.call(__MODULE__, {:fetch_since, topic, last_event_id, limit})

  def count(topic), do: GenServer.call(__MODULE__, {:count, topic})

  def purge_old(ttl_ms \\ @ttl_ms), do: GenServer.call(__MODULE__, {:purge_old, ttl_ms})

  @doc """
  Drops every topic whose name starts with `prefix` and deletes the backing
  ETS rows. Called on company deletion so stale `company:{id}:*` topics don't
  linger in `topic_events` forever (they're bounded per-topic but the topic
  set itself is unbounded).
  """
  @spec purge_topics_with_prefix(String.t()) :: non_neg_integer()
  def purge_topics_with_prefix(prefix) when is_binary(prefix) do
    GenServer.call(__MODULE__, {:purge_prefix, prefix})
  end

  @impl true
  def init(opts) do
    table =
      case :ets.info(@table) do
        :undefined -> :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
        _ -> @table
      end

    max_per_topic = Keyword.get(opts, :max_events_per_topic, @max_per_topic)
    Process.send_after(self(), :purge_tick, @purge_interval_ms)

    {:ok,
     %{
       table: table,
       # Seed from wall-clock so event ids stay monotonic across a GenServer
       # restart. The ETS table is owned by this process, so a crash deletes it
       # and init recreates it empty; a plain 0-based counter would then reuse
       # ids that reconnecting clients still hold as their replay watermark,
       # silently dropping (or mis-serving) events. Wall-clock ms only ever
       # advances, so post-restart ids never collide with pre-restart ones.
       counter: System.system_time(:millisecond),
       # topic => [event_id] newest-first
       topic_events: %{},
       max_per_topic: max_per_topic,
       # cursor for incremental purge — last topic name visited last tick.
       purge_cursor: nil
     }}
  end

  @impl true
  def handle_call({:append, topic, payload}, _from, state) do
    event_id = state.counter + 1
    timestamp = System.system_time(:millisecond)
    :ets.insert(@table, {event_id, topic, payload, timestamp})

    ids = [event_id | Map.get(state.topic_events, topic, [])]
    {kept, evicted} = trim_topic(ids, state.max_per_topic)
    Enum.each(evicted, &:ets.delete(@table, &1))

    {:reply, event_id,
     %{state | counter: event_id, topic_events: Map.put(state.topic_events, topic, kept)}}
  end

  @impl true
  def handle_call({:fetch_latest, topic, limit}, _from, state) do
    events =
      state.topic_events
      |> Map.get(topic, [])
      |> Enum.take(limit)
      |> Enum.reverse()
      |> lookup_events()

    {:reply, {:ok, events}, state}
  end

  @impl true
  def handle_call({:fetch_since, topic, last_event_id, limit}, _from, state) do
    case Map.get(state.topic_events, topic) do
      nil ->
        {:reply, {:ok, []}, state}

      ids ->
        min_id = List.last(ids) || 0

        if last_event_id < min_id do
          {:reply, {:error, :replay_window_expired}, state}
        else
          events =
            ids
            |> Enum.reverse()
            |> Enum.drop_while(&(&1 <= last_event_id))
            |> Enum.take(limit)
            |> lookup_events()

          {:reply, {:ok, events}, state}
        end
    end
  end

  @impl true
  def handle_call({:count, topic}, _from, state) do
    {:reply, length(Map.get(state.topic_events, topic, [])), state}
  end

  @impl true
  def handle_call({:purge_old, ttl_ms}, _from, state) do
    {deleted, state} = do_purge_old(ttl_ms, state)
    {:reply, deleted, state}
  end

  @impl true
  def handle_call({:purge_prefix, prefix}, _from, state) do
    {matching, remaining} =
      Enum.split_with(state.topic_events, fn {topic, _ids} ->
        is_binary(topic) and String.starts_with?(topic, prefix)
      end)

    deleted =
      Enum.reduce(matching, 0, fn {_topic, ids}, count ->
        Enum.each(ids, &:ets.delete(@table, &1))
        count + length(ids)
      end)

    new_state = %{state | topic_events: Map.new(remaining)}
    {:reply, deleted, new_state}
  end

  @impl true
  def handle_info(:purge_tick, state) do
    {_deleted, state} = do_purge_old(@ttl_ms, state)
    Process.send_after(self(), :purge_tick, @purge_interval_ms)
    {:noreply, state}
  end

  defp trim_topic(ids, max) when length(ids) <= max, do: {ids, []}

  defp trim_topic(ids, max) do
    {kept, evicted} = Enum.split(ids, max)
    {kept, evicted}
  end

  defp do_purge_old(ttl_ms, state) do
    cutoff = System.system_time(:millisecond) - ttl_ms

    # Sort topics deterministically and skip ahead to the cursor so we resume
    # from where we left off last tick. Process at most
    # @max_topics_per_purge_tick topics; the rest wait for the next tick.
    sorted_topics = state.topic_events |> Map.keys() |> Enum.sort()

    {topics_to_visit, next_cursor} =
      pick_topic_window(sorted_topics, state.purge_cursor, @max_topics_per_purge_tick)

    {processed_events, deleted} =
      Enum.reduce(topics_to_visit, {%{}, 0}, fn topic, {acc, count} ->
        ids = Map.get(state.topic_events, topic, [])
        {kept, evicted} = drop_old_ids(ids, cutoff)
        Enum.each(evicted, &:ets.delete(@table, &1))

        new_acc = if kept == [], do: acc, else: Map.put(acc, topic, kept)
        {new_acc, count + length(evicted)}
      end)

    # Topics not visited this tick: keep their existing ids unchanged. Visited
    # topics: replace with the trimmed list (or drop if empty).
    untouched =
      state.topic_events
      |> Map.drop(topics_to_visit)

    new_topic_events = Map.merge(untouched, processed_events)

    {deleted, %{state | topic_events: new_topic_events, purge_cursor: next_cursor}}
  end

  # Returns {topics_to_visit, next_cursor}.
  # If cursor is nil or not present, start from the head; otherwise pick up
  # after it. Wrap to the head when we hit the end.
  defp pick_topic_window([], _cursor, _max), do: {[], nil}

  defp pick_topic_window(topics, cursor, max) do
    rest =
      case cursor do
        nil -> topics
        c -> Enum.drop_while(topics, &(&1 <= c))
      end

    rest = if rest == [], do: topics, else: rest
    window = Enum.take(rest, max)
    next = if window == [], do: nil, else: List.last(window)
    {window, next}
  end

  # ids are newest-first; we drop the tail entries (oldest) whose timestamps
  # are older than the cutoff. Walk from the end.
  defp drop_old_ids(ids, cutoff) do
    {kept_rev, evicted} =
      ids
      |> Enum.reverse()
      |> Enum.reduce({[], []}, fn id, {kept, evicted} ->
        case :ets.lookup(@table, id) do
          [{^id, _topic, _payload, ts}] when ts >= cutoff -> {[id | kept], evicted}
          [{^id, _topic, _payload, _ts}] -> {kept, [id | evicted]}
          [] -> {kept, evicted}
        end
      end)

    {Enum.reverse(kept_rev), evicted}
  end

  defp lookup_events(ids) do
    Enum.reduce(ids, [], fn id, acc ->
      case :ets.lookup(@table, id) do
        [{^id, topic, payload, ts}] ->
          [%{event_id: id, topic: topic, payload: payload, timestamp: ts} | acc]

        [] ->
          acc
      end
    end)
    |> Enum.reverse()
  end
end
