defmodule Cympho.AgentHeartbeat do
  @moduledoc """
  Per-agent GenServer that manages heartbeat lifecycle.

  With the default `delegate_to_dispatcher: true`, heartbeat processes are
  event-driven: a durable wake or explicit trigger stamps agent liveness,
  heals a transient `:error`, and nudges the central Dispatcher. They do not
  keep one periodic timer (and its database traffic) per agent.

  The legacy direct-dispatch mode (`delegate_to_dispatcher: false`) retains the
  periodic cycle: query assigned work, claim it, start an Orchestrator, then
  schedule the next heartbeat with `Process.send_after/3`.
  """

  use GenServer
  require Logger

  alias Cympho.AgentHeartbeat.Supervisor
  alias Cympho.{Orchestrator, Issues, Agents, Activities, Skills, Companies}
  alias Cympho.Orchestrator.Dispatcher
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
          available_skills: list(map()) | nil,
          wake_pending: boolean()
        }

  @default_heartbeat_interval :timer.seconds(60)
  @min_heartbeat_interval :timer.seconds(5)

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :agent_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

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
  Looks up the heartbeat pid for an agent. Returns `{:ok, pid}` or `:error`.
  """
  @spec whereis(String.t()) :: {:ok, pid()} | :error
  def whereis(agent_id) do
    case Registry.lookup(Cympho.AgentHeartbeat.Registry, agent_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Starts a heartbeat process for the given agent_id.
  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_for_agent(String.t()) :: {:ok, pid()} | {:error, atom()}
  def start_for_agent(agent_id) when is_binary(agent_id) do
    case whereis(agent_id) do
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
    case whereis(agent_id) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, :infinity)
          catch
            :exit, _ -> {:error, :not_found}
          end
        else
          {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets the current status of the heartbeat for the given agent_id.
  """
  @spec status(String.t()) :: {:ok, status()} | {:error, :not_found}
  def status(agent_id) do
    case whereis(agent_id) do
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
    case whereis(agent_id) do
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
    case whereis(agent_id) do
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
    case whereis(agent_id) do
      {:ok, pid} ->
        {:ok, GenServer.call(pid, :get_state)}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Fetches state for many agents in parallel. Missing agents map to `{:error, :not_found}`.
  Caps concurrency to avoid flooding the scheduler when called from a LiveView mount.
  """
  @spec get_states([String.t()]) :: %{String.t() => {:ok, map()} | {:error, :not_found}}
  def get_states(agent_ids) when is_list(agent_ids) do
    agent_ids
    |> Task.async_stream(
      fn id -> {id, get_state(id)} end,
      max_concurrency: 16,
      ordered: false,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {id, result}}, acc -> Map.put(acc, id, result)
      {:exit, _}, acc -> acc
    end)
  end

  @doc """
  Triggers an immediate heartbeat for the given agent_id.
  Sends a :heartbeat message to the GenServer to check for work immediately.
  Used by Wakes context to wake agents on comments, blocker resolution, and child completion.
  """
  @spec trigger_heartbeat(String.t()) :: :ok | {:error, :not_found}
  def trigger_heartbeat(agent_id) when is_binary(agent_id) do
    case whereis(agent_id) do
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
    # Delegated heartbeats are wake-driven. The Dispatcher already owns a
    # periodic poll, so arming one timer per agent only adds idle DB churn.
    # Legacy direct-dispatch mode keeps its original timer. Use the default
    # interval here so init never queries the DB in either mode.
    timer_ref =
      if delegate_to_dispatcher?() do
        nil
      else
        Process.send_after(self(), {:heartbeat, :timer}, @default_heartbeat_interval)
      end

    Phoenix.PubSub.subscribe(
      Cympho.PubSub,
      Cympho.HeartbeatEngine.WakeupQueue.topic_for_agent(agent_id)
    )

    # `available_skills` is part of @type state and the direct-dispatch fallback
    # sets it with `%{state | ...}`, which raises KeyError on a missing key. It
    # was absent here, so that branch crashed *after* checking the issue out and
    # starting the orchestrator, leaving a live agent session behind a heartbeat
    # process restarted as idle.
    state = %{
      agent_id: agent_id,
      status: :idle,
      current_issue_id: nil,
      started_at: nil,
      timer_ref: timer_ref,
      available_skills: nil,
      wake_pending: false
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # External trigger (trigger_heartbeat/1 or a wake broadcast): an event
    # happened, so nudging the dispatcher is warranted.
    run_heartbeat(state, _event_triggered? = true)
  end

  @impl true
  def handle_info({:heartbeat, :timer}, state) do
    if delegate_to_dispatcher?() do
      # A timer may already be in the mailbox when configuration switches from
      # legacy mode. Drop it without touching the DB or arming a replacement.
      {:noreply, %{state | timer_ref: nil, wake_pending: false}}
    else
      run_heartbeat(state, _event_triggered? = false)
    end
  end

  @impl true
  def handle_info(:shutdown, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:wakeup_enqueued, _agent_id, _wake}, state) do
    # Coalesce wake bursts: one :heartbeat message per drain, no matter how
    # many wakes were broadcast while it was queued.
    if state.wake_pending do
      {:noreply, state}
    else
      send(self(), :heartbeat)
      {:noreply, %{state | wake_pending: true}}
    end
  end

  defp run_heartbeat(state, event_triggered?) do
    # Cancel any still-armed timer before rescheduling. Event-triggered
    # heartbeats arrive out of band; without this cancel each wake would
    # leave the old timer running and permanently add another heartbeat
    # loop for this agent (timer multiplication).
    cancel_heartbeat_timer(state.timer_ref)
    state = %{state | timer_ref: nil, wake_pending: false}
    agent_id = state.agent_id

    cond do
      delegate_to_dispatcher?() ->
        # This branch only handles real external events. Periodic timer messages
        # are discarded above, so idle agents do not generate background DB
        # traffic. One event performs one liveness action and one Dispatcher
        # nudge; no replacement timer is armed.
        if event_triggered? do
          _ = recover_and_touch(agent_id)
          _ = Dispatcher.poll_now()
        end

        {:noreply, state}

      Agents.is_agent_at_capacity?(agent_id) ->
        _ = Agents.touch_heartbeat(agent_id)
        timer_ref = schedule_heartbeat(agent_id)
        {:noreply, %{state | timer_ref: timer_ref}}

      true ->
        do_heartbeat(state)
    end
  end

  defp cancel_heartbeat_timer(nil), do: :ok

  defp cancel_heartbeat_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp do_heartbeat(state) do
    agent_id = state.agent_id

    with {:ok, agent} <- Agents.get_agent(agent_id),
         {:ok, agent} <- maybe_recover_error_status(agent),
         :ok <- check_agent_runtime_available(agent) do
      do_heartbeat_for_available_agent(state, agent)
    else
      {:skip, _reason} ->
        timer_ref = schedule_heartbeat(agent_id)
        {:noreply, %{state | timer_ref: timer_ref}}

      {:error, _} ->
        timer_ref = schedule_heartbeat(agent_id)
        {:noreply, %{state | timer_ref: timer_ref}}
    end
  end

  # A transient failure (orchestrator start error, adapter blip) marks the
  # agent :error, and :error is in the runtime skip-list — without recovery
  # the agent's own heartbeat would refuse to run forever: a permanent silent
  # sleep, since nothing else resets :error automatically. Reset to :idle at
  # most once per heartbeat tick so transient errors self-heal at a bounded
  # retry rate. Persistent failures still trip the adapter circuit breaker
  # into :paused, which is deliberately not auto-recovered.
  defp maybe_recover_error_status(%{status: :error} = agent) do
    Logger.info("[AgentHeartbeat] recovering agent from error status",
      agent_id: agent.id,
      company_id: agent.company_id,
      component: "agent_heartbeat"
    )

    case Agents.recover_error_status(agent) do
      {:ok, recovered} -> {:ok, recovered}
      {:error, _reason} -> {:skip, :error_status_recovery_failed}
    end
  end

  defp maybe_recover_error_status(agent), do: {:ok, agent}

  # When work is delegated to the dispatcher, still stamp liveness and heal
  # :error so the roster and eligibility do not freeze under the default path.
  defp recover_and_touch(agent_id) do
    case Agents.get_agent(agent_id) do
      {:ok, %{status: :error} = agent} ->
        # recover_error_status stamps last_heartbeat_at via update_agent_status.
        _ = maybe_recover_error_status(agent)
        :ok

      {:ok, agent} ->
        _ = Agents.touch_heartbeat(agent)
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp do_heartbeat_for_available_agent(state, agent) do
    agent_id = state.agent_id
    issue = fetch_next_todo_issue(agent)

    if issue do
      # Checkout the issue
      case Issues.checkout_issue(issue, agent_id) do
        {:ok, checked_out_issue} ->
          # Fetch available skills for this agent
          available_skills = Skills.available_for_agent(agent_id)
          started_at = DateTime.utc_now()
          _ = maybe_update_agent_status(agent_id, :running)

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
                   started_at: started_at,
                   timer_ref: timer_ref,
                   available_skills: available_skills
               }}

            {:error, reason} ->
              _ =
                Logger.error("[AgentHeartbeat] failed to start orchestrator: #{inspect(reason)}")

              # Undo only the unbound checkout we just claimed. A successor run
              # may have bound checkout_run_id after a bind race; unconditional
              # release would clear that owner (same CAS as Dispatcher).
              _ = Issues.release_unbound_checkout(checked_out_issue, :todo)

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
          _ = maybe_update_agent_status(agent_id, :idle)
          timer_ref = schedule_heartbeat(agent_id)
          {:noreply, %{state | timer_ref: timer_ref}}
      end
    else
      # No work available, stay idle
      _ = maybe_update_agent_status(agent_id, :idle)
      timer_ref = schedule_heartbeat(agent_id)

      {:noreply,
       %{state | status: :idle, current_issue_id: nil, started_at: nil, timer_ref: timer_ref}}
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

    broadcast_idle_transition(state.agent_id)

    {:reply, :ok, %{state | status: :idle, current_issue_id: nil, started_at: nil}}
  end

  defp broadcast_idle_transition(agent_id) do
    case Agents.get_agent(agent_id) do
      {:ok, %{company_id: company_id}} when is_binary(company_id) and company_id != "" ->
        payload = {:agent_heartbeat_updated, agent_id, %{status: :idle, company_id: company_id}}

        # Per-company topic for LiveView consumers (kanban, dashboards).
        # Not company:#{id}:… form, but still routed through PubSubGuard.
        _ = Cympho.PubSubGuard.broadcast("agent_heartbeats:#{company_id}", payload)

        # System topic for app-wide consumers (AutoAssignmentReassigner).
        _ = Cympho.PubSubGuard.broadcast("system:agent_heartbeats", payload)

      _ ->
        # Fail-closed: never publish tenant heartbeats without a company_id.
        :ok
    end
  end

  @impl true
  def terminate(reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    _ =
      Logger.info(
        "[AgentHeartbeat] terminated for agent #{state.agent_id}, reason: #{inspect(reason)}"
      )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp schedule_heartbeat(agent_id) do
    if delegate_to_dispatcher?() do
      # Defensive guard for mode changes while a direct heartbeat is running:
      # delegated scheduling must not query the agent row for its interval.
      nil
    else
      interval = heartbeat_interval(agent_id)
      Process.send_after(self(), {:heartbeat, :timer}, interval)
    end
  end

  defp delegate_to_dispatcher? do
    :cympho
    |> Application.get_env(:agent_heartbeat, [])
    |> Keyword.get(:delegate_to_dispatcher, true)
  end

  defp heartbeat_interval(agent_id) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        config = agent.heartbeat_config || %{}

        config
        |> Map.get("interval_ms", @default_heartbeat_interval)
        |> normalize_interval()

      {:error, _} ->
        @default_heartbeat_interval
    end
  rescue
    Ecto.Query.CastError ->
      @default_heartbeat_interval
  end

  # A malformed `interval_ms` (zero, negative, or non-integer) must not crash
  # the heartbeat loop or turn it into a hot spin — clamp to a sane floor.
  defp normalize_interval(interval) when is_integer(interval) and interval > 0,
    do: max(interval, @min_heartbeat_interval)

  defp normalize_interval(_interval), do: @default_heartbeat_interval

  defp fetch_next_todo_issue(agent) do
    project_id = agent.project_id

    Issue
    |> where(assignee_id: ^agent.id, status: :todo)
    |> where(
      [i],
      fragment(
        "COALESCE((?->'issue_runtime'->>'paused')::boolean, false) = false",
        i.monitor_state
      )
    )
    |> maybe_filter_by_project(project_id)
    |> first()
    |> Repo.one()
  end

  defp maybe_filter_by_project(query, nil), do: query
  defp maybe_filter_by_project(query, project_id), do: where(query, project_id: ^project_id)

  defp check_agent_runtime_available(agent) do
    cond do
      agent.status in [:paused, :terminated, :offline, :error, :pending_approval, :sleeping] ->
        {:skip, {:agent_status, agent.status}}

      agent.governance_status in ["paused", "terminated", "pending_approval"] ->
        {:skip, {:governance_status, agent.governance_status}}

      not company_active?(agent.company_id) ->
        {:skip, :company_inactive}

      true ->
        :ok
    end
  end

  defp company_active?(nil), do: true

  defp company_active?(company_id) do
    company_id
    |> Companies.get_company!()
    |> Companies.active?()
  rescue
    _ -> false
  end

  defp maybe_update_agent_status(agent_id, new_status) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        if agent.status != new_status do
          Agents.update_agent_status(agent, %{status: new_status})
        else
          # Status unchanged (e.g. idle with no work) — still advance the
          # roster heartbeat clock so "Never" does not stick after real ticks.
          Agents.touch_heartbeat(agent)
        end

      {:error, _} ->
        :error
    end
  end
end
