defmodule Cympho.Companies.ImportTransferSweeper do
  @moduledoc "Fail-open recovery and expiry worker for company import transfers."

  use GenServer

  require Logger

  alias Cympho.Companies.ImportTransfers

  @default_interval_ms 60 * 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      transfer_opts: Keyword.take(opts, [:spool_root, :max_age_ms])
    }

    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    safely("recover stranded company import transfers", &ImportTransfers.recover_stranded/0)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    # A request process can die immediately after committing an apply claim.
    # The lease may still be live at VM startup, so startup-only recovery would
    # strand that row forever unless the user happened to retry it. Recheck
    # expired claims on every maintenance pass before ordinary expiry cleanup.
    safely("recover expired company import apply claims", &ImportTransfers.recover_stranded/0)

    safely("sweep abandoned company import transfers", fn ->
      ImportTransfers.sweep(state.transfer_opts)
    end)

    schedule(state.interval_ms)
    {:noreply, state}
  end

  defp safely(operation, fun) do
    fun.()
  rescue
    _exception ->
      Logger.warning("Failed to #{operation}")
      :error
  catch
    _kind, _reason ->
      Logger.warning("Failed to #{operation}")
      :error
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :sweep, interval_ms)
end
