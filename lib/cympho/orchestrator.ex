defmodule Cympho.Orchestrator do
  @moduledoc """
  Represents an active agent session for an issue.

  Receives AgentRunner Port messages and translates them into session lifecycle events,
  publishing results via PubSub for LiveView consumption.

  Session lifecycle:
    start_session -> session_started -> tool_call_detected (possibly multiple) -> turn_completed -> session_ended

  Each orchestrator instance is registered by issue_id and manages
  a single agent session, forwarding messages to the caller via messages
  from AgentRunner.

  Protocol:
    - Started by AgentHeartbeat via `start_and_run/2`
    - Calls AgentRunner.run/4 with self() as recipient_pid
    - Receives {:session_started, session_id}, {:tool_call_detected, session_id, tool_call},
      {:turn_completed, session_id, result}, {:turn_ended_with_error, session_id, reason} from AgentRunner
    - On completion: creates Comment, transitions issue, updates agent status
  """

  @enforce_keys [:issue, :agent_id]
  defstruct [
    :issue,
    :agent_id,
    :session_id,
    :run_id,
    :status,
    turn_count: 0,
    tool_traces: %{},
    opts: []
  ]

  use GenServer
  alias Cympho.{Issues, Comments, Agents, Activities, HeartbeatEngine, AgentAdapters}

  @heartbeat_tick_interval 30_000

  @registry Cympho.OrchestratorRegistry

  ## Client API

  @doc """
  Starts an orchestrator for the given issue and agent, runs the session immediately.
  Returns {:ok, pid} or {:error, reason}.
  """
  @spec start_and_run(map(), String.t()) :: {:ok, pid()} | {:error, atom()}
  def start_and_run(%{id: issue_id} = issue, agent_id, opts \\ []) when is_binary(agent_id) do
    case Registry.lookup(@registry, issue_id) do
      [{_pid, _}] ->
        {:error, :already_started}

      [] ->
        name = via_tuple(issue_id)

        case GenServer.start_link(__MODULE__, {issue, agent_id, opts}, name: name) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, _pid}} -> {:error, :already_started}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Looks up the orchestrator PID for a given issue.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(issue_id) do
    case Registry.lookup(@registry, issue_id) do
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
  @spec stop(String.t()) :: :ok
  def stop(issue_id) do
    case whereis(issue_id) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  @doc """
  Gets the current session state for a given issue.
  Returns nil if no orchestrator is running for the issue.
  """
  @spec get_session_state(String.t()) :: map() | nil
  def get_session_state(issue_id) do
    case whereis(issue_id) do
      nil ->
        nil

      pid ->
        try do
          GenServer.call(pid, :get_session_state, 5000)
        catch
          :exit, _ -> nil
        end
    end
  end

  defp via_tuple(issue_id) do
    {:via, Registry, {@registry, issue_id}}
  end

  @impl true
  def init({issue, agent_id, opts}) do
    session = %__MODULE__{issue: issue, agent_id: agent_id, opts: opts}
    session = create_pending_run(session, issue, agent_id)
    {:ok, session, {:continue, :start_session}}
  end

  @impl true
  def handle_continue(:start_session, %__MODULE__{} = session) do
    agent_map = build_agent_map(session)

    case AgentAdapters.resolve(agent_map) do
      {:ok, module, config} ->
        start_engine_run(session)
        schedule_heartbeat_tick()

        opts = run_opts(session, config)
        session_id = module.run(session.issue, session.agent_id, self(), opts)

        {:noreply, %{session | session_id: session_id}}

      {:error, error} ->
        handle_resolution_error(session, error)
    end
  end

  @impl true
  def handle_info({:session_started, session_id}, %__MODULE__{} = session) do
    {:noreply, %{session | session_id: session_id}}
  end

  @impl true
  def handle_info({:tool_call_detected, _session_id, tool_call}, %__MODULE__{} = session) do
    issue = session.issue
    agent_id = session.agent_id

    {updated_tool_traces, _trace_id} =
      capture_tool_call(tool_call, issue, agent_id, session.tool_traces)

    {:noreply, %{session | turn_count: session.turn_count + 1, tool_traces: updated_tool_traces}}
  end

  @impl true
  def handle_info({:turn_completed, _session_id, result}, %__MODULE__{} = session) do
    issue = session.issue
    agent_id = session.agent_id

    # Process tool results from the response
    updated_tool_traces = process_tool_results(result, session.tool_traces)

    complete_engine_run(%{session | tool_traces: updated_tool_traces}, result)

    body = extract_result_content(result)

    {:ok, _comment} =
      Comments.create_comment(%{
        body: body,
        author_type: "agent",
        author_id: agent_id,
        issue_id: issue.id
      })

    Issues.transition_issue(issue, :done)

    Activities.log_heartbeat_event(issue.id, :completed, %{
      agent_id: agent_id,
      turn_count: session.turn_count + 1
    })

    set_agent_idle(agent_id)
    reset_adapter_failure(agent_id)

    {:stop, :normal, session}
  end

  @impl true
  def handle_info({:turn_ended_with_error, _session_id, reason}, %__MODULE__{} = session) do
    issue = session.issue
    agent_id = session.agent_id

    :logger.warning(
      "[Orchestrator] Session ended with error for issue #{issue.id}, agent #{agent_id}: #{inspect(reason)}"
    )

    # Mark pending tool traces as errored/timed out
    mark_pending_traces_as_errored(session.tool_traces, reason)

    fail_engine_run(session, reason)

    error_body = "Agent work error: #{inspect(reason)}"

    {:ok, _comment} =
      Comments.create_comment(%{
        body: error_body,
        author_type: "agent",
        author_id: agent_id,
        issue_id: issue.id
      })

    case Issues.transition_issue(issue, :blocked) do
      {:ok, _} ->
        :logger.info("[Orchestrator] Issue #{issue.id} transitioned to :blocked after error")

      {:error, reason} ->
        :logger.error(
          "[Orchestrator] Failed to transition issue #{issue.id} to :blocked: #{inspect(reason)}"
        )
    end

    set_agent_idle(agent_id)

    {:stop, :normal, session}
  end

  @impl true
  def handle_info(:heartbeat_tick, %__MODULE__{run_id: run_id} = session) when run_id != nil do
    record_heartbeat(session)
    schedule_heartbeat_tick()
    {:noreply, session}
  end

  def handle_info(:heartbeat_tick, session) do
    {:noreply, session}
  end

  @impl true
  def handle_call(:get_session_state, _from, %__MODULE__{} = session) do
    {:reply,
     %{
       issue_id: session.issue.id,
       agent_id: session.agent_id,
       session_id: session.session_id,
       run_id: session.run_id,
       status: session.status,
       turn_count: session.turn_count
     }, session}
  end

  @impl true
  def terminate(reason, %__MODULE__{} = session) do
    send(Cympho.Orchestrator.Dispatcher, {:session_ended, session.issue.id, reason})

    _ =
      :logger.info(
        "[Orchestrator] terminated for issue #{session.issue.id}, agent #{session.agent_id}, reason: #{inspect(reason)}"
      )

    :ok
  end

  ## Private — HeartbeatEngine integration

  defp create_pending_run(session, issue, agent_id) do
    try do
      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent_id,
          issue_id: issue.id,
          adapter: "claude_local"
        })

      %{session | run_id: run.id}
    rescue
      e ->
        :logger.warning("[Orchestrator] Failed to create engine run: #{inspect(e)}")
        session
    end
  end

  defp start_engine_run(%__MODULE__{run_id: nil}), do: :ok

  defp start_engine_run(%__MODULE__{run_id: run_id}) do
    try do
      {:ok, run} = HeartbeatEngine.get_run(run_id)
      HeartbeatEngine.start_run(run)
    rescue
      e ->
        :logger.warning("[Orchestrator] Failed to start engine run: #{inspect(e)}")
    end
  end

  defp complete_engine_run(%__MODULE__{run_id: nil}, _result), do: :ok

  defp complete_engine_run(%__MODULE__{run_id: run_id}, result) do
    try do
      {:ok, run} = HeartbeatEngine.get_run(run_id)
      attrs = extract_run_attrs(result)
      HeartbeatEngine.complete_run(run, attrs)
    rescue
      e ->
        :logger.warning("[Orchestrator] Failed to complete engine run: #{inspect(e)}")
    end
  end

  defp fail_engine_run(%__MODULE__{run_id: nil}, _reason), do: :ok

  defp fail_engine_run(%__MODULE__{run_id: run_id}, reason) do
    try do
      {:ok, run} = HeartbeatEngine.get_run(run_id)
      HeartbeatEngine.fail_run(run, to_string(reason))
    rescue
      e ->
        :logger.warning("[Orchestrator] Failed to fail engine run: #{inspect(e)}")
    end
  end

  defp record_heartbeat(%__MODULE__{run_id: nil}), do: :ok

  defp record_heartbeat(%__MODULE__{run_id: run_id}) do
    try do
      {:ok, run} = HeartbeatEngine.get_run(run_id)
      HeartbeatEngine.record_heartbeat(run)
    rescue
      _ -> :ok
    end
  end

  defp extract_run_attrs(result) when is_map(result) do
    usage = result["usage"] || %{}

    %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      cost_usd: parse_cost(result["cost_usd"] || usage["cost_usd"])
    }
  end

  defp extract_run_attrs(_), do: %{input_tokens: 0, output_tokens: 0, cost_usd: Decimal.new("0")}

  defp parse_cost(nil), do: Decimal.new("0")
  defp parse_cost(val) when is_binary(val), do: Decimal.new(val)
  defp parse_cost(val), do: Decimal.new("#{val}")

  defp schedule_heartbeat_tick do
    Process.send_after(self(), :heartbeat_tick, @heartbeat_tick_interval)
  end

  ## Private — original helpers

  defp extract_result_content(result) when is_map(result) do
    content = result["content"] || []

    texts =
      content
      |> Enum.filter(fn item -> item["type"] == "text" end)
      |> Enum.map(fn item -> item["text"] end)
      |> Enum.join("\n\n")

    if texts == "",
      do: inspect(result),
      else: texts
  end

  defp extract_result_content(_), do: "No content returned"

  defp set_agent_idle(agent_id) do
    case Agents.get_agent(agent_id) do
      {:ok, agent} ->
        Agents.update_agent(agent, %{status: :idle})

      {:error, _} ->
        :error
    end
  end

  defp handle_adapter_error(session, {:unknown_adapter, adapter_type}) do
    issue = session.issue
    agent_id = session.agent_id

    error_body =
      "Adapter resolution failed: unknown adapter `#{adapter_type}`. Check agent configuration."

    {:ok, _} =
      Comments.create_comment(%{
        body: error_body,
        author_type: "agent",
        author_id: agent_id,
        issue_id: issue.id
      })

    Issues.transition_issue(issue, :blocked)
    set_agent_idle(agent_id)

    {:stop, :normal, session}
  end

  defp handle_adapter_error(session, reason) do
    issue = session.issue
    agent_id = session.agent_id

    :logger.error(
      "[Orchestrator] Adapter resolution failed for issue #{issue.id}: #{inspect(reason)}"
    )

    error_body = "Adapter resolution failed: #{inspect(reason)}"

    {:ok, _} =
      Comments.create_comment(%{
        body: error_body,
        author_type: "agent",
        author_id: agent_id,
        issue_id: issue.id
      })

    Issues.transition_issue(issue, :blocked)
    set_agent_idle(agent_id)

    {:stop, :normal, session}
  end

  defp process_tool_results(result, tool_traces) when is_map(result) do
    content = result["content"] || []

    Enum.reduce(content, tool_traces, fn item, acc_traces ->
      if item["type"] == "tool_result" do
        tool_use_id = item["tool_use_id"]
        result_content = item["content"] || ""
        is_error = item["is_error"] || false

        # Find and update the corresponding trace
        case Map.get(acc_traces, tool_use_id) do
          nil ->
            :logger.warning("[Orchestrator] No trace found for tool_result: #{tool_use_id}")
            acc_traces

          trace_id ->
            update_trace_with_result(trace_id, result_content, is_error, acc_traces)
        end
      else
        acc_traces
      end
    end)
  end

  defp process_tool_results(_result, tool_traces), do: tool_traces

  defp update_trace_with_result(trace_id, result_content, is_error, tool_traces) do
    case Cympho.ToolCallTraces.get_tool_call_trace(trace_id) do
      {:ok, trace} ->
        status = if is_error, do: "error", else: "success"

        case Cympho.ToolCallTraces.update_tool_call_trace_status(trace, status, result_content) do
          {:ok, _updated_trace} ->
            :logger.info(
              "[Orchestrator] Updated tool call trace: #{trace_id} with status: #{status}"
            )

            # Emit telemetry for tool completion
            :telemetry.execute(
              [:cympho, :tool, :complete],
              %{count: 1},
              %{
                tool_name: trace.tool_name,
                agent_id: trace.agent_id,
                issue_id: trace.issue_id,
                trace_id: trace_id,
                status: status,
                duration_ms: DateTime.diff(DateTime.utc_now(), trace.occurred_at, :millisecond)
              }
            )

            # Remove from pending traces map since it's now completed
            tool_use_id = Enum.find_value(tool_traces, fn {k, v} -> if v == trace_id, do: k end)
            Map.delete(tool_traces, tool_use_id)

          {:error, reason} ->
            :logger.warning("[Orchestrator] Failed to update tool call trace: #{inspect(reason)}")
            tool_traces
        end

      {:error, :not_found} ->
        :logger.warning("[Orchestrator] Trace not found: #{trace_id}")
        tool_traces
    end
  end

  defp mark_pending_traces_as_errored(tool_traces, reason) do
    Enum.each(tool_traces, fn {_tool_use_id, trace_id} ->
      case Cympho.ToolCallTraces.get_tool_call_trace(trace_id) do
        {:ok, trace} ->
          status = if reason == :stall_timeout, do: "timeout", else: "error"
          error_message = "Session error: #{inspect(reason)}"

          case Cympho.ToolCallTraces.update_tool_call_trace_status(trace, status, error_message) do
            {:ok, _updated_trace} ->
              :logger.info(
                "[Orchestrator] Marked pending tool call trace as errored: #{trace_id}"
              )

            {:error, update_reason} ->
              :logger.warning(
                "[Orchestrator] Failed to update errored tool call trace: #{inspect(update_reason)}"
              )
          end

        {:error, :not_found} ->
          :logger.warning("[Orchestrator] Trace not found for error marking: #{trace_id}")
      end
    end)
  end

  defp capture_tool_call(tool_call, issue, agent_id, tool_traces) do
    try do
      attrs = %{
        trace_type: "tool_invocation",
        tool_name: tool_call["name"],
        tool_arguments: tool_call["input"] || %{},
        status: "pending",
        company_id: issue.company_id,
        agent_id: agent_id,
        issue_id: issue.id,
        actor_type: "agent",
        actor_id: agent_id,
        occurred_at: DateTime.utc_now()
      }

      case Cympho.ToolCallTraces.create_tool_call_trace(attrs) do
        {:ok, trace} ->
          :logger.info("[Orchestrator] Captured tool call trace: #{trace.tool_name}")

          :telemetry.execute(
            [:cympho, :tool, :call],
            %{count: 1},
            %{
              tool_name: tool_call["name"],
              agent_id: agent_id,
              issue_id: issue.id,
              trace_id: trace.id
            }
          )

          # Store tool_use_id -> trace_id mapping for async result updates
          tool_use_id = tool_call["id"]
          updated_tool_traces = Map.put(tool_traces, tool_use_id, trace.id)

          {updated_tool_traces, trace.id}

        {:error, reason} ->
          :logger.warning("[Orchestrator] Failed to capture tool call trace: #{inspect(reason)}")
          {tool_traces, nil}
      end
    rescue
      e ->
        :logger.error("[Orchestrator] Error capturing tool call: #{inspect(e)}")
        {tool_traces, nil}
    end
  end

  defp build_agent_map(session) do
    %{
      adapter: Keyword.get(session.opts || [], :adapter),
      config: Keyword.get(session.opts || [], :adapter_config, %{})
    }
  end

  defp run_opts(session, config) do
    skills = Keyword.get(session.opts || [], :skills, [])
    [skills: skills, config: config]
  end

  defp handle_resolution_error(session, error) do
    handle_adapter_error(session, error)
  end

  defp reset_adapter_failure(_agent_id) do
    :ok
  end
end
