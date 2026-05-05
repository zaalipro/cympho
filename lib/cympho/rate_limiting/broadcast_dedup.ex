defmodule Cympho.RateLimiting.BroadcastDedup do
  @moduledoc false

  use GenServer

  @dedup_window_ms 500
  @cleanup_interval_ms 5_000
  # Hard cap on dedup-table rows; under sustained broadcast flood we'd
  # otherwise grow unbounded between cleanup ticks. When we hit this we run
  # an inline cleanup (cheap kernel-level select_delete) before inserting.
  @max_table_size 50_000

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

    if :ets.info(state.table, :size) >= @max_table_size do
      sweep_expired(state.table, now)
    end

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
    sweep_expired(state.table, System.monotonic_time(:millisecond))
    schedule_cleanup()
    {:noreply, state}
  end

  # Single kernel-level pass; deletes every row whose `expires_at` has
  # passed without copying the table or scheduling per-row deletes.
  defp sweep_expired(table, now) do
    match_spec = [{{:_, :"$1"}, [{:"=<", :"$1", now}], [true]}]
    :ets.select_delete(table, match_spec)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
