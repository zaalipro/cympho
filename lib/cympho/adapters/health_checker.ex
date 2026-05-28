defmodule Cympho.Adapters.HealthChecker do
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

  alias Cympho.Adapters
  alias Cympho.Agents
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
      nil ->
        :ok

      _pid ->
        send(__MODULE__, :check_all)
        :ok
    end
  end

  @doc """
  Triggers an immediate health check for a specific agent.
  """
  @spec check_agent_now(agent_id()) :: :ok
  def check_agent_now(agent_id) do
    case GenServer.whereis(__MODULE__) do
      nil ->
        :ok

      _pid ->
        send(__MODULE__, {:check_agent, agent_id})
        :ok
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

  # Stream agents in batches so a 10k-agent install doesn't load the whole
  # table into memory on every health-check tick. We only need each agent's
  # id to look it up in `check_agent_health/2`, so the projection stays small.
  @health_check_batch_size 500

  defp perform_health_checks(state) do
    query = from a in Agent, where: a.status != :offline, select: a.id

    {:ok, count} =
      Repo.transaction(fn ->
        query
        |> Repo.stream(max_rows: @health_check_batch_size)
        |> Stream.each(fn agent_id -> check_agent_health(agent_id, state) end)
        |> Enum.count()
      end)

    Logger.debug("[HealthChecker] checked #{count} active agents")
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

  # Bound each adapter's health_check call so a hung adapter (e.g. one whose
  # network call doesn't return) cannot stall the loop and starve other agents.
  @health_check_timeout_ms 5_000

  defp check_adapter_health(%Agent{} = agent) do
    case Adapters.Registry.resolve_agent(%{adapter: agent.adapter, config: agent.config}) do
      {:ok, adapter_module, _config} ->
        run_with_timeout(adapter_module, agent)

      {:error, :no_adapter} ->
        %{status: :unavailable, message: "Adapter not found", checked_at: DateTime.utc_now()}
    end
  end

  defp run_with_timeout(adapter_module, %Agent{} = agent) do
    task =
      Task.Supervisor.async_nolink(Cympho.TaskSupervisor, fn ->
        adapter_module.health_check(agent.config)
      end)

    case Task.yield(task, @health_check_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        Logger.error("[HealthChecker] health_check crashed for #{agent.id}: #{inspect(reason)}")

        %{
          status: :unavailable,
          message: "Health check failed",
          checked_at: DateTime.utc_now()
        }

      nil ->
        Logger.warning("[HealthChecker] health_check timed out for #{agent.id}")

        %{
          status: :unavailable,
          message: "Health check timed out after #{@health_check_timeout_ms}ms",
          checked_at: DateTime.utc_now()
        }
    end
  end

  defp process_health_result(agent, health_result, state) do
    current_health_status = Map.get(state.last_health_status, agent.id, :healthy)
    new_health_status = health_result.status
    consecutive_failures = Map.get(state.consecutive_failures, agent.id, 0)

    cond do
      new_health_status == :healthy and current_health_status != :healthy ->
        Logger.info("[HealthChecker] agent #{agent.id} health recovered")
        broadcast_health_status(agent.id, :healthy, current_health_status)

        if agent.status == :error do
          case Agents.update_agent(agent, %{status: :idle, health_status: :healthy}) do
            {:ok, _} ->
              Logger.info("[HealthChecker] agent #{agent.id} transitioned to :idle")

            {:error, changeset} ->
              Logger.error(
                "[HealthChecker] failed to update agent #{agent.id}: #{inspect(changeset)}"
              )
          end
        else
          Agents.update_agent(agent, %{health_status: :healthy})
        end

        state
        |> put_in([:consecutive_failures, agent.id], 0)
        |> put_in([:last_health_status, agent.id], :healthy)

      new_health_status in [:degraded, :unavailable] ->
        new_failures = consecutive_failures + 1

        Logger.warning(
          "[HealthChecker] agent #{agent.id} unhealthy (#{new_failures}/#{@max_consecutive_failures}): #{health_result.message}"
        )

        if new_health_status != current_health_status do
          broadcast_health_status(agent.id, new_health_status, current_health_status)
        end

        if new_failures >= @max_consecutive_failures and agent.status != :error do
          case Agents.update_agent(agent, %{status: :error, health_status: new_health_status}) do
            {:ok, _} ->
              Logger.error(
                "[HealthChecker] agent #{agent.id} transitioned to :error after #{new_failures} consecutive failures"
              )

            {:error, changeset} ->
              Logger.error(
                "[HealthChecker] failed to update agent #{agent.id}: #{inspect(changeset)}"
              )
          end
        else
          Agents.update_agent(agent, %{health_status: new_health_status})
        end

        state
        |> put_in([:consecutive_failures, agent.id], new_failures)
        |> put_in([:last_health_status, agent.id], new_health_status)

      true ->
        if new_health_status == :healthy and consecutive_failures > 0 do
          put_in(state, [:consecutive_failures, agent.id], 0)
        else
          state
        end
    end
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

    Logger.debug(
      "[HealthChecker] broadcast health status change for agent #{agent_id}: #{old_status} -> #{new_status}"
    )
  end
end
