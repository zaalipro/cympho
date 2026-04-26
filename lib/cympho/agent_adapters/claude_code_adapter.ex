defmodule Cympho.AgentAdapters.ClaudeCodeAdapter do
  @moduledoc """
  Adapter for Anthropic Claude Code CLI.

  Spawns and manages Claude CLI sessions using Port, parsing JSON output and
  forwarding progress to the caller via the standard message protocol.

  Implements `Cympho.AgentAdapters.Adapter`.
  """

  @behaviour Cympho.AgentAdapters.Adapter

  @stall_timeout Application.compile_env(:cympho, :agent_runner_stall_timeout, 300_000)

  @impl true
  def type, do: :claude_code

  @impl true
  def available?(config \\ %{}) do
    claude_in_path?() and api_key_present?(config)
  end

  @impl true
  def health_check(config \\ %{}) do
    cond do
      not claude_in_path?() ->
        %{status: :unhealthy, message: "Claude CLI not found in PATH", checked_at: DateTime.utc_now()}

      not api_key_present?(config) ->
        %{status: :unhealthy, message: "ANTHROPIC_API_KEY not set", checked_at: DateTime.utc_now()}

      true ->
        case System.cmd("claude", ["--version"], stderr_to_stdout: true) do
          {_output, 0} ->
            %{status: :healthy, message: "Claude CLI operational", checked_at: DateTime.utc_now()}

          {output, code} ->
            %{
              status: :degraded,
              message: "claude --version exited with code #{code}: #{String.slice(output, 0, 100)}",
              checked_at: DateTime.utc_now()
            }
        end
    end
  end

  @impl true
  def validate_config(config) when is_map(config) do
    with :ok <- validate_stall_timeout(config[:stall_timeout]),
         :ok <- validate_cwd(config[:cwd]),
         :ok <- validate_resume(config[:resume]) do
      :ok
    end
  end

  def validate_config(config) when is_list(config) do
    validate_config(Map.new(config))
  end

  @impl true
  def run(issue, agent_id, recipient_pid, opts \\ []) when is_pid(recipient_pid) do
    session_id = make_ref()
    cwd = opts[:cwd] || Cympho.Workspace.workspace_path(issue.id)
    resume? = opts[:resume] || false
    stall_timeout = opts[:stall_timeout] || @stall_timeout

    cmd = build_claude_command(issue, agent_id, resume?)

    spawn(fn ->
      do_run(session_id, cmd, cwd, recipient_pid, stall_timeout)
    end)

    session_id
  end

  ## Private — availability helpers

  defp claude_in_path? do
    case System.cmd("which", ["claude"]) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp api_key_present?(config) when is_map(config) do
    config_key = config[:api_key] || config["api_key"]
    api_key(config_key) != ""
  end

  defp api_key_present?(_), do: api_key(nil) != ""

  defp api_key(nil) do
    Application.get_env(:cympho, :anthropic_api_key) ||
      System.get_env("ANTHROPIC_API_KEY") ||
      ""
  end

  defp api_key(key) when is_binary(key) and key != "", do: key

  ## Private — config validation

  defp validate_stall_timeout(nil), do: :ok

  defp validate_stall_timeout(timeout) when is_integer(timeout) and timeout > 0 do
    if timeout > 3_600_000 do
      {:error, "stall_timeout must be less than 1 hour (3600000ms)"}
    else
      :ok
    end
  end

  defp validate_stall_timeout(_), do: {:error, "stall_timeout must be a positive integer"}

  defp validate_cwd(nil), do: :ok

  defp validate_cwd(path) when is_binary(path) do
    if File.dir?(path), do: :ok, else: {:error, "cwd must be a valid directory path"}
  end

  defp validate_cwd(_), do: {:error, "cwd must be a string"}

  defp validate_resume(nil), do: :ok
  defp validate_resume(true), do: :ok
  defp validate_resume(false), do: :ok
  defp validate_resume(_), do: {:error, "resume must be a boolean"}

  ## Private — command building

  defp build_claude_command(issue, _agent_id, resume?) do
    base = [
      "claude",
      "-p",
      "--bare",
      "--output-format",
      "json",
      "--no-input"
    ]

    prompt = build_prompt(issue)

    args =
      if resume? do
        base ++ ["--resume"]
      else
        base
      end

    bash_command(args, prompt)
  end

  defp bash_command(claude_args, prompt) do
    claude_cmd = Enum.join(["claude" | claude_args], " ")
    ~s(bash -c '#{claude_cmd}' << 'PROMPT'\n#{prompt}\nPROMPT)
  end

  defp build_prompt(issue) do
    """
    Issue ID: #{issue.id}
    Title: #{issue.title}

    #{issue.description || "No description provided."}
    """
    |> String.trim()
  end

  ## Private — Port execution

  defp do_run(session_id, cmd, cwd, recipient_pid, stall_timeout) do
    env = [{"ANTHROPIC_API_KEY", api_key(nil)} | env_whitelist()]

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

  defp env_whitelist do
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
