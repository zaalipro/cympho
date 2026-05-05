defmodule Cympho.RateLimiting.AgentActionLimiter do
  @moduledoc """
  Per-agent rate limiter for `Cympho.AgentActions.execute/3`.

  Caps how many action *batches* a single agent may execute per minute. A
  buggy or runaway agent can otherwise trigger unbounded `create_issue` /
  `comment` storms. The check is fixed-window (1 minute) implemented with
  `:ets.update_counter/4`, so it's lock-free and amortizes O(1).

  GenServer exists only to own the table and run cleanup; reads/writes go
  directly against the public ETS table.
  """

  use GenServer

  @table __MODULE__
  @window_seconds 60
  @cleanup_interval_ms 30_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Records one action for `agent_id` and returns `:ok` if under the cap, or
  `{:error, :rate_limited}` if the agent is over budget for the current
  60s window.

  `agent_id` of `nil` is treated as `:ok` (system actions, tests).
  """
  @spec check(String.t() | nil) :: :ok | {:error, :rate_limited}
  def check(nil), do: :ok

  def check(agent_id) when is_binary(agent_id) do
    bucket = current_bucket()
    key = {agent_id, bucket}
    new_count = :ets.update_counter(@table, key, 1, {key, 0})

    if new_count > max_per_minute() do
      {:error, :rate_limited}
    else
      :ok
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
    bucket = current_bucket()
    # Drop every row whose bucket is older than the current one. New writes
    # land in the current (or next) bucket, so this is safe under
    # concurrent traffic.
    match_spec = [{{{:_, :"$1"}, :_}, [{:<, :"$1", bucket}], [true]}]
    :ets.select_delete(@table, match_spec)
    schedule_cleanup()
    {:noreply, state}
  end

  defp current_bucket, do: div(System.system_time(:second), @window_seconds)

  defp max_per_minute do
    Application.get_env(:cympho, :agent_actions, [])
    |> Keyword.get(:max_per_minute, 60)
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)
end
