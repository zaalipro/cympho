defmodule Cympho.Orchestrator do
  @moduledoc """
  GenServer that manages Claude CLI sessions for issue processing.

  Receives AgentRunner Port messages and translates them into session lifecycle events,
  publishing results via PubSub for LiveView consumption.

  Session lifecycle:
    start_session → session_started → turn_completed (possibly multiple) → session_ended

  Error cases:
    turn_ended_with_error (stall_timeout | exit_code | parse_error)
  """

  use GenServer
  alias Cympho.AgentRunner
  alias Cympho.Orchestrator.Session

  @stall_timeout Application.compile_env(:cympho, :agent_runner_stall_timeout, 300_000)

  @doc """
  Starts an orchestrator for the given issue, linked to the caller's process.
  """
  def start_link(issue, agent_id) do
    name = via_tuple(issue.id)
    GenServer.start_link(__MODULE__, {issue, agent_id}, name: name)
  end

  @doc """
  Looks up the orchestrator PID for a given issue.
  """
  def whereis(issue_id) do
    case Registry.lookup(Cympho.Orchestrator.Registry, issue_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Subscribes to orchestrator events for a given issue.
  """
  def subscribe(issue_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "orchestrator:#{issue_id}")
  end

  @doc """
  Stops the orchestrator for a given issue.
  """
  def stop(issue_id) do
    case whereis(issue_id) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp via_tuple(issue_id) do
    {:via, Registry, {Cympho.Orchestrator.Registry, issue_id}}
  end

  @impl true
  def init({issue, agent_id}) do
    state = %Session{
      issue: issue,
      agent_id: agent_id,
      status: :idle,
      turn_count: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:start_session, _from, %Session{status: :running} = state) do
    {:reply, {:ok, state.session_id}, state}
  end

  @impl true
  def handle_call(:start_session, _from, state) do
    session_id = AgentRunner.run(state.issue, state.agent_id, self())
    new_state = %{state | session_id: session_id, status: :running, turn_count: 0}
    {:reply, {:ok, session_id}, new_state}
  end

  @impl true
  def handle_info({:session_started, session_id}, %Session{} = state) do
    new_state = %{state | session_id: session_id, status: :running}
    broadcast(state, {:session_started, session_id})
    schedule_stall_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:turn_completed, session_id, result}, %Session{} = state) do
    case state.session_id == session_id do
      true ->
        turn_count = state.turn_count + 1
        new_state = %{state | turn_count: turn_count, last_result: result, last_output_time: now_ms()}
        broadcast(state, {:turn_completed, session_id, result})
        schedule_stall_check()
        {:noreply, new_state}

      false ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:turn_ended_with_error, session_id, reason}, %Session{} = state) do
    case state.session_id == session_id do
      true ->
        new_state = %{state | status: :failed, last_error: reason}
        broadcast(state, {:turn_ended_with_error, session_id, reason})
        {:noreply, new_state}

      false ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:stall_check, %Session{} = state) do
    if state.status == :running && state.last_output_time do
      if now_ms() - state.last_output_time > @stall_timeout do
        new_state = %{state | status: :failed, last_error: :stall_timeout}
        broadcast(state, {:turn_ended_with_error, state.session_id, :stall_timeout})
        {:noreply, new_state}
      else
        schedule_stall_check()
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:exit_status, code}, %Session{} = state) do
    new_state = %{state | status: :failed, last_error: {:exit_code, code}}
    broadcast(state, {:session_ended, state.session_id, :exit_code})
    {:noreply, new_state}
  end

  defp broadcast(%Session{} = state, message) do
    Phoenix.PubSub.broadcast(Cympho.PubSub, "orchestrator:#{state.issue.id}", message)
  end

  defp schedule_stall_check do
    check_interval = min(@stall_timeout, 30_000)
    Process.send_after(self(), :stall_check, check_interval)
  end

  defp now_ms, do: System.system_time(:millisecond)
end