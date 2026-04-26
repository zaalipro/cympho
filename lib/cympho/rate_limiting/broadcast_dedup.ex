defmodule Cympho.RateLimiting.BroadcastDedup do
  @moduledoc false

  use GenServer

  @dedup_window_ms 500
  @cleanup_interval_ms 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def should_broadcast?(topic, event, payload) do
    key = {topic, event, :erlang.phash2(payload)}
    check_and_mark(key)
  end

  def should_broadcast_pubsub?(topic, message) do
    key = {:pubsub, topic, :erlang.phash2(message)}
    check_and_mark(key)
  end

  defp check_and_mark(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(__MODULE__, key) do
      [{^key, expires_at}] when expires_at > now ->
        false

      _ ->
        :ets.insert(__MODULE__, {key, now + @dedup_window_ms})
        true
    end
  end

  @impl true
  def init(_) do
    table = :ets.new(__MODULE__, [:set, :named_table, :public, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn
        {key, expires_at}, acc when expires_at <= now ->
          :ets.delete(__MODULE__, key)
          acc

        _, acc ->
          acc
      end,
      :ok,
      __MODULE__
    )

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
