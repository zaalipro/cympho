defmodule Cympho.AgentAdapters.HealthChecker do
  @moduledoc """
  GenServer that performs periodic health checks on agent adapters.

  For each active agent, polls the adapter's health_check/1 callback at a
  configured interval. Tracks consecutive failures and transitions agent status
  to :error after 3 consecutive failures. Transitions back to :idle when health
  recovers.

  Health state changes are broadcast via Phoenix.PubSub on the "agents" topic.
  """

  use GenServer
  require Logger

  alias Cympho.{Agents, AgentAdapters}
  alias Cympho.Agents.Agent
  alias Cympho.Repo
  import Ecto.Query

  @type health_state :: :healthy | :degraded | :unavailable
  @type state :: %{
          timer_ref: reference() | nil,
          interval: milliseconds(),
          consecutive_failures: %{agent_id() => non_neg_integer()},
          last_health_status: %{agent_id() => health_state()}
        }

  @type milliseconds :: pos_integer()
  @type agent_id :: String.t()

  @default_interval :timer.minutes(5)
  @max_consecutive_failures 3
  @pubsub_topic "agents"

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the HealthChecker GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {init_opts, gen_opts} = Keyword.split(opts, [:interval])
    GenServer.start_link(__MODULE__, init_opts, Keyword.put(gen_opts, :name, __MODULE__))
  end

  @doc """
  Gets the current health status for an agent.
  """
  @spec get_health_status(agent_id()) :: {:ok, health_state()} | {:error, :not_found}
  def get_health_status(agent_id) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:get_health_status, agent_id})
    end
  end

  @doc """
  Gets all tracked health statuses.
  """
  @spec get_all_health_statuses() :: %{agent_id() => health_state()}
  def get_all_health_statuses do
    case GenServer.whereis(__MODULE__) do
      nil -> %{}
      pid -> GenServer.call(pid, :get_all_health_statuses)
    end
  end

  @doc """
  Triggers an immediate health check for all active agents.
  """
  @spec check_all_now() :: :ok
  def check_all_now do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> send(__MODULE__, :check_all); :ok
    end
  end

  @doc """
  Triggers an immediate health check for a specific agent.
  """
  @spec check_agent_now(agent_id()) :: :ok
  def check_agent_now(agent_id) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> send(__MODULE__, {:check_agent, agent_id}); :ok
    end
  end

  @doc """
  Subscribes to agent health status updates via PubSub.
  """
  @spec subscribe() :: :ok
  def subscribe do
    Phoenix.PubSub.subscribe(Cympho.PubSub, @pubsub_topic)
  end

  @doc """
  Unsubscribes from agent health status updates.
  """
  @spec unsubscribe() :: :ok
  def unsubscribe do
    Phoenix.PubSub.unsubscribe(Cympho.PubSub, @pubsub_topic)
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)

    # Schedule first health check
    timer_ref = Process.send_after(self(), :check_all, interval)

    state = %{
      timer_ref: timer_ref,
      interval: interval,
      consecutive_failures: %{},
      last_health_status: %{}
    }

    Logger.info("[HealthChecker] started with interval #{interval}ms")
    {:ok, state}
  end

  @impl true
  def handle_info(:check_all, state) do
    perform_health_checks(state)
    timer_ref = Process.send_after(self(), :check_all, state.interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info({:check_agent, agent_id}, state) do
    check_agent_health(agent_id, state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:get_health_status, agent_id}, _from, state) do
    status = Map.get(state.last_health_status, agent_id, :healthy)
    {:reply, {:ok, status}, state}
  end

  def handle_call(:get_all_health_statuses, _from, state) do
    {:reply, state.last_health_status, state}
  end

  @impl true
  def terminate(reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    Logger.info("[HealthChecker] terminated: #{inspect(reason)}")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp perform_health_checks(state) do
    # Get all active agents (not offline)
    active_agents =
      Agent
      |> where([a], a.status != :offline)
      |> Repo.all()

    Logger.debug("[HealthChecker] checking #{length(active_agents)} active agents")

    Enum.each(active_agents, fn agent ->
      check_agent_health(agent.id, state)
    end)
  end

  defp check_agent_health(agent_id, state) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        health_result = check_adapter_health(agent)
        process_health_result(agent, health_result, state)

      {:error, :not_found} ->
        Logger.debug("[HealthChecker] agent #{agent_id} not found")
        :ok
    end
  end

  defp check_adapter_health(%Agent{} = agent) do
    case AgentAdapters.resolve(%{adapter: agent.adapter, config: agent.config}) do
      {:ok, adapter_module, _config} ->
        try do
          adapter_module.health_check(agent.config)
        rescue
          e ->
            Logger.error("[HealthChecker] health_check crashed for #{agent.id}: #{inspect(e)}")
            %{status: :unavailable, message: "Health check failed", checked_at: DateTime.utc_now()}
        end

      {:error, :no_adapter} ->
        %{status: :unavailable, message: "Adapter not found", checked_at: DateTime.utc_now()}
    end
  end

  defp process_health_result(agent, health_result, state) do
    current_health_status = Map.get(state.last_health_status, agent.id, :healthy)
    new_health_status = health_result.status
    consecutive_failures = Map.get(state.consecutive_failures, agent.id, 0)

    cond do
      # Health recovered
      new_health_status == :healthy and current_health_status != :healthy ->
        Logger.info("[HealthChecker] agent #{agent.id} health recovered")

        # Reset consecutive failures
        _ = put_in(state.consecutive_failures[agent.id], 0)
        _ = put_in(state.last_health_status[agent.id], :healthy)

        # Broadcast health status change
        broadcast_health_status(agent.id, :healthy, current_health_status)

        # Transition agent back to idle if it was in error state
        if agent.status == :error do
          case Agents.update_agent(agent, %{status: :idle, health_status: :healthy}) do
            {:ok, _updated_agent} ->
              Logger.info("[HealthChecker] agent #{agent.id} transitioned to :idle")

            {:error, changeset} ->
              Logger.error("[HealthChecker] failed to update agent #{agent.id}: #{inspect(changeset)}")
          end
        else
          # Just update health_status
          Agents.update_agent(agent, %{health_status: :healthy})
        end

      # Health degraded or unavailable
      new_health_status in [:degraded, :unavailable] ->
        new_failures = consecutive_failures + 1
        Logger.warning("[HealthChecker] agent #{agent.id} unhealthy (#{new_failures}/#{@max_consecutive_failures}): #{health_result.message}")

        # Update state
        _ = put_in(state.consecutive_failures[agent.id], new_failures)
        _ = put_in(state.last_health_status[agent.id], new_health_status)

        # Broadcast health status change if it's a new state
        if new_health_status != current_health_status do
          broadcast_health_status(agent.id, new_health_status, current_health_status)
        end

        # Transition to error after max consecutive failures
        if new_failures >= @max_consecutive_failures and agent.status != :error do
          case Agents.update_agent(agent, %{status: :error, health_status: new_health_status}) do
            {:ok, _updated_agent} ->
              Logger.error("[HealthChecker] agent #{agent.id} transitioned to :error after #{new_failures} consecutive failures")

            {:error, changeset} ->
              Logger.error("[HealthChecker] failed to update agent #{agent.id}: #{inspect(changeset)}")
          end
        else
          # Just update health_status
          Agents.update_agent(agent, %{health_status: new_health_status})
        end

      # Health remains the same
      true ->
        # Reset consecutive failures if healthy
        if new_health_status == :healthy and consecutive_failures > 0 do
          _ = put_in(state.consecutive_failures[agent.id], 0)
        end
    end

    # Return updated state
    %{state | consecutive_failures: Map.get(state.consecutive_failures, agent.id, consecutive_failures)}
  end

  defp broadcast_health_status(agent_id, new_status, old_status) do
    payload = %{
      event_type: :health_status_changed,
      agent_id: agent_id,
      old_status: old_status,
      new_status: new_status,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Phoenix.PubSub.broadcast(Cympho.PubSub, @pubsub_topic, {:health_status_changed, payload})
    Logger.debug("[HealthChecker] broadcast health status change for agent #{agent_id}: #{old_status} -> #{new_status}")
  end
end
