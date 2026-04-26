defmodule Cympho.EventStore do
  @moduledoc """
  ETS-based event store that buffers recent scoped-topic events for replay.

  Stores the last 200 events per topic in a circular buffer pattern.
  Reconnecting clients can replay missed messages by providing their last
  seen event_id.
  """

  use GenServer

  @table :cympho_event_store
  @max_per_topic 200
  @default_limit 100

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Appends an event to the store for the given topic.
  Returns the assigned event_id (monotonic integer).
  """
  @spec append(String.t(), map()) :: integer()
  def append(topic, payload) do
    GenServer.call(__MODULE__, {:append, topic, payload})
  end

  @doc """
  Fetches events for a topic since the given event_id.
  Returns `{:ok, events}` or `{:error, :replay_window_expired}`.
  """
  @spec fetch_since(String.t(), integer() | nil, integer()) ::
          {:ok, [map()]} | {:error, :replay_window_expired}
  def fetch_since(topic, last_event_id, limit \\ @default_limit)

  def fetch_since(topic, nil, limit) do
    GenServer.call(__MODULE__, {:fetch_latest, topic, limit})
  end

  def fetch_since(topic, last_event_id, limit) do
    GenServer.call(__MODULE__, {:fetch_since, topic, last_event_id, limit})
  end

  @doc """
  Returns the current event count for a topic.
  """
  @spec count(String.t()) :: integer()
  def count(topic) do
    :ets.match_count(@table, {:_, topic, :_, :_, :_})
  end

  @doc """
  Purges events older than the given ttl_ms for all topics.
  """
  @spec purge_old(integer()) :: integer()
  def purge_old(ttl_ms \\ 300_000) do
    GenServer.call(__MODULE__, {:purge_old, ttl_ms})
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])

    schedule_purge()

    {:ok, %{table: table, counters: %{}, min_ids: %{}}}
  end

  @impl true
  def handle_call({:append, topic, payload}, _from, state) do
    event_id = next_event_id(topic, state)
    timestamp = System.system_time(:millisecond)

    :ets.insert(@table, {event_id, topic, payload, timestamp})

    state = track_topic_bounds(state, topic, event_id)
    state = maybe_trim_topic(state, topic)

    {:reply, event_id, state}
  end

  @impl true
  def handle_call({:fetch_since, topic, last_event_id, limit}, _from, state) do
    case get_min_id(topic, state) do
      nil ->
        {:reply, {:ok, []}, state}

      min_id when last_event_id < min_id ->
        {:reply, {:error, :replay_window_expired}, state}

      _ ->
        events = do_fetch_since(topic, last_event_id, limit)
        {:reply, {:ok, events}, state}
    end
  end

  @impl true
  def handle_call({:fetch_latest, topic, limit}, _from, state) do
    events =
      :ets.match_object(@table, {:_, topic, :_, :_})
      |> Enum.sort_by(fn {id, _, _, _} -> id end, :desc)
      |> Enum.take(limit)
      |> Enum.reverse()
      |> Enum.map(&event_to_map/1)

    {:reply, {:ok, events}, state}
  end

  @impl true
  def handle_call({:purge_old, ttl_ms}, _from, state) do
    cutoff = System.system_time(:millisecond) - ttl_ms

    deleted =
      :ets.foldl(
        fn {event_id, _topic, _payload, timestamp}, acc ->
          if timestamp < cutoff do
            :ets.delete(@table, event_id)
            acc + 1
          else
            acc
          end
        end,
        0,
        @table
      )

    {:reply, deleted, state}
  end

  @impl true
  def handle_info(:purge_tick, state) do
    purge_old(300_000)
    schedule_purge()
    {:noreply, state}
  end

  defp next_event_id(topic, state) do
    counter = Map.get(state.counters, topic, 0)
    global_counter = :ets.update_counter(@table, :__global_counter__, {2, 1}, {:__global_counter__, 0})
    global_counter
  end

  defp track_topic_bounds(state, topic, event_id) do
    min_id = Map.get(state.min_ids, topic)

    min_id =
      if is_nil(min_id) or event_id < min_id do
        event_id
      else
        min_id
      end

    %{state | min_ids: Map.put(state.min_ids, topic, min_id)}
  end

  defp maybe_trim_topic(state, topic) do
    count = :ets.match_count(@table, {:_, topic, :_, :_, :_})

    if count > @max_per_topic do
      trim_count = count - @max_per_topic

      :ets.match_object(@table, {:_, topic, :_, :_, :_})
      |> Enum.sort_by(fn {id, _, _, _} -> id end)
      |> Enum.take(trim_count)
      |> Enum.each(fn {id, _, _, _} -> :ets.delete(@table, id) end)

      remaining =
        :ets.match_object(@table, {:_, topic, :_, :_, :_})
        |> Enum.sort_by(fn {id, _, _, _} -> id end)

      new_min =
        case List.first(remaining) do
          nil -> nil
          {id, _, _, _} -> id
        end

      %{state | min_ids: Map.put(state.min_ids, topic, new_min)}
    else
      state
    end
  end

  defp do_fetch_since(topic, last_event_id, limit) do
    :ets.match_object(@table, {:_, topic, :_, :_})
    |> Enum.filter(fn {id, _, _, _} -> id > last_event_id end)
    |> Enum.sort_by(fn {id, _, _, _} -> id end)
    |> Enum.take(limit)
    |> Enum.map(&event_to_map/1)
  end

  defp get_min_id(topic, state) do
    Map.get(state.min_ids, topic)
  end

  defp event_to_map({event_id, topic, payload, timestamp}) do
    %{
      event_id: event_id,
      topic: topic,
      payload: payload,
      timestamp: timestamp
    }
  end

  defp schedule_purge do
    Process.send_after(self(), :purge_tick, 60_000)
  end
end
