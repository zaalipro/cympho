defmodule Cympho.RateLimiting.BroadcastDedup do
  @moduledoc false

  use GenServer

  @dedup_window_ms 500
  @cleanup_interval_ms 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def should_broadcast?(topic, event, payload) do
    key = {topic, event, payload_digest(payload)}
    GenServer.call(__MODULE__, {:check_and_mark, key})
  end

  def should_broadcast_pubsub?(topic, message) do
    key = {:pubsub, topic, payload_digest(message)}
    GenServer.call(__MODULE__, {:check_and_mark, key})
  end

  @doc false
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  defp payload_digest(payload) do
    :crypto.hash(:sha256, :erlang.term_to_binary(payload))
  end

  @impl true
  def init(_) do
    table = :ets.new(__MODULE__, [:set, :named_table])
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:check_and_mark, key}, _from, state) do
    now = System.monotonic_time(:millisecond)
    expires_at = now + @dedup_window_ms

    result =
      case :ets.lookup(state.table, key) do
        [{^key, existing_expires}] when existing_expires > now ->
          false

        _ ->
          :ets.insert(state.table, {key, expires_at})
          true
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn
        {key, expires_at}, acc when expires_at <= now ->
          :ets.delete(state.table, key)
          acc

        _, acc ->
          acc
      end,
      :ok,
      state.table
    )

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
