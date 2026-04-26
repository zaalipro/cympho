defmodule Cympho.RateLimiting.IpRateLimiter do
  @moduledoc false

  use GenServer

  @max_joins_per_second 10
  @window_ms 1_000
  @cleanup_interval_ms 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def check_join(ip) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(__MODULE__, ip) do
      [{^ip, count, window_start}] when now - window_start < @window_ms ->
        if count < @max_joins_per_second do
          :ets.insert(__MODULE__, {ip, count + 1, window_start})
          :ok
        else
          {:error, :rate_limited}
        end

      _ ->
        :ets.insert(__MODULE__, {ip, 1, now})
        :ok
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
    threshold = now - @window_ms

    :ets.foldl(
      fn
        {ip, _count, window_start}, acc when window_start < threshold ->
          :ets.delete(__MODULE__, ip)
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
