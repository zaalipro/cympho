defmodule Cympho.AdapterSessions do
  @moduledoc """
  Tracks live adapter worker processes by session id.

  Orchestrators only know the adapter-level session id returned by
  `Adapter.run/4`. This registry gives operator stop paths a small, shared
  way to ask the worker that owns the runtime port to shut down.
  """

  use GenServer

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  def register(session_id, pid) when is_pid(pid) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _server -> GenServer.cast(__MODULE__, {:register, session_id, pid})
    end
  end

  def unregister(session_id) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _server -> GenServer.cast(__MODULE__, {:unregister, session_id})
    end
  end

  def cancel(session_id, reason \\ :operator_stop) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _server -> GenServer.call(__MODULE__, {:cancel, session_id, reason})
    end
  end

  def registered?(session_id) do
    case Process.whereis(__MODULE__) do
      nil -> false
      _server -> GenServer.call(__MODULE__, {:registered?, session_id})
    end
  end

  def run_cancellable(session_id, fun) when is_function(fun, 0) do
    caller = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(caller, {__MODULE__, :cancellable_result, self(), fun.()})
      end)

    receive do
      {__MODULE__, :cancellable_result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:cancel_session, ^session_id, reason} ->
        Process.exit(pid, :kill)
        flush_request_down(ref, pid)
        {:error, {:cancelled, reason}}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:request_process_exit, reason}}
    end
  end

  defp flush_request_down(ref, pid) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      100 -> :ok
    end
  end

  ## Server

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}, monitors: %{}}}
  end

  @impl true
  def handle_cast({:register, session_id, pid}, state) do
    state = drop_session(state, session_id)

    if Process.alive?(pid) do
      ref = Process.monitor(pid)

      {:noreply,
       %{
         state
         | sessions: Map.put(state.sessions, session_id, %{pid: pid, ref: ref}),
           monitors: Map.put(state.monitors, ref, session_id)
       }}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:unregister, session_id}, state) do
    {:noreply, drop_session(state, session_id)}
  end

  @impl true
  def handle_call({:cancel, session_id, reason}, _from, state) do
    case Map.get(state.sessions, session_id) do
      %{pid: pid} ->
        send(pid, {:cancel_session, session_id, reason})
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:registered?, session_id}, _from, state) do
    {:reply, Map.has_key?(state.sessions, session_id), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {session_id, monitors} ->
        {:noreply,
         %{state | sessions: Map.delete(state.sessions, session_id), monitors: monitors}}
    end
  end

  defp drop_session(state, session_id) do
    case Map.pop(state.sessions, session_id) do
      {nil, sessions} ->
        %{state | sessions: sessions}

      {%{ref: ref}, sessions} ->
        Process.demonitor(ref, [:flush])
        %{state | sessions: sessions, monitors: Map.delete(state.monitors, ref)}
    end
  end
end
