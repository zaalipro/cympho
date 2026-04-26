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

  @doc """
  Runs a Claude CLI session for the given issue.

  Options:
    - `:resume` — pass true to continue a multi-turn session
    - `:cwd` — working directory for the Claude CLI (defaults to workspace path)
    - `: stall_timeout` — milliseconds before killing hung process (default 300_000 / 5 min)
  """
  def run(issue, agent_id, recipient_pid, opts \\ []) when is_pid(recipient_pid) do
    session_id = make_ref()
    cwd = opts[:cwd] || Cympho.Workspace.workspace_path(issue.id)
    resume? = opts[:resume] || false
    stall_timeout = opts[:stall_timeout] || @stall_timeout

    cmd = build_claude_command(issue, agent_id, resume?, opts)

    spawn(fn ->
      do_run(session_id, cmd, cwd, recipient_pid, stall_timeout)
    end)

    session_id
  end

  defp build_claude_command(issue, _agent_id, resume?, opts) do
    base = [
      "claude",
      "-p",
      "--bare",
      "--output-format",
      "json",
      "--no-input"
    ]

    prompt = build_prompt(issue, opts)

    args =
      if resume? do
        base ++ ["--resume"]
      else
        base
      end

    # Build the full bash command with piped input
    bash_command(args, prompt)
  end

  defp bash_command(claude_args, prompt) do
    claude_cmd = Enum.join(["claude" | claude_args], " ")

    # Use heredoc to pass prompt safely without shell interpretation.
    # The single-quoted 'EOF' delimiter prevents variable expansion,
    # command substitution, and other shell interpretations.
    ~s(bash -c '#{claude_cmd}' << 'PROMPT'\n#{prompt}\nPROMPT)
  end

  defp build_prompt(issue, opts \\ []) do
    skills = Keyword.get(opts, :skills, [])

    base_prompt = """
    Issue ID: #{issue.id}
    Title: #{issue.title}

    #{issue.description || "No description provided."}
    """

    if Enum.empty?(skills) do
      String.trim(base_prompt)
    else
      skills_block = build_skills_prompt_block(skills)
      """
      #{String.trim(base_prompt)}

      #{skills_block}
      """
      |> String.trim()
    end
  end

  defp build_skills_prompt_block(skills) when is_list(skills) do
    adapter = :claude_local

    skill_fragments =
      Enum.map(skills, fn skill ->
        Cympho.Skills.Adapter.skill_prompt_fragment(adapter, skill)
      end)

    """
    ## Available Skills

    The following skills are available for use in this session:
    #{Enum.join(skill_fragments, "\n")}
    """
    |> String.trim()
  end

  defp do_run(session_id, cmd, cwd, recipient_pid, stall_timeout) do
    env = [{"ANTHROPIC_API_KEY", api_key()} | env_whitelist()]

    port =
      Port.open({:spawn, cmd}, [
        :binary,
        :exit_status,
        cd: cwd,
        env: env
      ])

    send(recipient_pid, {:session_started, session_id})

    loop(port, session_id, recipient_pid, stall_timeout, nil)
  end

  defp loop(port, session_id, recipient_pid, stall_timeout, last_output_time) do
    receive do
      {port, {:data, output}} ->
        new_last_output = System.system_time(:millisecond)

        case parse_json_output(output) do
          {:ok, result} ->
            # Extract and send tool calls if present
            extract_and_send_tool_calls(result, session_id, recipient_pid)
            send(recipient_pid, {:turn_completed, session_id, result})
            loop(port, session_id, recipient_pid, stall_timeout, new_last_output)

          :continue ->
            loop(port, session_id, recipient_pid, stall_timeout, new_last_output)

          :error ->
            send(recipient_pid, {:turn_ended_with_error, session_id, {:parse_error, output}})
        end

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, code}} ->
        send(recipient_pid, {:turn_ended_with_error, session_id, {:exit_code, code}})

      :stall_check ->
        now = System.system_time(:millisecond)

        if last_output_time && now - last_output_time > stall_timeout do
          Port.close(port)
          send(recipient_pid, {:turn_ended_with_error, session_id, :stall_timeout})
        else
          schedule_stall_check(stall_timeout)
          loop(port, session_id, recipient_pid, stall_timeout, last_output_time)
        end
    end
  end

  defp schedule_stall_check(timeout) do
    # Check slightly more often than the timeout to catch edge cases
    check_interval = min(timeout, 30_000)
    Process.send_after(self(), :stall_check, check_interval)
  end

  defp parse_json_output(output) do
    trimmed = String.trim(output)

    if trimmed == "" or trimmed =~ ~r/^Thinking|$/ do
      :continue
    else
      case Jason.decode(trimmed) do
        {:ok, result} -> {:ok, result}
        {:error, _} -> :error
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
