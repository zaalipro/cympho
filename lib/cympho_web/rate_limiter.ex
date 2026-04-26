defmodule CymphoWeb.RateLimiter do
  @moduledoc """
  Per-socket and per-IP rate limiting for WebSocket channels.

  Uses ETS-based sliding window counters. Enforces:
  - Max 10 events/sec per socket for push operations
  - Max 1 heartbeat/sec per socket
  - Max 10 joins/sec per IP address
  """

  use GenServer

  @table :cympho_rate_limiter
  @max_events_per_sec 10
  @max_joins_per_sec 10
  @max_heartbeats_per_sec 1
  @cleanup_interval 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a socket can push an event.
  """
  @spec check_push(String.t()) :: :ok | {:error, :rate_limited}
  def check_push(socket_id) do
    GenServer.call(__MODULE__, {:check_rate, socket_id, :push, @max_events_per_sec})
  end

  @doc """
  Checks if a client can send a heartbeat.
  """
  @spec check_heartbeat(String.t()) :: :ok | {:error, :rate_limited}
  def check_heartbeat(socket_id) do
    GenServer.call(__MODULE__, {:check_rate, socket_id, :heartbeat, @max_heartbeats_per_sec})
  end

  @doc """
  Checks if an IP can join.
  """
  @spec check_join(String.t()) :: :ok | {:error, :rate_limited}
  def check_join(ip) do
    GenServer.call(__MODULE__, {:check_rate, "join:#{ip}", :join, @max_joins_per_sec})
  end

  @doc """
  Cleans up a socket's rate limit entries on disconnect.
  """
  @spec cleanup_socket(String.t()) :: :ok
  def cleanup_socket(socket_id) do
    GenServer.cast(__MODULE__, {:cleanup_socket, socket_id})
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:check_rate, key, kind, max_per_sec}, _from, state) do
    now = System.system_time(:millisecond)

    :ets.insert(@table, {{key, kind, now}, true})

    count = length(:ets.match_object(@table, {{key, kind, :_}, :_}))

    result =
      if count <= max_per_sec do
        :ok
      else
        {:error, :rate_limited}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:cleanup_socket, socket_id}, state) do
    :ets.match_delete(@table, {{{socket_id, :_, :_}, :_}})
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = System.system_time(:millisecond) - 2000

    :ets.foldl(
      fn {{_key, _kind, ts}, _} = entry, _acc ->
        if ts < cutoff do
          :ets.delete_object(@table, entry)
        end
      end,
      :ok,
      @table
    )

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
