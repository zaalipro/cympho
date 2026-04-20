defmodule Cympho.AgentHeartbeat do
  @moduledoc """
  Per-agent GenServer that manages heartbeat lifecycle.
  """
  use GenServer

  alias Cympho.AgentHeartbeat.{Registry, Supervisor}

  @type status :: :idle | :working
  @type state :: %{
          agent_id: String.t(),
          status: status(),
          current_issue_id: String.t() | nil,
          timer_ref: reference() | nil
        }

  @heartbeat_interval :timer.seconds(30)

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the AgentHeartbeat GenServer for the given agent_id.
  """
  @spec start_link(agent_id: String.t()) :: GenServer.on_start()
  def start_link(agent_id: agent_id) do
    GenServer.start_link(__MODULE__, agent_id, name: via(agent_id))
  end

  @doc """
  Returns a tuple used to register/lookup the heartbeat process via Registry.
  """
  def via(agent_id) do
    {:via, Registry, {agent_id}}
  end

  @doc """
  Starts a heartbeat process for the given agent_id.
  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_for_agent(String.t()) :: {:ok, pid()} | {:error, atom()}
  def start_for_agent(agent_id) when is_binary(agent_id) do
    case Registry.lookup(agent_id) do
      {:ok, _pid} ->
        {:error, :already_started}

      :error ->
        DynamicSupervisor.start_child(
          Cympho.AgentHeartbeat.Supervisor,
          {__MODULE__, agent_id: agent_id}
        )
    end
  end

  @doc """
  Stops the heartbeat process for the given agent_id.
  """
  @spec stop_for_agent(String.t()) :: :ok | {:error, :not_found}
  def stop_for_agent(agent_id) do
    case Registry.lookup(agent_id) do
      {:ok, pid} ->
        GenServer.stop(pid, :normal)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets the current status of the heartbeat for the given agent_id.
  """
  @spec status(String.t()) :: {:ok, status()} | {:error, :not_found}
  def status(agent_id) do
    case Registry.lookup(agent_id) do
      {:ok, pid} ->
        {:ok, GenServer.call(pid, :get_status)}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Transitions the heartbeat to working status and records the current issue.
  """
  @spec set_working(String.t(), String.t()) :: :ok | {:error, :not_found}
  def set_working(agent_id, issue_id) do
    case Registry.lookup(agent_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:set_working, issue_id})

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Transitions the heartbeat back to idle status.
  """
  @spec set_idle(String.t()) :: :ok | {:error, :not_found}
  def set_idle(agent_id) do
    case Registry.lookup(agent_id) do
      {:ok, pid} ->
        GenServer.call(pid, :set_idle)

      :error ->
        {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(agent_id: agent_id) do
    timer_ref = schedule_heartbeat()
    {:ok, %{agent_id: agent_id, status: :idle, current_issue_id: nil, timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # Skeleton: log heartbeat occurrence
    _ = :logger.info("[AgentHeartbeat] heartbeat for agent #{state.agent_id}")
    timer_ref = schedule_heartbeat()
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:shutdown, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call({:set_working, issue_id}, _from, state) do
    {:reply, :ok, %{state | status: :working, current_issue_id: issue_id}}
  end

  @impl true
  def handle_call(:set_idle, _from, state) do
    {:reply, :ok, %{state | status: :idle, current_issue_id: nil}}
  end

  @impl true
  def terminate(reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    _ = :logger.info("[AgentHeartbeat] terminated for agent #{state.agent_id}, reason: #{inspect(reason)}")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end
end