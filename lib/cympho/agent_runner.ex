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
  @fresh_turn_wake_reasons ~w(issue_commented issue_comment_mentioned)

  @doc """
  Runs a Claude CLI session for the given issue.

  Options:
    - `:resume` — pass true to continue a multi-turn session
    - `:cwd` — working directory for the Claude CLI (defaults to workspace path)
    - `:command` — CLI command to run (defaults to CYMPHO_CLAUDE_COMMAND or claude)
    - `: stall_timeout` — milliseconds before killing hung process (default 300_000 / 5 min)
  """
  def run(issue, agent_id, recipient_pid, opts \\ []) when is_pid(recipient_pid) do
    session_id = make_ref()
    config = option_value(opts, :config) || %{}
    cwd = option_value(opts, :cwd) || option_value(config, :cwd) || issue_workspace_path(issue)
    resume_decision = resume_decision(issue, cwd, resume_requested?(opts, config), opts)
    stall_timeout = opts[:stall_timeout] || @stall_timeout
    env = opts[:env] || runtime_context_env(opts[:runtime_context])

    cmd = build_claude_command(issue, agent_id, resume_decision, opts)

    worker =
      spawn(fn ->
        try do
          do_run(session_id, cmd, cwd, recipient_pid, stall_timeout, env)
        after
          Cympho.AdapterSessions.unregister(session_id)
        end
      end)

    Cympho.AdapterSessions.register(session_id, worker)

    session_id
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

    # Build the full bash command with piped input
    bash_command(command, args, prompt)
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

  defp bash_command(command, claude_args, prompt) do
    claude_cmd = Enum.map_join([command | claude_args], " ", &shell_quote/1)
    cld_source = ~s(source "$HOME/.cld" 2>/dev/null || true)

    # Use heredoc to pass prompt safely without shell interpretation.
    # The single-quoted 'EOF' delimiter prevents variable expansion,
    # command substitution, and other shell interpretations.
    ~s(bash -lc '#{cld_source}; exec #{claude_cmd}' << 'PROMPT'\n#{prompt}\nPROMPT)
  end

  defp shell_quote(value) do
    value
    |> to_string()
    |> String.replace("'", "'\"'\"'")
  end

  def build_prompt(issue, opts) when is_list(opts) do
    Cympho.AgentPrompt.build(issue, nil, opts)
  end

  def build_prompt(issue, agent_id, opts) when is_list(opts) do
    Cympho.AgentPrompt.build(issue, agent_id, opts)
  end

  defp do_run(session_id, cmd, cwd, recipient_pid, stall_timeout, runtime_env) do
    anthropic_api_key =
      runtime_env["ANTHROPIC_API_KEY"] || runtime_env[:ANTHROPIC_API_KEY] || api_key()

    env = [{"ANTHROPIC_API_KEY", anthropic_api_key} | runtime_env(runtime_env) ++ env_whitelist()]

    port =
      try do
        Port.open({:spawn, cmd}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          cd: cwd,
          env: port_env(env)
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

    send(recipient_pid, {:session_started, session_id})

    # Arm the stall watchdog immediately. Without this first tick the
    # watchdog never fires and a hung adapter that produces no output at
    # all blocks the run forever. Seed last_output_time with "now" so
    # silence-from-the-start also counts as a stall.
    schedule_stall_check(stall_timeout)

    loop(port, session_id, recipient_pid, stall_timeout, %{
      last_output_time: System.system_time(:millisecond),
      turn_completed?: false,
      buffer: ""
    })
  end

  defp loop(port, session_id, recipient_pid, stall_timeout, state) do
    receive do
      {^port, {:data, output}} ->
        buffer = state.buffer <> output

        state = %{
          state
          | last_output_time: System.system_time(:millisecond),
            buffer: buffer
        }

        case parse_json_output(buffer) do
          {:ok, result} ->
            case Cympho.Adapters.ProviderFailure.detect(result) do
              :ok ->
                # Extract and send tool calls if present
                extract_and_send_tool_calls(result, session_id, recipient_pid)
                send(recipient_pid, {:turn_completed, session_id, result})

                loop(port, session_id, recipient_pid, stall_timeout, %{
                  state
                  | turn_completed?: true,
                    buffer: ""
                })

              {:error, reason} ->
                close_port(port)
                send(recipient_pid, {:turn_ended_with_error, session_id, reason})
            end

          :continue ->
            loop(port, session_id, recipient_pid, stall_timeout, %{state | buffer: ""})

          :incomplete ->
            # Looks like the head of a JSON document split across port
            # chunks — keep accumulating; exit_status settles the outcome.
            loop(port, session_id, recipient_pid, stall_timeout, state)

          {:error, reason} ->
            send(recipient_pid, {:turn_ended_with_error, session_id, reason})
        end

      {^port, {:exit_status, 0}} ->
        # A clean exit that never produced a parseable turn is still a
        # failed run — the orchestrator would otherwise wait on a
        # turn_completed that never comes.
        cond do
          state.turn_completed? ->
            :ok

          String.trim(state.buffer) != "" ->
            send(
              recipient_pid,
              {:turn_ended_with_error, session_id, {:parse_error, state.buffer}}
            )

          true ->
            send(recipient_pid, {:turn_ended_with_error, session_id, :no_output})
        end

      {^port, {:exit_status, code}} ->
        send(recipient_pid, {:turn_ended_with_error, session_id, {:exit_code, code}})

      :stall_check ->
        now = System.system_time(:millisecond)

        if now - state.last_output_time > stall_timeout do
          close_port(port)
          send(recipient_pid, {:turn_ended_with_error, session_id, :stall_timeout})
        else
          schedule_stall_check(stall_timeout)
          loop(port, session_id, recipient_pid, stall_timeout, state)
        end

      {:cancel_session, ^session_id, reason} ->
        close_port(port)
        send(recipient_pid, {:turn_ended_with_error, session_id, {:cancelled, reason}})
    end
  end

  defp close_port(port) when is_port(port) do
    Cympho.PortKiller.close(port)
  end

  defp schedule_stall_check(timeout) do
    # Check slightly more often than the timeout to catch edge cases
    check_interval = min(timeout, 30_000)
    Process.send_after(self(), :stall_check, check_interval)
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
    Application.get_env(:cympho, :anthropic_api_key) ||
      System.get_env("ANTHROPIC_API_KEY") ||
      ""
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
    Enum.map(env, fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
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
