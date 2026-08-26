defmodule Cympho.AgentRunner do
  @moduledoc """
  Spawns and manages Claude CLI sessions for issue processing.

  Uses Port to open a bash shell that runs the Claude CLI with JSON output,
  capturing stdout/stderr and forwarding progress to the caller via messages.

  Messages sent to recipient_pid:
    - `{:session_started, session_id}` — when the Claude process starts
    - `{:turn_completed, session_id, result}` — when a turn completes with parsed result
    - `{:tool_call_detected, session_id, tool_call}` — when a tool_use block is detected
    - `{:turn_ended_with_error, session_id, reason}` — when an error occurs
  """

  @stall_timeout Application.compile_env(:cympho, :agent_runner_stall_timeout, 300_000)
  # Absolute wall-clock cap independent of output drip. Stall timeout alone
  # resets on any stdout, so a slow drip can burn spend forever without this.
  @max_run_ms Application.compile_env(:cympho, :agent_runner_max_run_ms, 3_600_000)
  @max_output_bytes Application.compile_env(:cympho, :agent_runner_max_output_bytes, 8_000_000)
  @diagnostic_tail_bytes 8_192
  @fresh_turn_wake_reasons ~w(issue_commented issue_comment_mentioned)

  @doc """
  Runs a Claude CLI session for the given issue.

  Options:
    - `:resume` — pass true to continue a multi-turn session
    - `:cwd` — working directory for the Claude CLI (defaults to workspace path)
    - `:command` — CLI command to run (defaults to CYMPHO_CLAUDE_COMMAND or claude)
    - `:stall_timeout` — milliseconds of silence before killing hung process (default 300_000 / 5 min)
    - `:max_run_ms` — absolute wall-clock milliseconds for the whole run, even if
      output keeps dripping (default 3_600_000 / 1 hour). Also read from config.
    - `:max_output_bytes` — absolute stdout/stderr byte cap for the whole run
      (default 8_000_000). Also read from config.
  """
  def run(issue, agent_id, recipient_pid, opts \\ []) when is_pid(recipient_pid) do
    session_id = make_ref()
    config = option_value(opts, :config) || %{}
    cwd = option_value(opts, :cwd) || option_value(config, :cwd) || issue_workspace_path(issue)
    resume_decision = resume_decision(issue, cwd, resume_requested?(opts, config), opts)
    stall_timeout = resolve_positive_integer(opts, config, :stall_timeout, @stall_timeout)
    max_run_ms = resolve_positive_integer(opts, config, :max_run_ms, @max_run_ms)

    max_output_bytes = effective_max_output_bytes(opts, config)

    env = opts[:env] || runtime_context_env(opts[:runtime_context])

    cmd = build_claude_command(issue, agent_id, resume_decision, opts)

    _worker =
      Cympho.AdapterSessions.spawn_registered(session_id, opts, fn ->
        # Watch the orchestrator that owns this run. The graceful stop path goes
        # through Orchestrator.terminate/2 → AdapterSessions.cancel/2, but a
        # brutal kill (Process.exit/2, OOM, node shutdown) never runs it, and
        # every recovery path from there is a database write — nothing signals
        # this worker or its CLI child. Since the workspace path is derived from
        # the issue id, the next dispatch would then start a second CLI in the
        # same git checkout as the survivor.
        Process.monitor(recipient_pid)

        try do
          do_run(
            session_id,
            cmd,
            cwd,
            recipient_pid,
            stall_timeout,
            max_run_ms,
            max_output_bytes,
            env,
            opts
          )
        rescue
          exception ->
            # Every other adapter reports a crashing worker; this one did not.
            # `do_run/8` writes a prompt file and opens a port before it sends
            # anything, so an ENOSPC or EACCES there killed the worker silently.
            # The orchestrator keeps stamping run heartbeats, which hides the run
            # from the watchdog's stale scan, and its own dead-worker detector
            # only arms after it has seen the session registered on a tick 30s
            # later — so the issue sat :in_progress behind a live orchestrator
            # indefinitely.
            send(
              recipient_pid,
              {:turn_ended_with_error, session_id, {:adapter_crash, Exception.message(exception)}}
            )
        catch
          kind, reason ->
            send(
              recipient_pid,
              {:turn_ended_with_error, session_id, {:adapter_exit, kind, reason}}
            )
        after
          Cympho.AdapterSessions.unregister(session_id)
        end
      end)

    session_id
  end

  defp resolve_positive_integer(opts, config, key, default) do
    case option_value(opts, key) || option_value(config, key) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {n, ""} when n > 0 -> n
          _ -> default
        end

      _ ->
        default
    end
  end

  @doc false
  def effective_max_output_bytes(opts, config) do
    opts
    |> resolve_positive_integer(config, :max_output_bytes, @max_output_bytes)
    |> min(@max_output_bytes)
  end

  defp build_claude_command(issue, agent_id, resume_decision, opts) do
    command = cli_command(opts)

    base =
      ["-p", "--bare"] ++
        permission_args(issue) ++
        ["--output-format", "json"]

    prompt = build_prompt(issue, agent_id, opts)

    Cympho.PromptTelemetry.attach_to_run(
      opts,
      prompt,
      Map.merge(%{"adapter" => "claude_code"}, resume_telemetry(resume_decision))
    )

    args =
      if resume_decision.used do
        base ++ ["--resume"]
      else
        base
      end

    {command, args, prompt}
  end

  # Plan and Ask runs may inspect the checkout but must not change it. Claude's
  # plan permission mode enforces that at tool execution time; standard runs
  # remain unattended and writable under the existing bypass behavior.
  defp permission_args(issue) do
    if read_only_work_mode?(issue) do
      ["--permission-mode", "plan"]
    else
      ["--dangerously-skip-permissions"]
    end
  end

  defp read_only_work_mode?(%{work_mode: mode})
       when mode in [:planning, :ask, "planning", "ask"],
       do: true

  defp read_only_work_mode?(%{"work_mode" => mode})
       when mode in [:planning, :ask, "planning", "ask"],
       do: true

  defp read_only_work_mode?(_issue), do: false

  defp cli_command(opts) do
    config = option_value(opts, :config) || %{}

    option_value(opts, :command) ||
      option_value(config, :command) ||
      Application.get_env(:cympho, :claude_code_command) ||
      System.get_env("CYMPHO_CLAUDE_COMMAND") ||
      "claude"
  end

  defp option_value(opts, key) when is_list(opts) do
    Keyword.get(opts, key) ||
      case List.keyfind(opts, Atom.to_string(key), 0) do
        {_, value} -> value
        nil -> nil
      end
  end

  defp option_value(%{} = opts, key) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  defp option_value(_opts, _key), do: nil

  defp issue_workspace_path(issue), do: Cympho.Workspace.workspace_path(issue_id(issue))

  defp issue_id(%{id: id}) when not is_nil(id), do: to_string(id)
  defp issue_id(%{"id" => id}) when not is_nil(id), do: to_string(id)
  defp issue_id(issue) when is_map(issue), do: issue |> Map.get(:id) |> to_string()

  defp resume_requested?(opts, config) do
    truthy?(option_value(opts, :resume)) or truthy?(option_value(config, :resume))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false

  defp resume_decision(issue, cwd, false, _opts) do
    %{
      requested: false,
      used: false,
      reason: "fresh_per_run",
      cwd: cwd,
      issue_id: issue_id(issue)
    }
  end

  defp resume_decision(issue, cwd, true, opts) do
    issue_id = issue_id(issue)

    cond do
      fresh_turn_wake?(option_value(opts, :wake_context)) ->
        %{
          requested: true,
          used: false,
          reason: "comment_wake_fresh_turn",
          cwd: cwd,
          issue_id: issue_id
        }

      issue_scoped_cwd?(cwd, issue_id) ->
        %{
          requested: true,
          used: true,
          reason: "issue_scoped_workspace",
          cwd: cwd,
          issue_id: issue_id
        }

      true ->
        %{
          requested: true,
          used: false,
          reason: "shared_cwd_guard",
          cwd: cwd,
          issue_id: issue_id
        }
    end
  end

  defp fresh_turn_wake?({reason, _metadata}) when is_binary(reason),
    do: reason in @fresh_turn_wake_reasons

  defp fresh_turn_wake?(_wake_context), do: false

  defp issue_scoped_cwd?(cwd, issue_id) when is_binary(cwd) and is_binary(issue_id) do
    cwd = Path.expand(cwd)
    issue_workspace = issue_id |> Cympho.Workspace.workspace_path() |> Path.expand()

    cwd == issue_workspace or String.starts_with?(cwd, issue_workspace <> "/")
  end

  defp issue_scoped_cwd?(_cwd, _issue_id), do: false

  defp resume_telemetry(%{requested: requested, used: used, reason: reason}) do
    %{
      "session_resume_requested" => requested,
      "session_resume_used" => used,
      "session_resume_reason" => reason
    }
  end

  def build_prompt(issue, opts) when is_list(opts) do
    Cympho.AgentPrompt.build(issue, nil, opts)
  end

  def build_prompt(issue, agent_id, opts) when is_list(opts) do
    Cympho.AgentPrompt.build(issue, agent_id, opts)
  end

  defp do_run(
         session_id,
         {command, args, prompt},
         cwd,
         recipient_pid,
         stall_timeout,
         max_run_ms,
         max_output_bytes,
         runtime_env,
         opts
       ) do
    quoted = Enum.map([command | args], &shell_quote/1)
    pipe_limit = max_output_bytes + 1
    limiter = output_limiter_command(pipe_limit)

    anthropic_api_key =
      runtime_env["ANTHROPIC_API_KEY"] || runtime_env[:ANTHROPIC_API_KEY] || api_key()

    env = [{"ANTHROPIC_API_KEY", anthropic_api_key} | runtime_env(runtime_env) ++ env_whitelist()]

    Cympho.Adapters.ProcessAdapter.with_prompt_file(prompt, fn path ->
      port_opts_env = port_env([{"CYMPHO_PROMPT_FILE", path} | env])

      port =
        try do
          bash = String.to_charlist(System.find_executable("bash") || "/bin/bash")

          Port.open({:spawn_executable, bash}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            cd: cwd,
            args: [
              "-lc",
              "set -o pipefail; { source \"$HOME/.cld\" 2>/dev/null || true; exec " <>
                Enum.join(quoted, " ") <>
                " < \"$CYMPHO_PROMPT_FILE\"; } 2>&1 | " <>
                limiter <> " -c #{pipe_limit}; exit \"${PIPESTATUS[0]}\""
            ],
            env: port_opts_env
          ])
        rescue
          exception ->
            # A spawn failure (missing binary, bad cwd) must surface as a
            # failed run, not a silently dead worker the orchestrator waits on.
            send(
              recipient_pid,
              {:turn_ended_with_error, session_id, {:spawn_failed, Exception.message(exception)}}
            )

            exit(:normal)
        end

      case mark_local_process_started(session_id, opts) do
        :ok ->
          run_open_port(
            port,
            session_id,
            recipient_pid,
            stall_timeout,
            max_run_ms,
            max_output_bytes
          )

        {:error, :runtime_admission_start_failed} ->
          close_port(port)

          send(
            recipient_pid,
            {:turn_ended_with_error, session_id, :runtime_admission_start_failed}
          )
      end
    end)
  end

  defp run_open_port(
         port,
         session_id,
         recipient_pid,
         stall_timeout,
         max_run_ms,
         max_output_bytes
       ) do
    send(recipient_pid, {:session_started, session_id})

    started_at = System.system_time(:millisecond)
    port_monitor = :erlang.monitor(:port, port)

    # Wall-clock and stall deadlines use receive-after (not send_after) so a
    # flood of port output cannot starve the timer message. max_run_ms is
    # absolute from started_at and is NOT reset by drip output; stall only
    # tracks silence since last_output_time.
    outcome =
      try do
        loop(port, session_id, recipient_pid, stall_timeout, max_run_ms, %{
          started_at: started_at,
          last_output_time: started_at,
          max_output_bytes: max_output_bytes,
          bytes: 0,
          chunks: 0,
          last_report_at: nil,
          result: nil,
          buffer: "",
          diagnostic_tail: ""
        })
      after
        # A terminal adapter message must never race the local OS child. On
        # natural exit the port is already closed; on every other outcome
        # this synchronously closes/reaps the owned process tree first.
        close_port(port)
        Process.demonitor(port_monitor, [:flush])
      end

    send_terminal_outcome(recipient_pid, session_id, outcome)
  end

  defp loop(port, session_id, recipient_pid, stall_timeout, max_run_ms, state) do
    wait_ms = watchdog_wait_ms(state, stall_timeout, max_run_ms)

    receive do
      {^port, {:data, output}}
      when state.bytes + byte_size(output) > state.max_output_bytes ->
        diagnostic_tail = append_diagnostic_tail(state.diagnostic_tail, output)

        {:error, {:output_limit_exceeded, state.max_output_bytes, diagnostic_tail}}

      {^port, {:data, output}} ->
        buffer = state.buffer <> output

        state =
          %{
            state
            | last_output_time: System.system_time(:millisecond),
              buffer: buffer,
              diagnostic_tail: append_diagnostic_tail(state.diagnostic_tail, output),
              bytes: state.bytes + byte_size(output),
              chunks: state.chunks + 1
          }
          |> maybe_report_progress(session_id, recipient_pid)

        case {state.result, parse_json_output(buffer)} do
          {result, _parsed} when not is_nil(result) ->
            loop(port, session_id, recipient_pid, stall_timeout, max_run_ms, %{
              state
              | buffer: ""
            })

          {nil, {:ok, result}} ->
            case Cympho.Adapters.ProviderFailure.detect(result) do
              :ok ->
                # Extract and send tool calls if present
                extract_and_send_tool_calls(result, session_id, recipient_pid)

                loop(port, session_id, recipient_pid, stall_timeout, max_run_ms, %{
                  state
                  | result: result,
                    buffer: ""
                })

              {:error, reason} ->
                {:error, reason}
            end

          {nil, :continue} ->
            loop(port, session_id, recipient_pid, stall_timeout, max_run_ms, %{
              state
              | buffer: ""
            })

          {nil, :incomplete} ->
            # Looks like the head of a JSON document split across port
            # chunks — keep accumulating; exit_status settles the outcome.
            loop(port, session_id, recipient_pid, stall_timeout, max_run_ms, state)

          {nil, {:error, reason}} ->
            # This is the only terminal branch that used to return without
            # closing the port. The child is still running here — a shell
            # preamble on the first chunk lands in this branch milliseconds
            # after spawn — and an implicitly closed port leaves `claude
            # --dangerously-skip-permissions` alive in the issue workspace,
            # still billing and no longer tracked by anything.
            {:error, reason}
        end

      {^port, {:exit_status, 0}} ->
        # A clean exit that never produced a parseable turn is still a
        # failed run — the orchestrator would otherwise wait on a
        # turn_completed that never comes.
        cond do
          not is_nil(state.result) ->
            {:ok, state.result}

          String.trim(state.buffer) != "" ->
            {:error, {:parse_error, state.buffer}}

          true ->
            {:error, :no_output}
        end

      {^port, {:exit_status, code}} ->
        if is_nil(state.result), do: {:error, {:exit_code, code}}, else: {:ok, state.result}

      {:cancel_session, ^session_id, reason} ->
        {:error, {:cancelled, reason}}

      {:DOWN, _ref, :process, ^recipient_pid, _reason} ->
        # The orchestrator died without stopping us. There is nobody left to
        # report to, and leaving the CLI running would put a second writer in
        # this issue's workspace as soon as the run is re-dispatched.
        :owner_down
    after
      wait_ms ->
        now = System.system_time(:millisecond)

        cond do
          now - state.started_at >= max_run_ms ->
            {:error, :max_run_timeout}

          now - state.last_output_time >= stall_timeout ->
            {:error, :stall_timeout}

          true ->
            # Clock resolution edge: re-enter and recompute remaining wait.
            loop(port, session_id, recipient_pid, stall_timeout, max_run_ms, state)
        end
    end
  end

  defp send_terminal_outcome(recipient_pid, session_id, {:ok, result}) do
    send(recipient_pid, {:turn_completed, session_id, result})
  end

  defp send_terminal_outcome(recipient_pid, session_id, {:error, reason}) do
    send(recipient_pid, {:turn_ended_with_error, session_id, reason})
  end

  defp send_terminal_outcome(_recipient_pid, _session_id, :owner_down), do: :ok

  defp append_diagnostic_tail(_tail, output) when byte_size(output) >= @diagnostic_tail_bytes do
    output
    |> binary_part(byte_size(output) - @diagnostic_tail_bytes, @diagnostic_tail_bytes)
    |> :binary.copy()
  end

  defp append_diagnostic_tail(tail, output) do
    output_size = byte_size(output)
    retained_tail_size = min(byte_size(tail), @diagnostic_tail_bytes - output_size)

    binary_part(tail, byte_size(tail) - retained_tail_size, retained_tail_size) <> output
  end

  # Output is buffered until the process exits, so an owner watching an issue
  # saw nothing between "running" and a finished comment — for up to the full
  # wall-clock cap. Reporting byte and chunk counts as they arrive is
  # format-independent and cheap; the throttle keeps a chatty CLI from turning
  # every chunk into a PubSub broadcast.
  defp maybe_report_progress(state, session_id, recipient_pid) do
    now = System.system_time(:millisecond)
    interval = Application.get_env(:cympho, :adapter_progress_interval_ms, 1_000)

    if is_nil(state.last_report_at) or now - state.last_report_at >= interval do
      send(
        recipient_pid,
        {:turn_progress, session_id, %{bytes: state.bytes, chunks: state.chunks}}
      )

      %{state | last_report_at: now}
    else
      state
    end
  end

  defp close_port(port) when is_port(port) do
    Cympho.PortKiller.close_and_await(port)
  end

  defp mark_local_process_started(session_id, opts) do
    with :ok <- Cympho.AdapterSessions.local_process_started(session_id) do
      mark_runtime_local_process_started(opts)
    else
      _error -> {:error, :runtime_admission_start_failed}
    end
  end

  defp mark_runtime_local_process_started(opts) do
    case Keyword.get(opts, :runtime_admission_claim) do
      {token, server, _execution_class} when is_reference(token) ->
        mark_runtime_local_process_started(token, server)

      {token, server} when is_reference(token) ->
        mark_runtime_local_process_started(token, server)

      _none ->
        :ok
    end
  end

  defp mark_runtime_local_process_started(token, server) do
    case Cympho.RuntimeAdmission.local_process_started(token, server) do
      :ok -> :ok
      _error -> {:error, :runtime_admission_start_failed}
    end
  end

  defp shell_quote(token) do
    "'" <> String.replace(to_string(token), "'", "'\"'\"'") <> "'"
  end

  # `head -c` reads all requested bytes before it writes anything on common
  # platforms. That hides progress and turns the stall timer into a false
  # positive for every normal response below the cap. This relay uses
  # unbuffered syscalls, streams promptly, and closes its input after exactly
  # `limit` bytes so the child receives SIGPIPE before excess output can enter
  # the BEAM mailbox. Minimal systems without Perl fall back to byte-wise `dd`:
  # slower only for unusually large output, but still bounded and streaming.
  defp output_limiter_command(limit) do
    case System.find_executable("perl") do
      perl when is_binary(perl) ->
        program =
          "$r=shift; while($r>0){$w=$r<65536?$r:65536;" <>
            "$n=sysread(STDIN,$b,$w); last unless $n; $o=0;" <>
            "while($o<$n){$x=syswrite(STDOUT,$b,$n-$o,$o); exit 1 unless $x; $o+=$x;}" <>
            "$r-=$n;}"

        Enum.map_join([perl, "-e", program, Integer.to_string(limit)], " ", &shell_quote/1)

      _ ->
        dd = System.find_executable("dd") || "/bin/dd"
        "#{shell_quote(dd)} bs=1 count=#{limit} 2>/dev/null"
    end
  end

  # Nearest of absolute max-run and stall-silence deadlines. Zero means the
  # after clause fires immediately and classifies which budget was exhausted.
  defp watchdog_wait_ms(state, stall_timeout, max_run_ms) do
    now = System.system_time(:millisecond)
    remaining_max = max(state.started_at + max_run_ms - now, 0)
    remaining_stall = max(state.last_output_time + stall_timeout - now, 0)
    min(remaining_max, remaining_stall)
  end

  defp parse_json_output(output) do
    trimmed = String.trim(output)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "Thinking") ->
        :continue

      true ->
        case Jason.decode(trimmed) do
          {:ok, result} ->
            {:ok, result}

          {:error, _} ->
            case Cympho.Adapters.ProviderFailure.detect(trimmed) do
              # Provider failure text takes priority — surface it as-is.
              {:error, reason} ->
                {:error, reason}

              :ok ->
                # A JSON document head that doesn't decode yet is likely a
                # result split across port chunks — wait for the rest.
                if String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") do
                  :incomplete
                else
                  {:error, {:parse_error, output}}
                end
            end
        end
    end
  end

  defp api_key do
    Application.get_env(:cympho, :anthropic_api_key) || ""
  end

  defp env_whitelist do
    # Only pass these env vars to the subprocess for safety
    ["HOME", "PATH", "USER", "LOGNAME"]
    |> Enum.map(fn key -> {key, System.get_env(key)} end)
    |> Enum.reject(fn {_, val} -> is_nil(val) end)
  end

  defp runtime_context_env(%Cympho.RuntimeContext{env: env}) when is_map(env), do: env
  defp runtime_context_env(_), do: %{}

  defp runtime_env(env) when is_map(env) do
    Enum.flat_map(env, fn {key, value} ->
      key = to_string(key)

      cond do
        key == "ANTHROPIC_API_KEY" -> []
        is_nil(value) -> []
        true -> [{key, to_string(value)}]
      end
    end)
  end

  defp runtime_env(_env), do: []

  defp port_env(env) do
    env
    |> Enum.map(fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
    |> Cympho.Adapters.CodexAdapter.clean_port_env()
  end

  defp extract_and_send_tool_calls(result, session_id, recipient_pid) when is_map(result) do
    content = result["content"] || []

    Enum.each(content, fn item ->
      if item["type"] == "tool_use" do
        tool_call = %{
          "type" => "tool_use",
          "id" => item["id"],
          "name" => item["name"],
          "input" => item["input"],
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        send(recipient_pid, {:tool_call_detected, session_id, tool_call})
      end
    end)
  end

  defp extract_and_send_tool_calls(_result, _session_id, _recipient_pid), do: :ok
end
