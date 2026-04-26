defmodule Cympho.EventStore do
  @moduledoc """
  ETS-based event store that buffers recent scoped-topic events for replay.
  """
  use GenServer

  @table :cympho_event_store
  @max_per_topic 200
  @default_limit 100

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
  def fetch_since(topic, nil, limit), do: GenServer.call(__MODULE__, {:fetch_latest, topic, limit})
  def fetch_since(topic, last_event_id, limit), do: GenServer.call(__MODULE__, {:fetch_since, topic, last_event_id, limit})

  def count(topic), do: length(:ets.match_object(@table, {:_, topic, :_, :_}))

  def purge_old(ttl_ms \\ 300_000), do: GenServer.call(__MODULE__, {:purge_old, ttl_ms})

  @impl true
  def init(opts) do
    table = :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
    max_per_topic = Keyword.get(opts, :max_events_per_topic, @max_per_topic)
    Process.send_after(self(), :purge_tick, 60_000)
    {:ok, %{table: table, min_ids: %{}, max_per_topic: max_per_topic}}
  end

  @impl true
  def handle_call({:append, topic, payload}, _from, state) do
    event_id = :ets.update_counter(@table, :__global_counter__, {2, 1}, {:__global_counter__, 0})
    timestamp = System.system_time(:millisecond)
    :ets.insert(@table, {event_id, topic, payload, timestamp})
    min_id = case Map.get(state.min_ids, topic) do
      nil -> event_id
      existing when event_id < existing -> event_id
      existing -> existing
    end
    state = %{state | min_ids: Map.put(state.min_ids, topic, min_id)}
    state = trim_if_needed(state, topic)
    {:reply, event_id, state}
  end

  @impl true
  def handle_call({:fetch_since, topic, last_event_id, limit}, _from, state) do
    case Map.get(state.min_ids, topic) do
      nil -> {:reply, {:ok, []}, state}
      min_id when last_event_id < min_id -> {:reply, {:error, :replay_window_expired}, state}
      _ -> {:reply, {:ok, do_fetch_since(topic, last_event_id, limit)}, state}
    end
  end

  @impl true
  def handle_call({:fetch_latest, topic, limit}, _from, state) do
    events = :ets.match_object(@table, {:_, topic, :_, :_})
    |> Enum.sort_by(&elem(&1, 0), :desc) |> Enum.take(limit) |> Enum.reverse() |> Enum.map(&to_map/1)
    {:reply, {:ok, events}, state}
  end

  @impl true
  def handle_call({:purge_old, ttl_ms}, _from, state) do
    cutoff = System.system_time(:millisecond) - ttl_ms
    deleted = :ets.foldl(fn
      {:__global_counter__, _}, acc -> acc
      {event_id, _, _, timestamp}, acc ->
        if timestamp < cutoff, do: (:ets.delete(@table, event_id); acc + 1), else: acc
    end, 0, @table)
    {:reply, deleted, state}
  end

  @impl true
  def handle_info(:purge_tick, state) do
    purge_old(300_000)
    Process.send_after(self(), :purge_tick, 60_000)
    {:noreply, state}
  end

  defp trim_if_needed(state, topic) do
    topic_count = count(topic)
    if topic_count > state.max_per_topic do
      trim_count = topic_count - state.max_per_topic
      to_delete = :ets.match_object(@table, {:_, topic, :_, :_})
      |> Enum.sort_by(&elem(&1, 0)) |> Enum.take(trim_count)
      Enum.each(to_delete, fn {id, _, _, _} -> :ets.delete(@table, id) end)
      new_min = case :ets.match_object(@table, {:_, topic, :_, :_}) |> Enum.sort_by(&elem(&1, 0)) do
        [{id, _, _, _} | _] -> id
        [] -> nil
      end
      %{state | min_ids: Map.put(state.min_ids, topic, new_min)}
    else
      state
    end
  end

  defp do_fetch_since(topic, last_event_id, limit) do
    :ets.match_object(@table, {:_, topic, :_, :_})
    |> Enum.filter(fn {id, _, _, _} -> id > last_event_id end)
    |> Enum.sort_by(&elem(&1, 0)) |> Enum.take(limit) |> Enum.map(&to_map/1)
  end

  defp to_map({event_id, topic, payload, timestamp}) do
    %{event_id: event_id, topic: topic, payload: payload, timestamp: timestamp}
  end
end
