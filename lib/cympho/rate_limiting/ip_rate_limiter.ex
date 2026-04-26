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
    GenServer.call(__MODULE__, {:check_join, ip})
  end

  @doc false
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(_) do
    schedule_cleanup()
    {:ok, %{entries: %{}}}
  end

  @impl true
  def handle_call({:check_join, ip}, _from, %{entries: entries} = state) do
    now = System.monotonic_time(:millisecond)

    {result, entries} =
      case Map.get(entries, ip) do
        {count, window_start} when now - window_start < @window_ms ->
          if count < @max_joins_per_second do
            {:ok, Map.put(entries, ip, {count + 1, window_start})}
          else
            {{:error, :rate_limited}, entries}
          end

        _ ->
          {:ok, Map.put(entries, ip, {1, now})}
      end

    {:reply, result, %{state | entries: entries}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | entries: %{}}}
  end

  @impl true
  def handle_info(:cleanup, %{entries: entries} = state) do
    threshold = System.monotonic_time(:millisecond) - @window_ms

    cleaned =
      entries
      |> Enum.reject(fn {_ip, {_count, window_start}} -> window_start < threshold end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, %{state | entries: cleaned}}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
