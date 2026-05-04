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
       counter: 0,
       # topic => [event_id] newest-first
       topic_events: %{},
       max_per_topic: max_per_topic
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

    {topic_events, deleted} =
      Enum.reduce(state.topic_events, {%{}, 0}, fn {topic, ids}, {acc, count} ->
        {kept, evicted} = drop_old_ids(ids, cutoff)
        Enum.each(evicted, &:ets.delete(@table, &1))

        new_acc =
          if kept == [] do
            acc
          else
            Map.put(acc, topic, kept)
          end

        {new_acc, count + length(evicted)}
      end)

    {deleted, %{state | topic_events: topic_events}}
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
