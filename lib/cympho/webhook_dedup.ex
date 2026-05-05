defmodule Cympho.WebhookDedup do
  @moduledoc """
  Idempotency cache for inbound webhooks (currently GitHub `X-GitHub-Delivery`).

  GitHub re-delivers webhooks on receiver errors and timeouts. Without
  deduplication, every retry would re-execute side effects (state transitions,
  comment creation). We track each delivery id in a public ETS table with a
  24h TTL — long enough to cover GitHub's retry window, short enough that the
  table stays small.

  Reads are lock-free (`:ets.lookup` against a public table). The GenServer
  exists only to own the table and run periodic eviction.
  """

  use GenServer

  @table __MODULE__
  @ttl_ms :timer.hours(24)
  @cleanup_interval_ms :timer.minutes(15)
  @max_table_size 50_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Atomically marks `delivery_id` as seen. Returns `:fresh` the first time and
  `:duplicate` on subsequent calls within the TTL window.

  `nil` or empty ids are treated as `:fresh` (no dedup possible without an id).
  """
  @spec check_and_mark(String.t() | nil) :: :fresh | :duplicate
  def check_and_mark(nil), do: :fresh
  def check_and_mark(""), do: :fresh

  def check_and_mark(delivery_id) when is_binary(delivery_id) do
    now = System.monotonic_time(:millisecond)
    expires_at = now + @ttl_ms

    # `insert_new` is atomic, so concurrent identical webhooks resolve to one
    # winner without GenServer involvement.
    case :ets.insert_new(@table, {delivery_id, expires_at}) do
      true ->
        :fresh

      false ->
        case :ets.lookup(@table, delivery_id) do
          [{^delivery_id, existing_expires}] when existing_expires > now ->
            :duplicate

          # Stale entry not yet swept; overwrite it and treat as fresh.
          _ ->
            :ets.insert(@table, {delivery_id, expires_at})
            :fresh
        end
    end
  end

  @doc false
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_) do
    :ets.new(@table, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    sweep_expired(System.monotonic_time(:millisecond))
    enforce_size_cap()
    schedule_cleanup()
    {:noreply, state}
  end

  defp sweep_expired(now) do
    match_spec = [{{:_, :"$1"}, [{:"=<", :"$1", now}], [true]}]
    :ets.select_delete(@table, match_spec)
  end

  defp enforce_size_cap do
    if :ets.info(@table, :size) > @max_table_size do
      # Aggressive cap: drop everything if we somehow exceed the bound.
      # This prefers losing dedup state over unbounded growth.
      :ets.delete_all_objects(@table)
    end
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)
end
