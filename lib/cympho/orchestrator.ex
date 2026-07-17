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
    :runtime_context,
    :status,
    :fallback_profile_ids,
    no_work_retry_count: 0,
    turn_count: 0,
    tool_traces: %{},
    fallback_errors: [],
    adapter_session_seen?: false,
    adapter_session_misses: 0,
    opts: []
  ]

  use GenServer
  require Logger

  import Ecto.Query, only: [from: 2]

  alias Cympho.{
    Adapters.Error,
    Issues,
    Comments,
    Agents,
    Activities,
    HeartbeatEngine,
    Adapters,
    AgentActions,
    IssueDigest,
    ReviewNudges,
    Runtime,
    WorkProducts,
    AuditTrail.Instrumenter
  }

  alias Cympho.Issues.Issue

  @heartbeat_tick_interval 30_000
  # Consecutive heartbeat ticks (30s apart) the adapter session may be
  # missing from AdapterSessions after having been seen, before we treat
  # the worker as dead. Two ticks tolerates a race with late registration
  # or a brief re-register between retries.
  @adapter_session_liveness_misses 2
  @adapter_failure_circuit_breaker_threshold 3
  @no_progress_circuit_breaker_threshold 3
  @completion_contract_blocker_keys MapSet.new([
                                      :agent_note,
                                      :owner_summary,
                                      :work_product,
                                      :delivery_comment,
                                      :review_decision,
                                      :ceo_owner_update,
                                      :code_reference
                                    ])

  @registry Cympho.OrchestratorRegistry
  @max_no_work_retries 1

  ## Client API

  @doc """
  Starts an orchestrator for the given issue and agent, runs the session immediately.
  Returns {:ok, pid} or {:error, reason}.
  """
  @spec start_and_run(map(), String.t()) :: {:ok, pid()} | {:error, atom()}
  def start_and_run(%{id: issue_id} = issue, agent_id, opts \\ []) when is_binary(agent_id) do
    # `GenServer.start/3` with a `:name` is itself the atomic gate via the
    # Registry — a redundant `Registry.lookup` before it creates a TOCTOU window
    # where a concurrent caller can win and we incorrectly report a permanent
    # `:already_started` (which the dispatcher then treats as a dispatch failure
    # and retries with backoff).
    #
    # Intentionally NOT linked to the caller: sessions are started by the
    # dispatcher, agent heartbeats, and LiveViews, and must survive any of
    # them going away (a closed browser tab must not abort an agent run, and
    # an orchestrator crash must not take down its caller). The dispatcher
    # monitors the returned pid for slot cleanup; the watchdog and boot-time
    # orphan recovery cover brutal kills.
    name = via_tuple(issue_id)

    case GenServer.start(__MODULE__, {issue, agent_id, opts}, name: name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Existing orchestrator is fine — caller can attach to it.
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
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
  @spec stop(String.t(), term()) :: :ok
  def stop(issue_id, reason \\ :normal) do
    case whereis(issue_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, reason)
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
    case prepare_runtime(session) do
      {:ok, module, config, runtime_context} ->
        {:noreply, start_runtime_session(session, module, config, runtime_context)}

      {:error, error} ->
        handle_preflight_or_resolution_error(session, error)
    end
  rescue
    exception ->
      # A crash while preparing the runtime must not strand the issue in
      # :in_progress with no follow-up — fail the run, leave an operator
      # comment, and park the issue instead of crash-looping every poll.
      Logger.error("[Orchestrator] runtime preparation crashed",
        issue_id: session.issue.id,
        agent_id: session.agent_id,
        error: Exception.message(exception)
      )

      handle_preflight_error(session, {:preflight_crashed, Exception.message(exception)})
  end

  # Stale adapter-session messages. After a provider fallback or no-work
  # retry the previous worker is gone, but a late message from it (or from
  # the liveness prod racing a real terminal message) must not be processed
  # as if it belonged to the current attempt — that would double-finalize
  # the run or trigger a second fallback.
  @impl true
  def handle_info({event, msg_session_id, _payload}, %__MODULE__{session_id: current} = session)
      when event in [:tool_call_detected, :turn_completed, :turn_ended_with_error] and
             not is_nil(current) and msg_session_id != current do
    Logger.warning("[Orchestrator] Ignoring message from stale adapter session",
      issue_id: session.issue.id,
      agent_id: session.agent_id,
      event: event
    )

    {:noreply, session}
  end

  @impl true
  def handle_info({:session_started, session_id}, %__MODULE__{session_id: current} = session)
      when not is_nil(current) and session_id != current do
    {:noreply, session}
  end

  def handle_info({:session_started, session_id}, %__MODULE__{} = session) do
    _ = Instrumenter.record_session_event(session, "started")
    {:noreply, %{session | session_id: session_id}}
  end

  @impl true
  def handle_info({:tool_call_detected, _session_id, tool_call}, %__MODULE__{} = session) do
    issue = session.issue
    agent_id = session.agent_id

    {updated_tool_traces, _trace_id} =
      capture_tool_call(tool_call, issue, agent_id, session.tool_traces)

    # Record tool call
    _ =
      Instrumenter.record_tool_call(
        session,
        tool_call["name"],
        tool_call["input"] || %{},
        "[in_progress]"
      )

    {:noreply, %{session | turn_count: session.turn_count + 1, tool_traces: updated_tool_traces}}
  end

  @impl true
  def handle_info({:turn_completed, _session_id, result}, %__MODULE__{} = session) do
    issue = session.issue
    agent_id = session.agent_id

    # Process tool results from the response
    updated_tool_traces = process_tool_results(result, session.tool_traces)

    # Record session completion
    _ =
      Instrumenter.record_session_event(session, "completed", %{
        "turn_count" => session.turn_count + 1
      })

    body = extract_result_content(result)

    create_agent_comment(issue, agent_id, body)

    action_result = handle_agent_actions(issue, agent_id, body)

    finalize_engine_run_for_action_result(
      %{session | tool_traces: updated_tool_traces},
      result,
      action_result
    )

    maybe_queue_completion_contract_nudge(issue, agent_id, action_result)

    case action_result do
      :ok ->
        Activities.log_heartbeat_event(issue.id, :completed, %{
          agent_id: agent_id,
          turn_count: session.turn_count + 1
        })

      {:error, reason} ->
        Activities.log_heartbeat_event(issue.id, :failed, %{
          agent_id: agent_id,
          turn_count: session.turn_count + 1,
          reason: inspect(reason)
        })
    end

    finalize_agent_after_completed_turn(issue, agent_id, action_result)
    reset_adapter_failure(agent_id)

    {:stop, :normal, session}
  rescue
    exception ->
      # An exception while processing a completed turn must still end in a
      # terminal outcome: fail the run, park the issue with an operator
      # comment, and free the agent — never crash and strand the issue.
      Logger.error("[Orchestrator] crashed while processing completed turn",
        issue_id: session.issue.id,
        agent_id: session.agent_id,
        error: Exception.message(exception)
      )

      fail_engine_run(session, {:turn_processing_crashed, Exception.message(exception)})

      message =
        "Cympho crashed while processing the agent's response (#{Exception.message(exception)})."

      # Only block if the crash left the issue mid-flight. If the agent's
      # actions already resolved it (handoff, review, done) before the
      # crash, blocking would undo legitimate progress.
      case Issues.get_issue(session.issue.id) do
        {:ok, %Issue{status: :in_progress} = latest} ->
          block_issue_with_comment(latest, message <> " Issue blocked for operator review.")

        _ ->
          create_system_comment(session.issue, message)
      end

      set_agent_idle(session.agent_id)
      {:stop, :normal, session}
  end

  @impl true
  def handle_info({:turn_ended_with_error, _session_id, reason}, %__MODULE__{} = session) do
    issue = session.issue
    agent_id = session.agent_id

    Logger.warning(
      "[Orchestrator] Session ended with error for issue #{issue.id}, agent #{agent_id}: #{inspect(reason)}"
    )

    # Mark pending tool traces as errored/timed out
    mark_pending_traces_as_errored(session.tool_traces, reason)

    fail_engine_run(session, reason)

    case maybe_start_provider_fallback(session, reason) do
      {:ok, fallback_session} ->
        {:noreply, fallback_session}

      :none ->
        case maybe_start_no_work_retry(session, reason) do
          {:ok, retry_session} ->
            {:noreply, retry_session}

          :none ->
            finish_failed_session(session, reason)
        end
    end
  rescue
    exception ->
      # Retry/fallback plumbing must not crash the failure path — that
      # would skip blocking the issue and leave it stuck in :in_progress.
      Logger.error("[Orchestrator] crashed while handling session error",
        issue_id: session.issue.id,
        agent_id: session.agent_id,
        error: Exception.message(exception)
      )

      finish_failed_session(session, reason)
  end

  @impl true
  def handle_info(:heartbeat_tick, %__MODULE__{run_id: run_id} = session) when run_id != nil do
    record_heartbeat(session)
    schedule_heartbeat_tick()

    case check_company_status(session) do
      :ok ->
        check_adapter_session_liveness(session)

      {:stop, :company_paused} ->
        Logger.warning(
          "[Orchestrator] Company paused during active session for issue #{session.issue.id}, stopping gracefully"
        )

        create_agent_comment(
          session.issue,
          session.agent_id,
          "Session stopped: company was paused. Issue released for re-dispatch when company resumes."
        )

        release_issue_after_adapter_error(session.issue)
        set_agent_idle(session.agent_id)

        # A shutdown-shaped reason (unlike :normal) makes terminate/2 cancel
        # the live adapter session and the engine run. Stopping :normal here
        # left the CLI process running and the run stuck in "running" until
        # the watchdog noticed.
        {:stop, {:shutdown, :company_paused}, session}
    end
  end

  def handle_info(:heartbeat_tick, session) do
    {:noreply, session}
  end

  def handle_info(msg, state) do
    issue_id =
      case state do
        %__MODULE__{issue: %{id: id}} -> id
        _ -> nil
      end

    Logger.warning(
      "[Orchestrator] Unexpected message (issue_id=#{inspect(issue_id)}): #{inspect(msg)}"
    )

    {:noreply, state}
  end

  # The orchestrator records a run heartbeat on every tick, which masks the
  # run from the watchdog's stale detection — so a dead adapter worker (one
  # that crashed without sending a terminal message) would keep this session
  # alive forever. Adapters register their worker with AdapterSessions for
  # the lifetime of the run; once we have seen the session registered, its
  # sustained disappearance without a terminal message means the worker died.
  # Route that through the normal error path so retries/fallbacks/blocking
  # apply.
  defp check_adapter_session_liveness(%__MODULE__{session_id: nil} = session),
    do: {:noreply, session}

  defp check_adapter_session_liveness(%__MODULE__{} = session) do
    registered? = adapter_session_registered?(session.session_id)

    cond do
      registered? ->
        {:noreply, %{session | adapter_session_seen?: true, adapter_session_misses: 0}}

      not session.adapter_session_seen? ->
        # Never observed registered — adapters like agrenting/mock don't
        # register, so absence is not evidence of death.
        {:noreply, session}

      session.adapter_session_misses + 1 < @adapter_session_liveness_misses ->
        {:noreply, %{session | adapter_session_misses: session.adapter_session_misses + 1}}

      true ->
        Logger.warning("[Orchestrator] adapter worker disappeared without a terminal message",
          issue_id: session.issue.id,
          agent_id: session.agent_id,
          component: "orchestrator"
        )

        send(self(), {:turn_ended_with_error, session.session_id, :adapter_worker_died})
        {:noreply, session}
    end
  end

  defp adapter_session_registered?(session_id) do
    Cympho.AdapterSessions.registered?(session_id)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp finish_failed_session(%__MODULE__{} = session, reason) do
    issue = session.issue
    agent_id = session.agent_id

    error_body = Error.comment(reason, adapter: session_adapter_name(session))

    # Best-effort comment: a comment failure must never prevent the issue
    # from being blocked and the agent from being released below.
    create_agent_comment(issue, agent_id, error_body)

    block_issue(issue)

    if provider_limit_failure?(reason) do
      pause_agent_for_provider_limit(agent_id, issue, reason)
    else
      set_agent_idle(agent_id)
    end

    {:stop, :normal, session}
  end

  @impl true
  def handle_cast(msg, state) do
    issue_id =
      case state do
        %__MODULE__{issue: %{id: id}} -> id
        _ -> nil
      end

    Logger.warning(
      "[Orchestrator] Unexpected cast (issue_id=#{inspect(issue_id)}): #{inspect(msg)}"
    )

    {:noreply, state}
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
    cancel_adapter_session(session.session_id, reason)
    finalize_active_run_on_shutdown(session, reason)

    if dispatcher = Process.whereis(Cympho.Orchestrator.Dispatcher) do
      send(dispatcher, {:session_ended, session.issue.id, reason})
    end

    _ =
      Logger.info(
        "[Orchestrator] terminated for issue #{session.issue.id}, agent #{session.agent_id}, reason: #{inspect(reason)}"
      )

    :ok
  end

  defp cancel_adapter_session(nil, _reason), do: :ok
  defp cancel_adapter_session(_session_id, :normal), do: :ok

  defp cancel_adapter_session(session_id, reason) do
    case Cympho.AdapterSessions.cancel(session_id, reason) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :not_started} -> :ok
    end
  end

  defp finalize_active_run_on_shutdown(%__MODULE__{run_id: nil}, _reason), do: :ok
  defp finalize_active_run_on_shutdown(%__MODULE__{}, :normal), do: :ok

  defp finalize_active_run_on_shutdown(%__MODULE__{} = session, reason) do
    with {:ok, run} <- HeartbeatEngine.get_run(session.run_id),
         true <- active_run_status?(Map.get(run, :status)) do
      result =
        if cancellation_shutdown_reason?(reason) do
          HeartbeatEngine.cancel_run(run)
        else
          HeartbeatEngine.fail_run(run, {:orchestrator_terminated, reason})
        end

      case result do
        {:ok, _updated} ->
          :ok

        {:error, error} ->
          Logger.warning(
            "[Orchestrator] failed to finalize run #{session.run_id} during shutdown: #{inspect(error)}"
          )
      end
    else
      _ -> :ok
    end
  rescue
    error ->
      Logger.warning(
        "[Orchestrator] failed to finalize run #{session.run_id} during shutdown: #{Exception.message(error)}"
      )
  end

  defp active_run_status?(status), do: status in ["pending", "queued", "running"]

  defp cancellation_shutdown_reason?(:shutdown), do: true
  defp cancellation_shutdown_reason?({:shutdown, _detail}), do: true
  defp cancellation_shutdown_reason?({:runtime_stop, _detail}), do: true
  defp cancellation_shutdown_reason?(:operator_stop), do: true
  defp cancellation_shutdown_reason?(:issue_terminal), do: true
  defp cancellation_shutdown_reason?(_reason), do: false

  ## Private — HeartbeatEngine integration

  defp create_pending_run(session, issue, agent_id, adapter_override \\ nil) do
    try do
      adapter =
        adapter_override ||
          case safe_get_agent(agent_id) do
            {:ok, agent} -> agent |> agent_adapter() |> adapter_name()
            {:error, _} -> "claude_code"
          end

      run_attrs = %{
        company_id: Map.get(issue, :company_id),
        agent_id: agent_id,
        issue_id: issue.id,
        adapter: adapter,
        invocation_source: Keyword.get(session.opts || [], :invocation_source, "heartbeat")
      }

      case HeartbeatEngine.create_run(run_attrs) do
        {:ok, run} ->
          %{session | run_id: run.id}

        {:error, reason} ->
          Logger.warning("[Orchestrator] Failed to create engine run: #{inspect(reason)}")
          session
      end
    rescue
      e ->
        Logger.warning("[Orchestrator] Failed to create engine run: #{inspect(e)}")
        session
    end
  end

  defp safe_get_agent(agent_id) do
    Agents.get_agent(agent_id)
  rescue
    _ -> {:error, :not_found}
  end

  defp agent_adapter(agent), do: Map.get(agent, :adapter)

  defp agent_config(agent) do
    Map.merge(Map.get(agent, :config, %{}) || %{}, Map.get(agent, :runtime_config, %{}) || %{})
  end

  defp adapter_name(nil), do: "claude_code"
  defp adapter_name(adapter), do: to_string(adapter)

  defp build_agent_map(session) do
    configured_adapter = Keyword.get(session.opts || [], :adapter)
    configured_adapter_config = Keyword.get(session.opts || [], :adapter_config)

    case safe_get_agent(session.agent_id) do
      {:ok, agent} ->
        %{
          adapter: configured_adapter || agent_adapter(agent),
          config: configured_adapter_config || agent_config(agent)
        }

      {:error, _} ->
        %{
          adapter: configured_adapter,
          config: configured_adapter_config || %{}
        }
    end
  end

  defp prepare_runtime(%__MODULE__{issue: %Issue{} = issue} = session) do
    case safe_get_agent(session.agent_id) do
      {:ok, %Cympho.Agents.Agent{} = agent} ->
        opts =
          session.opts
          |> Keyword.take([:adapter, :adapter_config, :skills, :cwd])
          |> Keyword.put(:run_id, session.run_id)

        case Runtime.preflight(issue, agent, opts) do
          {:ok, context} ->
            {:ok, context.adapter, context.adapter_config, context}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        prepare_legacy_runtime(session)
    end
  end

  defp prepare_runtime(%__MODULE__{} = session), do: prepare_legacy_runtime(session)

  defp prepare_runtime(%__MODULE__{issue: %Issue{} = issue} = session, profile)
       when is_map(profile) do
    case safe_get_agent(session.agent_id) do
      {:ok, %Cympho.Agents.Agent{} = agent} ->
        with {:ok, adapter} <- profile_adapter(profile) do
          opts =
            session.opts
            |> Keyword.take([:skills, :cwd])
            |> Keyword.put(:run_id, session.run_id)
            |> Keyword.put(:adapter, adapter)
            |> Keyword.put(:adapter_config, profile.config || %{})
            |> Keyword.put(:runtime_profile_id, profile.id)
            |> Keyword.put(:runtime_env, profile_env(profile))

          case Runtime.preflight(issue, agent, opts) do
            {:ok, context} -> {:ok, context.adapter, context.adapter_config, context}
            {:error, reason} -> {:error, reason}
          end
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp prepare_legacy_runtime(%__MODULE__{} = session) do
    agent_map = build_agent_map(session)

    case Adapters.resolve(agent_map) do
      {:ok, module, config} -> {:ok, module, config, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_opts(session, config, nil) do
    skills = Keyword.get(session.opts || [], :skills, [])
    [skills: skills, config: config, run_id: session.run_id]
  end

  defp run_opts(session, _config, %Cympho.RuntimeContext{} = context) do
    [
      run_id: session.run_id,
      skills: context.skills,
      config: context.adapter_config,
      cwd: context.cwd,
      env: context.env,
      runtime_context: context
    ]
  end

  defp start_runtime_session(session, module, config, runtime_context) do
    start_engine_run(session)
    wake_context = runtime_wake_context(session)

    if initial_runtime_attempt?(session) do
      consume_pending_wakes(session.agent_id, session.issue.id)
    end

    schedule_heartbeat_tick()

    opts =
      session
      |> run_opts(config, runtime_context)
      |> Keyword.put(:wake_context, wake_context)

    session_id = module.run(session.issue, session.agent_id, self(), opts)

    # Reset adapter-session liveness tracking for the new attempt — the new
    # adapter may not register with AdapterSessions at all (e.g. remote
    # marketplace adapters), and inheriting `seen?` from a previous adapter
    # would false-positive the dead-worker detector.
    %{
      session
      | session_id: session_id,
        runtime_context: runtime_context,
        adapter_session_seen?: false,
        adapter_session_misses: 0
    }
  end

  defp runtime_wake_context(%__MODULE__{no_work_retry_count: count}) when count > 0 do
    {"runtime_retry", %{"attempts" => count}}
  end

  defp runtime_wake_context(%__MODULE__{fallback_errors: []} = session) do
    # Snapshot the most-recent pending wake before consuming so we can surface
    # it to the agent's prompt as wake_context. Without this the agent only
    # sees the issue and has to infer "why am I being run."
    peek_pending_wake(session.agent_id, session.issue.id)
  end

  defp runtime_wake_context(%__MODULE__{fallback_errors: fallback_errors}) do
    {"runtime_fallback", %{"attempts" => length(fallback_errors)}}
  end

  defp initial_runtime_attempt?(%__MODULE__{fallback_errors: [], no_work_retry_count: 0}),
    do: true

  defp initial_runtime_attempt?(_session), do: false

  defp maybe_start_provider_fallback(%__MODULE__{} = session, reason) do
    if provider_fallback_failure?(reason) do
      session
      |> ensure_fallback_profile_ids()
      |> start_next_provider_fallback(reason)
    else
      :none
    end
  end

  defp ensure_fallback_profile_ids(%__MODULE__{fallback_profile_ids: ids} = session)
       when is_list(ids),
       do: session

  defp ensure_fallback_profile_ids(%__MODULE__{} = session) do
    ids =
      case safe_get_agent(session.agent_id) do
        {:ok, agent} -> Cympho.RuntimeProfiles.fallback_profile_ids(agent)
        {:error, _} -> []
      end

    %{session | fallback_profile_ids: ids}
  end

  defp start_next_provider_fallback(%__MODULE__{fallback_profile_ids: []}, _reason), do: :none

  defp start_next_provider_fallback(
         %__MODULE__{fallback_profile_ids: [profile_id | rest]} = session,
         reason
       ) do
    case Cympho.RuntimeProfiles.get(profile_id) do
      nil ->
        %{session | fallback_profile_ids: rest}
        |> start_next_provider_fallback(reason)

      profile ->
        attempt_session =
          session
          |> Map.put(:fallback_profile_ids, rest)
          |> Map.put(:fallback_errors, session.fallback_errors ++ [{profile_id, reason}])
          |> Map.put(:no_work_retry_count, 0)
          |> Map.put(:session_id, nil)
          |> Map.put(:tool_traces, %{})
          |> Map.put(:runtime_context, nil)
          |> create_pending_run(session.issue, session.agent_id, profile.adapter)

        case prepare_runtime(attempt_session, profile) do
          {:ok, module, config, runtime_context} ->
            create_agent_comment(
              session.issue,
              session.agent_id,
              "#{provider_fallback_label(reason)} on #{runtime_label(session)}; retrying with runtime profile #{profile.name} (`#{profile.id}`)."
            )

            {:ok, start_runtime_session(attempt_session, module, config, runtime_context)}

          {:error, fallback_error} ->
            fail_engine_run(
              attempt_session,
              {:fallback_preflight_failed, profile.id, fallback_error}
            )

            %{attempt_session | fallback_profile_ids: rest}
            |> start_next_provider_fallback(reason)
        end
    end
  end

  defp provider_limit_failure?({:provider_failure, category, _detail})
       when category in [:quota_exceeded, :rate_limited],
       do: true

  defp provider_limit_failure?({:http_error, 429, _detail}), do: true
  defp provider_limit_failure?(_reason), do: false

  defp provider_fallback_failure?(reason) do
    provider_limit_failure?(reason) or transient_provider_failure?(reason)
  end

  defp transient_provider_failure?({:provider_failure, :provider_unavailable, _detail}),
    do: true

  defp transient_provider_failure?({:http_error, status, _detail})
       when status in [500, 502, 503, 504, 529],
       do: true

  defp transient_provider_failure?(_reason), do: false

  defp provider_fallback_label(reason) do
    cond do
      provider_limit_failure?(reason) -> "Provider limit hit"
      transient_provider_failure?(reason) -> "Provider temporarily unavailable"
      true -> "Provider retry requested"
    end
  end

  defp pause_agent_for_provider_limit(agent_id, %Issue{} = issue, reason) do
    reason_text =
      "Provider circuit breaker paused this agent after #{provider_limit_label(reason)}. Fix credentials, quota, or fallback profiles, then resume the agent."

    {:ok, cancelled_wakes} = Cympho.Wakes.cancel_agent_wakes(agent_id, reason_text)

    case Agents.pause_agent(agent_id, reason_text) do
      {:ok, _agent} ->
        create_system_comment(
          issue,
          "Provider circuit breaker paused this agent and cancelled #{cancelled_wakes} queued #{pluralize(cancelled_wakes, "wake")} for this agent. #{reason_text}"
        )

      {:error, error} ->
        Logger.warning(
          "[Orchestrator] Failed to pause agent #{agent_id} after provider circuit breaker trip: #{inspect(error)}"
        )

        set_agent_error(agent_id)
    end
  end

  defp provider_limit_label({:provider_failure, :quota_exceeded, _detail}), do: "quota exhaustion"

  defp provider_limit_label({:provider_failure, :rate_limited, _detail}),
    do: "provider rate limiting"

  defp provider_limit_label({:http_error, 429, _detail}), do: "provider rate limiting"

  defp provider_limit_label(_reason), do: "provider limit failure"

  defp pluralize(1, noun), do: noun
  defp pluralize(_count, noun), do: noun <> "s"

  defp maybe_start_no_work_retry(%__MODULE__{} = session, reason) do
    if no_work_failure?(reason) and session.no_work_retry_count < @max_no_work_retries do
      attempt_session =
        session
        |> Map.put(:no_work_retry_count, session.no_work_retry_count + 1)
        |> Map.put(:session_id, nil)
        |> Map.put(:tool_traces, %{})
        |> Map.put(:runtime_context, nil)
        |> create_pending_run(session.issue, session.agent_id, session_adapter_name(session))

      case prepare_retry_runtime(attempt_session, session) do
        {:ok, module, config, runtime_context} ->
          create_agent_comment(
            session.issue,
            session.agent_id,
            "No usable adapter output from #{runtime_label(session)}; retrying once with the same runtime before blocking. Reason: #{format_no_work_reason(reason)}."
          )

          {:ok, start_runtime_session(attempt_session, module, config, runtime_context)}

        {:error, retry_error} ->
          fail_engine_run(attempt_session, {:runtime_retry_preflight_failed, retry_error})
          :none
      end
    else
      :none
    end
  end

  defp no_work_failure?(:no_output), do: true
  defp no_work_failure?({:parse_error, _detail}), do: true
  defp no_work_failure?(_reason), do: false

  defp prepare_retry_runtime(%__MODULE__{} = attempt_session, %__MODULE__{} = previous_session) do
    case previous_runtime_profile_id(previous_session) do
      profile_id when is_binary(profile_id) and profile_id != "" ->
        case Cympho.RuntimeProfiles.get(profile_id) do
          nil -> prepare_runtime(attempt_session)
          profile -> prepare_runtime(attempt_session, profile)
        end

      _ ->
        prepare_runtime(attempt_session)
    end
  end

  defp previous_runtime_profile_id(%__MODULE__{
         runtime_context: %Cympho.RuntimeContext{metadata: metadata}
       })
       when is_map(metadata) do
    Map.get(metadata, "runtime_profile_id") || Map.get(metadata, :runtime_profile_id)
  end

  defp previous_runtime_profile_id(_session), do: nil

  defp format_no_work_reason(:no_output), do: "no output"

  defp format_no_work_reason({:parse_error, detail}),
    do: "malformed adapter output (#{inspect(detail)})"

  defp format_no_work_reason(reason), do: inspect(reason)

  defp profile_adapter(%{adapter: adapter}) when is_binary(adapter) and adapter != "" do
    {:ok, String.to_existing_atom(adapter)}
  rescue
    ArgumentError -> {:error, {:unknown_adapter, adapter}}
  end

  defp profile_adapter(%{adapter: adapter}) when is_atom(adapter), do: {:ok, adapter}
  defp profile_adapter(_profile), do: {:error, :unknown_adapter}

  defp profile_env(%{runtime_config: runtime_config}) when is_map(runtime_config) do
    Map.get(runtime_config, "env") || Map.get(runtime_config, :env) || %{}
  end

  defp profile_env(_profile), do: %{}

  defp runtime_label(%__MODULE__{} = session) do
    case session_adapter_name(session) do
      nil -> "the current runtime"
      adapter -> adapter
    end
  end

  defp handle_preflight_or_resolution_error(session, error)
       when error in [:unknown_adapter, :no_adapter_available] or
              (is_tuple(error) and tuple_size(error) > 0 and elem(error, 0) == :config_invalid) do
    handle_resolution_error(session, error)
  end

  defp handle_preflight_or_resolution_error(session, error) do
    handle_preflight_error(session, error)
  end

  defp handle_resolution_error(session, error) do
    handle_adapter_error(session, error)
  end

  defp consume_pending_wakes(agent_id, issue_id) do
    Cympho.HeartbeatEngine.WakeupQueue.consume_for(agent_id, issue_id)
  rescue
    _ -> :ok
  end

  # Returns the most-recent pending wake for this agent+issue pair, or nil if
  # the agent was dispatched without an explicit wake (e.g. first poll). The
  # value is shaped as `{reason, metadata}` and consumed by AgentPrompt's
  # wake_context_block to render a "why you're running this turn" preamble.
  defp peek_pending_wake(agent_id, issue_id) do
    import Ecto.Query, only: [from: 2]
    alias Cympho.Wakes.AgentWake

    query =
      from(w in AgentWake,
        where:
          w.agent_id == ^agent_id and
            w.issue_id == ^issue_id and
            w.status == "pending",
        order_by: [desc: w.inserted_at],
        limit: 1
      )

    case Cympho.Repo.one(query) do
      nil -> nil
      %AgentWake{reason: reason, metadata: metadata} -> {reason, metadata || %{}}
    end
  rescue
    _ -> nil
  end

  defp handle_preflight_error(session, reason) do
    issue = session.issue
    agent_id = session.agent_id

    Logger.warning(
      "[Orchestrator] Runtime preflight failed for issue #{issue.id}: #{inspect(reason)}"
    )

    fail_engine_run(session, reason)

    create_agent_comment(
      issue,
      agent_id,
      "Runtime preflight failed: #{format_preflight_error(reason)}"
    )

    if retryable_preflight_error?(reason) do
      release_issue_after_adapter_error(issue)
    else
      block_issue(issue)
    end

    set_agent_idle(agent_id)

    {:stop, :normal, session}
  end

  defp retryable_preflight_error?(:company_paused), do: true
  defp retryable_preflight_error?({:agent_unavailable, _status}), do: true
  defp retryable_preflight_error?(_reason), do: false

  defp format_preflight_error({:agent_unavailable, status}),
    do: "agent is #{status}"

  defp format_preflight_error({:budget_blocked, info}),
    do:
      "budget policy #{info.policy_id} is exhausted for #{info.scope} scope in the #{info.period} period"

  defp format_preflight_error({:workspace_unavailable, cwd}),
    do: "workspace cwd is unavailable: #{cwd}"

  defp format_preflight_error({:workspace_error, reason}),
    do: "workspace setup failed: #{inspect(reason)}"

  defp format_preflight_error({:adapter_model_mismatch, message}), do: message

  defp format_preflight_error(:company_paused), do: "company is paused"

  defp format_preflight_error(:company_mismatch),
    do: "issue and agent belong to different companies"

  defp format_preflight_error(reason), do: inspect(reason)

  # Adapter failure counter is persisted on the agent row so the cap survives
  # process / node restarts. Race-safe via atomic SQL increment.

  defp finalize_agent_after_completed_turn(_issue, agent_id, :ok) do
    reset_no_progress_failure(agent_id)
    set_agent_idle(agent_id)
  end

  defp finalize_agent_after_completed_turn(issue, agent_id, {:error, :unresolved_current_issue}) do
    case record_no_progress_failure(agent_id) do
      {:ok, _count} ->
        set_agent_idle(agent_id)

      {:tripped, failure_count, cancelled_wakes} ->
        create_system_comment(
          issue,
          "No-progress circuit breaker paused this agent after #{failure_count} consecutive action-contract failures and cancelled #{cancelled_wakes} queued #{pluralize(cancelled_wakes, "wake")}. The agent kept producing non-resolving work; fix its instructions, runtime profile, or model choice, then resume it."
        )

      {:failed_to_trip, failure_count} ->
        create_system_comment(
          issue,
          "No-progress circuit breaker reached #{failure_count} consecutive action-contract failures, but Cympho could not pause the agent automatically. The agent was left in error state for operator repair."
        )
    end
  end

  defp finalize_agent_after_completed_turn(_issue, agent_id, {:error, _reason}) do
    set_agent_idle(agent_id)
  end

  defp reset_no_progress_failure(agent_id) do
    from(a in Cympho.Agents.Agent, where: a.id == ^agent_id)
    |> Cympho.Repo.update_all(set: [no_progress_failure_count: 0])

    :ok
  end

  defp record_no_progress_failure(agent_id) do
    from(a in Cympho.Agents.Agent, where: a.id == ^agent_id)
    |> Cympho.Repo.update_all(inc: [no_progress_failure_count: 1])

    new_count =
      Cympho.Repo.one(
        from(a in Cympho.Agents.Agent,
          where: a.id == ^agent_id,
          select: a.no_progress_failure_count
        )
      ) || 0

    if new_count >= @no_progress_circuit_breaker_threshold do
      case pause_agent_for_no_progress_circuit_breaker(agent_id, new_count) do
        {:ok, cancelled_wakes} -> {:tripped, new_count, cancelled_wakes}
        :error -> {:failed_to_trip, new_count}
      end
    else
      {:ok, new_count}
    end
  end

  defp pause_agent_for_no_progress_circuit_breaker(agent_id, failure_count) do
    reason =
      "No-progress circuit breaker paused this agent after #{failure_count} consecutive action-contract failures. Fix its instructions, runtime profile, or model choice, then resume the agent."

    cancelled_wakes =
      case Cympho.Wakes.cancel_agent_wakes(agent_id, reason) do
        {:ok, count} -> count
      end

    case Agents.pause_agent(agent_id, reason) do
      {:ok, _agent} ->
        reset_no_progress_failure(agent_id)
        {:ok, cancelled_wakes}

      {:error, error} ->
        Logger.warning(
          "[Orchestrator] Failed to pause agent #{agent_id} after no-progress circuit breaker trip: #{inspect(error)}"
        )

        set_agent_error(agent_id)
        :error
    end
  end

  defp reset_adapter_failure(agent_id) do
    from(a in Cympho.Agents.Agent, where: a.id == ^agent_id)
    |> Cympho.Repo.update_all(set: [adapter_failure_count: 0])

    :ok
  end

  defp record_adapter_failure(agent_id) do
    from(a in Cympho.Agents.Agent, where: a.id == ^agent_id)
    |> Cympho.Repo.update_all(inc: [adapter_failure_count: 1])

    new_count =
      Cympho.Repo.one(
        from(a in Cympho.Agents.Agent,
          where: a.id == ^agent_id,
          select: a.adapter_failure_count
        )
      ) || 0

    if new_count >= @adapter_failure_circuit_breaker_threshold do
      case pause_agent_for_adapter_circuit_breaker(agent_id, new_count) do
        :ok -> {:tripped, new_count}
        :error -> {:failed_to_trip, new_count}
      end
    else
      {:ok, new_count}
    end
  end

  defp pause_agent_for_adapter_circuit_breaker(agent_id, failure_count) do
    reason =
      "Adapter circuit breaker paused this agent after #{failure_count} consecutive adapter resolution failures. Fix the runtime/provider configuration, then resume the agent."

    case Agents.pause_agent(agent_id, reason) do
      {:ok, _agent} ->
        reset_adapter_failure(agent_id)
        :ok

      {:error, error} ->
        Logger.warning(
          "[Orchestrator] Failed to pause agent #{agent_id} after adapter circuit breaker trip: #{inspect(error)}"
        )

        set_agent_error(agent_id)
        :error
    end
  end

  defp start_engine_run(%__MODULE__{run_id: nil}), do: :ok

  defp start_engine_run(%__MODULE__{run_id: run_id}) do
    try do
      {:ok, run} = HeartbeatEngine.get_run(run_id)

      case HeartbeatEngine.start_run(run) do
        {:error, {:invalid_status, status}} ->
          # Lost CAS race: the run left "pending" before we could start it
          # (e.g. the watchdog recovered it, or a duplicate dispatch won). The
          # run did not start here; keep the session running so the adapter
          # attempt is not aborted on a benign race.
          Logger.warning("[Orchestrator] engine run already transitioned; not started here",
            component: "orchestrator",
            agent_id: Map.get(run, :agent_id),
            issue_id: Map.get(run, :issue_id),
            run_id: Map.get(run, :id),
            status: status
          )

        _ok_or_other ->
          :ok
      end
    rescue
      e ->
        Logger.warning("[Orchestrator] Failed to start engine run: #{inspect(e)}")
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
        Logger.warning("[Orchestrator] Failed to complete engine run: #{inspect(e)}")
    end
  end

  defp fail_engine_run(session, reason, usage_attrs \\ %{})

  defp fail_engine_run(%__MODULE__{run_id: nil}, _reason, _usage_attrs), do: :ok

  defp fail_engine_run(%__MODULE__{run_id: run_id}, reason, usage_attrs) do
    try do
      {:ok, run} = HeartbeatEngine.get_run(run_id)
      HeartbeatEngine.fail_run(run, reason, usage_attrs)
    rescue
      e ->
        Logger.warning("[Orchestrator] Failed to fail engine run: #{inspect(e)}")
    end
  end

  defp finalize_engine_run_for_action_result(%__MODULE__{} = session, result, :ok) do
    complete_engine_run(session, result)
  end

  defp finalize_engine_run_for_action_result(%__MODULE__{} = session, result, {:error, reason}) do
    fail_engine_run(session, {:agent_action_failed, reason}, extract_run_attrs(result))
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

  # The claude CLI json envelope reports usage as snake_case `usage` (with
  # cache_* token fields) plus per-model `modelUsage` (camelCase, carrying
  # `costUSD`), and cost as `total_cost_usd`. Read all shapes — without this
  # every run recorded $0 and budgets never saw real spend.
  defp extract_run_attrs(result) when is_map(result) do
    usage = result["usage"] || %{}
    model_usage = (result["modelUsage"] || %{}) |> Map.values()

    input_tokens =
      case sum_fields(usage, ~w(input_tokens cache_creation_input_tokens cache_read_input_tokens)) do
        0 -> sum_over(model_usage, ~w(inputTokens cacheCreationInputTokens cacheReadInputTokens))
        n -> n
      end

    output_tokens =
      case usage["output_tokens"] do
        n when is_integer(n) and n > 0 -> n
        _ -> sum_over(model_usage, ~w(outputTokens))
      end

    envelope_cost =
      parse_cost(result["total_cost_usd"] || result["cost_usd"] || usage["cost_usd"])

    cost =
      if Decimal.eq?(envelope_cost, 0) do
        Enum.reduce(model_usage, Decimal.new("0"), fn mu, acc ->
          Decimal.add(acc, parse_cost(mu["costUSD"]))
        end)
      else
        envelope_cost
      end

    %{input_tokens: input_tokens, output_tokens: output_tokens, cost_usd: cost}
  end

  defp extract_run_attrs(_), do: %{input_tokens: 0, output_tokens: 0, cost_usd: Decimal.new("0")}

  defp sum_fields(map, fields) do
    Enum.reduce(fields, 0, fn field, acc ->
      case map[field] do
        n when is_integer(n) -> acc + n
        _ -> acc
      end
    end)
  end

  defp sum_over(maps, fields) do
    Enum.reduce(maps, 0, fn map, acc -> acc + sum_fields(map, fields) end)
  end

  defp parse_cost(nil), do: Decimal.new("0")
  defp parse_cost(val) when is_binary(val), do: Decimal.new(val)
  defp parse_cost(val) when is_float(val), do: Decimal.from_float(val)
  defp parse_cost(val), do: Decimal.new("#{val}")

  defp session_adapter_name(%__MODULE__{run_id: run_id}) when not is_nil(run_id) do
    case HeartbeatEngine.get_run(run_id) do
      {:ok, run} -> run.adapter
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp session_adapter_name(_session), do: nil

  defp schedule_heartbeat_tick do
    Process.send_after(self(), :heartbeat_tick, @heartbeat_tick_interval)
  end

  defp check_company_status(%__MODULE__{issue: %Issue{company_id: nil}}), do: :ok

  defp check_company_status(%__MODULE__{issue: %Issue{company_id: company_id}}) do
    case Cympho.Companies.get_company!(company_id) do
      %{status: "active"} -> :ok
      _ -> {:stop, :company_paused}
    end
  rescue
    Ecto.NoResultsError -> {:stop, :company_paused}
  end

  ## Private — original helpers

  # The claude CLI's `--output-format json` envelope carries the agent's text
  # in "result"; the Messages-API shape carries a "content" block list. Falling
  # through to inspect/1 would escape the quotes/newlines inside the agent's
  # cympho-actions block, making it unparseable — so try both real shapes first.
  defp extract_result_content(%{"result" => text}) when is_binary(text) and text != "" do
    text
  end

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

  defp handle_agent_actions(issue, agent_id, body) do
    case AgentActions.parse(body) do
      {:ok, actions} ->
        handle_parsed_agent_actions(issue, agent_id, body, actions)

      {:error, reason} ->
        block_issue_with_comment(
          issue,
          "Agent response did not include a valid cympho-actions block: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp handle_parsed_agent_actions(issue, agent_id, body, actions) do
    case AgentActions.execute(issue, agent_id, actions) do
      {:ok, result} ->
        maybe_create_completion_handoff_comment(issue, agent_id, body, actions, result)

        if AgentActions.unresolved_current_issue?(issue, agent_id) do
          block_issue_with_comment(
            issue,
            "Agent actions did not resolve the current issue. Emit a resolving action: handoff, block_issue, submit_review, approve_issue, or swarm_worker_complete."
          )

          {:error, :unresolved_current_issue}
        else
          :ok
        end

      {:error, reason} ->
        block_issue_with_comment(
          issue,
          "Agent cympho-actions block parsed, but action execution failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp maybe_queue_completion_contract_nudge(issue, agent_id, :ok) do
    with {:ok, issue} <- Issues.get_issue(issue.id),
         false <- issue.status in [:blocked, :cancelled, :done],
         {:ok, agent} <- Agents.get_agent(agent_id) do
      runs = HeartbeatEngine.list_runs_for_issue(issue.id)
      work_products = WorkProducts.list_work_products(issue.id)
      child_issues = Issues.list_child_issues(issue.id)

      blockers =
        issue
        |> IssueDigest.build(runs, work_products, child_issues)
        |> get_in([:review_readiness, :blockers])
        |> List.wrap()
        |> Enum.filter(&MapSet.member?(@completion_contract_blocker_keys, &1.key))

      agents = completion_contract_agents(issue, agent)

      case preferred_completion_nudge(issue, blockers, agents, child_issues, agent_id) do
        nil ->
          :ok

        nudge ->
          case ReviewNudges.execute(issue, nudge.key,
                 blockers: blockers,
                 agents: agents,
                 child_issues: child_issues
               ) do
            {:ok, _queued} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[Orchestrator] Completion contract nudge failed for issue #{issue.id}: #{inspect(reason)}"
              )

              :ok
          end
      end
    else
      _ -> :ok
    end
  rescue
    exception ->
      Logger.warning(
        "[Orchestrator] Completion contract guard failed for issue #{issue.id}: #{Exception.message(exception)}"
      )

      :ok
  end

  defp maybe_queue_completion_contract_nudge(_issue, _agent_id, _action_result), do: :ok

  defp completion_contract_agents(issue, agent) do
    if issue.company_id do
      issue.company_id
      |> Agents.list_agents_by_company()
      |> case do
        [] -> [agent]
        agents -> agents
      end
    else
      [agent]
    end
  end

  defp preferred_completion_nudge(_issue, [], _agents, _child_issues, _agent_id), do: nil

  defp preferred_completion_nudge(issue, blockers, agents, child_issues, agent_id) do
    issue
    |> ReviewNudges.plan(blockers, agents: agents, child_issues: child_issues)
    |> Enum.reject(&(&1.queued? or not &1.enabled?))
    |> then(fn nudges ->
      Enum.find(nudges, &(&1.type == :delivery and &1.agent_id == agent_id)) ||
        Enum.find(nudges, &(&1.agent_id == agent_id)) ||
        Enum.find(nudges, &(&1.type == :delivery)) ||
        List.first(nudges)
    end)
  end

  defp maybe_create_completion_handoff_comment(issue, agent_id, body, actions, result) do
    cond do
      owner_visible_agent_note?(body) ->
        :ok

      Enum.any?(actions, &(&1["type"] == "comment")) ->
        :ok

      completion_body = generated_completion_comment(actions, result) ->
        create_agent_comment(issue, agent_id, completion_body)

      true ->
        :ok
    end
  end

  defp owner_visible_agent_note?(body) when is_binary(body) do
    Cympho.IssueDigest.comment_category(%{author_type: "agent", body: body}) != :routine
  end

  defp owner_visible_agent_note?(_body), do: false

  defp generated_completion_comment(actions, result) do
    types = Enum.map(actions, & &1["type"])

    cond do
      "attach_work_product" in types ->
        artifact_titles =
          actions
          |> Enum.filter(&(&1["type"] == "attach_work_product"))
          |> Enum.map(& &1["title"])
          |> Enum.reject(&(&1 in [nil, ""]))

        artifact_list =
          case artifact_titles do
            [] -> "attached work product evidence"
            titles -> Enum.join(titles, ", ")
          end

        issue_state =
          result
          |> Map.get(:issue, %{})
          |> Map.get(:status, :unknown)
          |> to_string()

        """
        [delivery] What happened: attached review evidence for this issue.
        Current state: issue is #{issue_state}; evidence is now available in work products.
        Evidence or verification: #{artifact_list}.
        Next decision: reviewer should inspect the artifact, then approve, request changes, or ask for more verification.
        """
        |> String.trim()

      true ->
        nil
    end
  end

  defp create_agent_comment(issue, agent_id, body) do
    case Comments.create_comment(%{
           body: body,
           author_type: "agent",
           author_id: agent_id,
           issue_id: issue.id
         }) do
      {:ok, _comment} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Orchestrator] Failed to create agent comment: #{inspect(reason)}")
    end
  end

  defp create_system_comment(issue, body) do
    case Comments.create_comment(%{
           body: body,
           author_type: "system",
           author_id: "00000000-0000-0000-0000-000000000000",
           issue_id: issue.id
         }) do
      {:ok, _comment} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Orchestrator] Failed to create system comment: #{inspect(reason)}")
    end
  end

  defp block_issue_with_comment(issue, reason) do
    _ =
      Comments.create_comment(%{
        body: reason,
        author_type: "system",
        author_id: "00000000-0000-0000-0000-000000000000",
        issue_id: issue.id
      })

    block_issue(issue)
  end

  @block_issue_attempts 3

  defp block_issue(issue, attempts_left \\ @block_issue_attempts)

  defp block_issue(%Issue{id: issue_id}, 0) do
    Logger.warning(
      "[Orchestrator] Gave up blocking issue #{issue_id} after #{@block_issue_attempts} stale-entry retries"
    )

    :ok
  end

  defp block_issue(%Issue{} = issue, attempts_left) do
    case Issues.get_issue(issue.id) do
      {:ok, latest_issue} ->
        do_block_issue(latest_issue, attempts_left)

      {:error, reason} ->
        Logger.warning(
          "[Orchestrator] Could not reload issue #{issue.id} before blocking: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp block_issue(issue, _attempts_left) do
    Issues.transition_issue(issue, :blocked)
  end

  defp do_block_issue(%Issue{} = issue, attempts_left) do
    case Issues.update_issue(issue, %{
           status: :blocked,
           assignee_id: nil,
           checkout_run_id: nil,
           checked_out_at: nil
         }) do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Orchestrator] Falling back to blocked transition for issue #{issue.id}: #{inspect(reason)}"
        )

        case Issues.transition_issue(issue, :blocked) do
          {:ok, _updated} ->
            :ok

          {:error, transition_reason} ->
            Logger.warning(
              "[Orchestrator] Failed to block issue #{issue.id}: #{inspect(transition_reason)}"
            )

            :ok
        end
    end
  rescue
    Ecto.StaleEntryError ->
      # Concurrent write bumped lock_version between our reload and update.
      # Refetch and retry (bounded) instead of leaving the issue un-parked.
      Logger.warning("[Orchestrator] Issue #{issue.id} changed while blocking, retrying")
      block_issue(%Issue{id: issue.id}, attempts_left - 1)
  end

  defp set_agent_idle(agent_id) do
    case safe_get_agent(agent_id) do
      {:ok, %{status: status}} when status in [:paused, :terminated, :pending_approval] ->
        # An operator (or a circuit breaker) parked this agent mid-run;
        # finishing the session must not silently resurrect it.
        :ok

      {:ok, agent} ->
        Agents.update_agent(agent, %{status: :idle})

      {:error, _} ->
        :error
    end
  end

  defp set_agent_error(agent_id) do
    case safe_get_agent(agent_id) do
      {:ok, agent} ->
        Agents.update_agent(agent, %{status: :error})

      {:error, _} ->
        :error
    end
  end

  defp handle_adapter_error(session, {:unknown_adapter, adapter_type}) do
    issue = session.issue
    agent_id = session.agent_id

    error_body =
      Error.comment({:unknown_adapter, adapter_type}, adapter: session_adapter_name(session))

    fail_engine_run(session, {:unknown_adapter, adapter_type})

    create_agent_comment(issue, agent_id, error_body)
    release_issue_after_adapter_error(issue)
    set_agent_idle(agent_id)

    {:stop, :normal, session}
  end

  defp handle_adapter_error(session, reason) do
    issue = session.issue
    agent_id = session.agent_id

    Logger.error(
      "[Orchestrator] Adapter resolution failed for issue #{issue.id}: #{inspect(reason)}"
    )

    error_body = Error.comment(reason, adapter: session_adapter_name(session))

    circuit_breaker =
      if reason == :no_adapter_available do
        record_adapter_failure(agent_id)
      else
        :not_applicable
      end

    fail_engine_run(session, reason)

    create_agent_comment(issue, agent_id, error_body)
    release_issue_after_adapter_error(issue)

    case circuit_breaker do
      {:tripped, failure_count} ->
        create_system_comment(
          issue,
          "Adapter circuit breaker paused this agent after #{failure_count} consecutive adapter resolution failures. Fix the runtime/provider configuration, then resume the agent."
        )

      {:failed_to_trip, failure_count} ->
        create_system_comment(
          issue,
          "Adapter circuit breaker reached #{failure_count} consecutive adapter resolution failures, but Cympho could not pause the agent automatically. The agent was left in error state for operator repair."
        )

      _ ->
        set_agent_idle(agent_id)
    end

    {:stop, :normal, session}
  end

  defp release_issue_after_adapter_error(%Issue{} = issue) do
    case Issues.force_release_issue(issue, :todo) do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Orchestrator] Failed to release issue after adapter error: #{inspect(reason)}"
        )
    end
  end

  defp release_issue_after_adapter_error(issue) do
    Issues.transition_issue(issue, :todo)
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
            Logger.warning("[Orchestrator] No trace found for tool_result: #{tool_use_id}")
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
            Logger.info(
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
            Logger.warning("[Orchestrator] Failed to update tool call trace: #{inspect(reason)}")
            tool_traces
        end

      {:error, :not_found} ->
        Logger.warning("[Orchestrator] Trace not found: #{trace_id}")
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
              Logger.info("[Orchestrator] Marked pending tool call trace as errored: #{trace_id}")

            {:error, update_reason} ->
              Logger.warning(
                "[Orchestrator] Failed to update errored tool call trace: #{inspect(update_reason)}"
              )
          end

        {:error, :not_found} ->
          Logger.warning("[Orchestrator] Trace not found for error marking: #{trace_id}")
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
          Logger.info("[Orchestrator] Captured tool call trace: #{trace.tool_name}")

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
          Logger.warning("[Orchestrator] Failed to capture tool call trace: #{inspect(reason)}")
          {tool_traces, nil}
      end
    rescue
      e ->
        Logger.error("[Orchestrator] Error capturing tool call: #{inspect(e)}")
        {tool_traces, nil}
    end
  end
end
