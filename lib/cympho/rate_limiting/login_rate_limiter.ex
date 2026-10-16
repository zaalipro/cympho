defmodule Cympho.RateLimiting.LoginRateLimiter do
  @moduledoc """
  Counts failed sign-in attempts per client address in a fixed window.

  `check/1` reserves an attempt atomically before any password hashing runs,
  so concurrent requests cannot all slip past the limit while their Argon2
  checks are still in flight. A successful sign-in hands its reservation back
  with `record_success/1`, so only failures count. Once an address reaches the
  limit, further attempts are refused until the window expires.

  IPv4-mapped IPv6 addresses are counted as their IPv4 address. Other IPv6
  clients are grouped by their /64 prefix, since a single host usually
  controls the whole prefix.
  """

  use GenServer

  import Bitwise

  @max_failures 10
  @window_ms 5 * 60 * 1_000
  @cleanup_interval_ms 60_000
  @hard_cap 10_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Reserves one sign-in attempt for the address.

  Returns `:ok`, or `{:error, :rate_limited}` once the address has used up its
  attempts for the current window. A reserved attempt counts as a failure
  unless it is released with `record_success/1`.
  """
  def check(ip), do: GenServer.call(__MODULE__, {:check, key(ip)})

  @doc "Releases the attempt reserved by `check/1` after a successful sign-in."
  def record_success(ip), do: GenServer.call(__MODULE__, {:record_success, key(ip)})

  @doc false
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_) do
    schedule_cleanup()
    {:ok, %{entries: %{}}}
  end

  @impl true
  def handle_call({:check, key}, _from, %{entries: entries} = state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(entries, key) do
      {count, window_start} when now - window_start < @window_ms and count >= @max_failures ->
        {:reply, {:error, :rate_limited}, state}

      {count, window_start} when now - window_start < @window_ms ->
        {:reply, :ok, %{state | entries: Map.put(entries, key, {count + 1, window_start})}}

      _ ->
        entries =
          if map_size(entries) >= @hard_cap, do: drop_stale(entries, now), else: entries

        {:reply, :ok, %{state | entries: Map.put(entries, key, {1, now})}}
    end
  end

  def handle_call({:record_success, key}, _from, %{entries: entries} = state) do
    entries =
      case Map.get(entries, key) do
        {count, window_start} when count > 1 -> Map.put(entries, key, {count - 1, window_start})
        {_count, _window_start} -> Map.delete(entries, key)
        nil -> entries
      end

    {:reply, :ok, %{state | entries: entries}}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | entries: %{}}}
  end

  @impl true
  def handle_info(:cleanup, %{entries: entries} = state) do
    cleaned = drop_stale(entries, System.monotonic_time(:millisecond))
    schedule_cleanup()
    {:noreply, %{state | entries: cleaned}}
  end

  defp key({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp key({a, b, c, d, _, _, _, _}), do: {:ipv6_64, a, b, c, d}
  defp key(ip), do: ip

  defp drop_stale(entries, now) do
    threshold = now - @window_ms

    entries
    |> Enum.reject(fn {_key, {_count, window_start}} -> window_start < threshold end)
    |> Map.new()
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
