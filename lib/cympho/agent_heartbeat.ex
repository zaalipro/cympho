defmodule Cympho.AgentHeartbeat do
  @moduledoc """
  Per-agent GenServer that manages heartbeat lifecycle.

  The heartbeat cycle:
    1. On `:heartbeat` message: query for `todo` issues assigned to this agent
    2. Call `Cympho.Issues.checkout_issue/2` to claim the first available issue
    3. On success: start `Cympho.Orchestrator` for the issue
    4. On Orchestrator completion (via `handle_info`): update agent to `:idle`
    5. Schedule next heartbeat via `Process.send_after`
  """

  use GenServer

  alias Cympho.AgentHeartbeat.Supervisor
  alias Cympho.AgentHeartbeat.Registry, as: HeartbeatRegistry
  alias Cympho.{Orchestrator, Issues, Agents, Activities, Skills}
  alias Cympho.Issues.Issue
  alias Cympho.Repo
  import Ecto.Query

  @type status :: :idle | :running
  @type state :: %{
          agent_id: String.t(),
          status: status(),
          current_issue_id: String.t() | nil,
          started_at: DateTime.t() | nil,
          timer_ref: reference() | nil,
          available_skills: list(map()) | nil
        }

  @default_heartbeat_interval :timer.seconds(60)

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
    {:via, Registry, {Cympho.AgentHeartbeat.Registry, agent_id}}
  end

  @doc """
  Starts a heartbeat process for the given agent_id.
  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_for_agent(String.t()) :: {:ok, pid()} | {:error, atom()}
  def start_for_agent(agent_id) when is_binary(agent_id) do
    case HeartbeatRegistry.lookup(agent_id) do
      {:ok, _pid} ->
        {:error, :already_started}

      :error ->
        DynamicSupervisor.start_child(
          Supervisor,
          {__MODULE__, agent_id: agent_id}
        )
    end
  end

  @doc """
  Stops the heartbeat process for the given agent_id.
  """
  @spec stop_for_agent(String.t()) :: :ok | {:error, :not_found}
  def stop_for_agent(agent_id) do
    case HeartbeatRegistry.lookup(agent_id) do
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
    case HeartbeatRegistry.lookup(agent_id) do
      {:ok, pid} ->
        {:ok, GenServer.call(pid, :get_status)}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Transitions the heartbeat to working status and records the current issue.
  Called internally when starting work on an issue.
  """
  @spec set_working(String.t(), String.t()) :: :ok | {:error, :not_found}
  def set_working(agent_id, issue_id) do
    case HeartbeatRegistry.lookup(agent_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:set_working, issue_id})

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Transitions the heartbeat back to idle status.
  Called internally when work completes or errors.
  """
  @spec set_idle(String.t()) :: :ok | {:error, :not_found}
  def set_idle(agent_id) do
    case HeartbeatRegistry.lookup(agent_id) do
      {:ok, pid} ->
        GenServer.call(pid, :set_idle)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets the full state of the heartbeat for the given agent_id.
  """
  @spec get_state(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_state(agent_id) do
    case HeartbeatRegistry.lookup(agent_id) do
      {:ok, pid} ->
        {:ok, GenServer.call(pid, :get_state)}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Triggers an immediate heartbeat for the given agent_id.
  Sends a :heartbeat message to the GenServer to check for work immediately.
  Used by Wakes context to wake agents on comments, blocker resolution, and child completion.
  """
  @spec trigger_heartbeat(String.t()) :: :ok | {:error, :not_found}
  def trigger_heartbeat(agent_id) when is_binary(agent_id) do
    case HeartbeatRegistry.lookup(agent_id) do
      {:ok, pid} ->
        send(pid, :heartbeat)
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(agent_id) do
    # Use default interval in init to avoid DB queries during startup.
    # Tests often exit before init completes, causing sandbox disconnect errors.
    timer_ref = Process.send_after(self(), :heartbeat, @default_heartbeat_interval)

    state = %{
      agent_id: agent_id,
      status: :idle,
      current_issue_id: nil,
      started_at: nil,
      timer_ref: timer_ref
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    agent_id = state.agent_id

    # Check if agent is at capacity before picking up more work
    if Agents.is_agent_at_capacity?(agent_id) do
      timer_ref = schedule_heartbeat(agent_id)
      {:noreply, %{state | timer_ref: timer_ref}}
    else
      do_heartbeat(state)
    end
  end

  @impl true
  def handle_info(:shutdown, state) do
    {:stop, :normal, state}
  end

  defp do_heartbeat(state) do
    agent_id = state.agent_id

    # Update agent status to running if idle
    _ = maybe_update_agent_status(agent_id, :running)

    # Query for todo issues assigned to this agent
    issue = fetch_next_todo_issue(agent_id)

    if issue do
      # Checkout the issue
      case Issues.checkout_issue(issue, agent_id) do
        {:ok, checked_out_issue} ->
          # Set heartbeat to working
          _ = set_working(agent_id, checked_out_issue.id)

          # Fetch available skills for this agent
          available_skills = Skills.available_for_agent(agent_id)

          # Start orchestrator - it handles the session and posts completion comment
          case Orchestrator.start_and_run(checked_out_issue, agent_id, skills: available_skills) do
            {:ok, _pid} ->
              Activities.log_heartbeat_event(checked_out_issue.id, :started, %{
                agent_id: agent_id
              })

              CymphoWeb.Events.broadcast_agent_heartbeat(
                checked_out_issue,
                agent_id,
                %{status: :started, timestamp: DateTime.utc_now() |> DateTime.to_iso8601()}
              )

              timer_ref = schedule_heartbeat(agent_id)

              {:noreply,
               %{
                 state
                 | status: :running,
                   current_issue_id: checked_out_issue.id,
                   started_at: DateTime.utc_now(),
                   timer_ref: timer_ref,
                   available_skills: available_skills
               }}

            {:error, reason} ->
              _ =
                :logger.error("[AgentHeartbeat] failed to start orchestrator: #{inspect(reason)}")

              Activities.log_heartbeat_event(checked_out_issue.id, :failed, %{
                agent_id: agent_id,
                reason: inspect(reason)
              })

              _ = maybe_update_agent_status(agent_id, :error)
              timer_ref = schedule_heartbeat(agent_id)

              {:noreply,
               %{
                 state
                 | status: :idle,
                   current_issue_id: nil,
                   started_at: nil,
                   timer_ref: timer_ref
               }}
          end

        {:error, _reason} ->
          # No issue available or couldn't checkout
          timer_ref = schedule_heartbeat(agent_id)
          {:noreply, %{state | timer_ref: timer_ref}}
      end
    else
      # No work available, stay idle
      timer_ref = schedule_heartbeat(agent_id)
      {:noreply, %{state | timer_ref: timer_ref}}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:set_working, issue_id}, _from, state) do
    {:reply, :ok,
     %{state | status: :running, current_issue_id: issue_id, started_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:set_idle, _from, state) do
    # Broadcast agent heartbeat event when transitioning to idle
    if state.current_issue_id do
      case Issues.get_issue(state.current_issue_id) do
        {:ok, issue} ->
          CymphoWeb.Events.broadcast_agent_heartbeat(
            issue,
            state.agent_id,
            %{status: :idle, timestamp: DateTime.utc_now() |> DateTime.to_iso8601()}
          )

        _ ->
          :ok
      end
    end

    {:reply, :ok, %{state | status: :idle, current_issue_id: nil, started_at: nil}}
  end

  @impl true
  def terminate(reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    _ =
      :logger.info(
        "[AgentHeartbeat] terminated for agent #{state.agent_id}, reason: #{inspect(reason)}"
      )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp schedule_heartbeat(agent_id) do
    interval = heartbeat_interval(agent_id)
    Process.send_after(self(), :heartbeat, interval)
  end

  defp heartbeat_interval(agent_id) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        config = agent.heartbeat_config || %{}
        Map.get(config, "interval_ms", @default_heartbeat_interval)

      {:error, _} ->
        @default_heartbeat_interval
    end
  rescue
    Ecto.Query.CastError ->
      @default_heartbeat_interval
  end

  defp fetch_next_todo_issue(agent_id) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        project_id = agent.project_id

        Issue
        |> where(assignee_id: ^agent_id, status: :todo)
        |> maybe_filter_by_project(project_id)
        |> first()
        |> Repo.one()

      {:error, _} ->
        nil
    end
  end

  defp maybe_filter_by_project(query, nil), do: query
  defp maybe_filter_by_project(query, project_id), do: where(query, project_id: ^project_id)

  defp maybe_update_agent_status(agent_id, new_status) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        if agent.status != new_status do
          Agents.update_agent(agent, %{status: new_status})
        end

      {:error, _} ->
        :error
    end
  end
end
