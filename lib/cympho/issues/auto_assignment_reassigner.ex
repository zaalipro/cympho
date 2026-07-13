defmodule Cympho.Issues.AutoAssignmentReassigner do
  @moduledoc """
  Subscribes to agent heartbeat status updates and triggers backlog
  reassignment when an agent transitions to :idle.

  Idle broadcasts are best-effort (PubSub delivery can be missed across
  crashes or node restarts), so a periodic sweep also scans for companies
  with unassigned backlog issues and reassigns them. This guarantees no
  queued issue waits forever on a missed event.

  Reassignment is scoped to the idle agent's company. When the supervised
  task crashes or fails to find a company_id, the failure is logged and the
  GenServer keeps running.
  """

  use GenServer
  require Logger
  import Ecto.Query, warn: false
  alias Cympho.Agents
  alias Cympho.Issues.AutoAssignment
  alias Cympho.Issues.Issue
  alias Cympho.Repo

  @max_concurrent_tasks 5
  @default_sweep_interval :timer.minutes(5)
  @sweep_company_limit 20

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "system:agent_heartbeats")
    schedule_sweep()
    {:ok, %{tasks: %{}}}
  end

  @impl true
  def handle_info({:agent_heartbeat_updated, agent_id, hb_state}, state) do
    cond do
      hb_state.status != :idle ->
        {:noreply, state}

      map_size(state.tasks) >= @max_concurrent_tasks ->
        Logger.warning(
          "[AutoAssignmentReassigner] at max concurrent (#{@max_concurrent_tasks}); skipping reassign for agent #{agent_id}"
        )

        {:noreply, state}

      true ->
        task = spawn_reassign_task(agent_id, hb_state[:company_id])
        tasks = Map.put(state.tasks, task.ref, agent_id)
        {:noreply, %{state | tasks: tasks}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    state = run_sweep(state)
    schedule_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, {:ok, assigned, queued}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    agent_id = Map.get(state.tasks, ref, "<unknown>")

    Logger.debug(
      "[AutoAssignmentReassigner] agent #{agent_id} idle → reassigned #{assigned}, queued #{queued}"
    )

    {:noreply, %{state | tasks: Map.delete(state.tasks, ref)}}
  end

  def handle_info({ref, other_result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    agent_id = Map.get(state.tasks, ref, "<unknown>")

    Logger.warning(
      "[AutoAssignmentReassigner] reassign task for agent #{agent_id} returned unexpected result: #{inspect(other_result)}"
    )

    {:noreply, %{state | tasks: Map.delete(state.tasks, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    agent_id = Map.get(state.tasks, ref, "<unknown>")

    if reason != :normal do
      Logger.warning(
        "[AutoAssignmentReassigner] reassign task for agent #{agent_id} crashed: #{inspect(reason)}"
      )
    end

    {:noreply, %{state | tasks: Map.delete(state.tasks, ref)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp spawn_reassign_task(_agent_id, company_id) when is_binary(company_id) do
    Task.Supervisor.async_nolink(Cympho.TaskSupervisor, fn ->
      AutoAssignment.reassign_backlog(company_id)
    end)
  end

  defp spawn_reassign_task(agent_id, _missing_company_id) do
    Task.Supervisor.async_nolink(Cympho.TaskSupervisor, fn ->
      case Agents.get_agent(agent_id) do
        {:ok, %{company_id: company_id}} when is_binary(company_id) ->
          AutoAssignment.reassign_backlog(company_id)

        _ ->
          {:error, :agent_or_company_missing}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Periodic sweep — safety net for missed idle broadcasts
  # ---------------------------------------------------------------------------

  defp run_sweep(state) do
    available = @max_concurrent_tasks - map_size(state.tasks)

    if available <= 0 do
      state
    else
      company_ids = companies_with_unassigned_backlog(min(available, @sweep_company_limit))

      Enum.reduce(company_ids, state, fn company_id, acc ->
        task =
          Task.Supervisor.async_nolink(Cympho.TaskSupervisor, fn ->
            AutoAssignment.reassign_backlog(company_id)
          end)

        %{acc | tasks: Map.put(acc.tasks, task.ref, "sweep:#{company_id}")}
      end)
    end
  rescue
    error ->
      # A transient DB error must not crash the reassigner: it would drop the
      # in-flight task refs and (until restart) the PubSub subscription.
      Logger.warning("[AutoAssignmentReassigner] sweep failed: #{inspect(error)}")
      state
  end

  defp companies_with_unassigned_backlog(limit) do
    Issue
    |> where([i], i.status == :backlog and is_nil(i.assignee_id) and not is_nil(i.company_id))
    |> where([i], is_nil(i.hidden_at))
    |> group_by([i], i.company_id)
    |> select([i], i.company_id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp schedule_sweep do
    case sweep_interval() do
      interval when is_integer(interval) and interval > 0 ->
        Process.send_after(self(), :sweep, interval)

      _ ->
        :ok
    end
  end

  # Disabled by default in test (no Ecto sandbox connection for the
  # app-supervised instance — same constraint as the watchdog); tests that
  # exercise the sweep opt in via Application.put_env.
  defp sweep_interval do
    default =
      if Application.get_env(:cympho, :env) == :test, do: 0, else: @default_sweep_interval

    Application.get_env(:cympho, :auto_assignment, [])
    |> Keyword.get(:sweep_interval_ms, default)
  end
end
