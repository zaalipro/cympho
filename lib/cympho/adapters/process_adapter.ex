defmodule Cympho.Adapters.ProcessAdapter do
  @moduledoc """
  Local process/CLI adapter.

  Runs agents as local subprocesses or CLI commands.
  """

  @behaviour Cympho.Adapters.Adapter

  @impl true
  def run(issue, agent_id, recipient_pid, opts) when is_pid(recipient_pid) do
    session_id = make_ref()

    spawn(fn ->
      do_run(session_id, issue, agent_id, recipient_pid, opts)
    end)

    session_id
  end

  defp do_run(session_id, issue, agent_id, recipient_pid, opts) do
    config = opts[:config] || %{}

    case start_process(issue, agent_id, config, recipient_pid, session_id) do
      {:ok, _pid} ->
        # Process started successfully
        :ok

      {:error, reason} ->
        send(recipient_pid, {:turn_ended_with_error, session_id, reason})
    end
  end

  defp start_process(issue, agent_id, config, recipient_pid, session_id) do
    command = config[:command] || config["command"]

    if is_nil(command) or command == "" do
      {:error, :no_command}
    else
      args = build_args(issue, agent_id, config)
      env = build_env(config)
      cwd = config[:cwd] || config["cwd"]

      opts = [:binary, :exit_status]

      opts =
        if cwd do
          opts ++ [cd: cwd]
        else
          opts
        end

      opts =
        if env != [] do
          opts ++ [env: env]
        else
          opts
        end

      spawn(fn ->
        run_process(session_id, command, args, opts, recipient_pid, config)
      end)

      {:ok, session_id}
    end
  end

  defp build_args(issue, agent_id, config) do
    base_args = [
      issue.id,
      agent_id,
      issue.title || ""
    ]

    extra_args = config[:args] || config["args"] || []

    base_args ++ extra_args
  end

  defp build_env(config) do
    base_env = [
      {"ISSUE_ID", config[:issue_id] || config["issue_id"]},
      {"AGENT_ID", config[:agent_id] || config["agent_id"]},
      {"ISSUE_TITLE", config[:issue_title] || config["issue_title"] || ""}
    ]

    custom_env = config[:env] || config["env"] || %{}

    custom_env_list =
      Enum.map(custom_env, fn {k, v} ->
        {to_string(k), to_string(v)}
      end)

    (base_env ++ custom_env_list)
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
  end

  defp run_process(session_id, command, args, opts, recipient_pid, config) do
    send(recipient_pid, {:session_started, session_id})

    # Build the full command
    full_cmd = build_full_command(command, args)

    port = Port.open({:spawn, full_cmd}, opts)

    timeout = config[:timeout] || config["timeout"] || 300_000

    wait_for_process(port, session_id, recipient_pid, timeout, <<>>)
  end

  defp build_full_command(command, args) do
    # Escape arguments properly for shell
    escaped_args = Enum.map(args, fn arg -> escape_shell_arg(arg) end)
    "#{command} #{Enum.join(escaped_args, " ")}"
  end

  defp escape_shell_arg(arg) when is_binary(arg) do
    # Simple shell escaping - wrap in single quotes and escape single quotes
    escaped = String.replace(arg, "'", "'\\''")
    "'#{escaped}'"
  end

  defp escape_shell_arg(arg), do: escape_shell_arg(to_string(arg))

  defp wait_for_process(port, session_id, recipient_pid, timeout, acc) do
    receive do
      {port, {:data, data}} ->
        wait_for_process(port, session_id, recipient_pid, timeout, acc <> data)

      {port, {:exit_status, 0}} ->
        result = parse_output(acc)
        send(recipient_pid, {:turn_completed, session_id, result})

      {port, {:exit_status, code}} ->
        send(recipient_pid, {:turn_ended_with_error, session_id, {:exit_code, code, acc}})

      after
        timeout ->
          Port.close(port)
          send(recipient_pid, {:turn_ended_with_error, session_id, :timeout})
    end
  end

  defp parse_output(output) do
    trimmed = String.trim(output)

    case Jason.decode(trimmed) do
      {:ok, result} when is_map(result) ->
        result

      {:ok, other} ->
        %{output: other, raw: trimmed}

      {:error, _} ->
        %{output: trimmed, raw: trimmed}
    end
  end

  @impl true
  def health_check(config) do
    command = config[:command] || config["command"]

    cond do
      is_nil(command) or command == "" ->
        %{status: :unhealthy, message: "No command configured", checked_at: DateTime.utc_now()}

      true ->
        # Check if command exists
        case System.cmd("which", [command]) do
          {_, 0} ->
            %{status: :healthy, message: "Command available", checked_at: DateTime.utc_now()}

          _ ->
            %{status: :degraded, message: "Command not found in PATH", checked_at: DateTime.utc_now()}
        end
    end
  end

  @impl true
  def config_schema do
    [
      %{
        key: :command,
        type: :string,
        required: true,
        default: nil,
        description: "Command to execute"
      },
      %{
        key: :args,
        type: :list,
        required: false,
        default: [],
        description: "Additional command arguments"
      },
      %{
        key: :cwd,
        type: :string,
        required: false,
        default: nil,
        description: "Working directory"
      },
      %{
        key: :timeout,
        type: :integer,
        required: false,
        default: 300_000,
        description: "Process timeout in milliseconds"
      },
      %{
        key: :env,
        type: :map,
        required: false,
        default: %{},
        description: "Additional environment variables"
      }
    ]
  end

  @impl true
  def name, do: "Local Process"

  @impl true
  def available? do
    # Process adapter is always available on Unix-like systems
    true
  end

  @impl true
  def validate_config(config) do
    with :ok <- validate_command(config["command"] || config[:command]),
         :ok <- validate_args(config["args"] || config[:args]),
         :ok <- validate_cwd(config["cwd"] || config[:cwd]),
         :ok <- validate_timeout(config["timeout"] || config[:timeout]),
         :ok <- validate_env(config["env"] || config[:env]) do
      :ok
    end
  end

  defp validate_command(nil), do: {:error, "command is required"}
  defp validate_command(""), do: {:error, "command cannot be empty"}
  defp validate_command(cmd) when is_binary(cmd), do: :ok
  defp validate_command(_), do: {:error, "command must be a string"}

  defp validate_args(nil), do: :ok

  defp validate_args(args) when is_list(args) do
    if Enum.all?(args, &is_binary/1) do
      :ok
    else
      {:error, "args must be a list of strings"}
    end
  end

  defp validate_args(_), do: {:error, "args must be a list"}

  defp validate_cwd(nil), do: :ok

  defp validate_cwd(path) when is_binary(path) do
    if File.dir?(path) do
      :ok
    else
      {:error, "cwd must be a valid directory path"}
    end
  end

  defp validate_cwd(_), do: {:error, "cwd must be a string"}

  defp validate_timeout(nil), do: :ok

  defp validate_timeout(timeout) when is_integer(timeout) do
    if timeout > 0 and timeout <= 3_600_000 do
      :ok
    else
      {:error, "timeout must be between 1 and 3600000 milliseconds"}
    end
  end

  defp validate_timeout(_), do: {:error, "timeout must be an integer"}

  defp validate_env(nil), do: :ok

  defp validate_env(env) when is_map(env) do
    if Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      :ok
    else
      {:error, "env must be a map with string keys and values"}
    end
  end

  defp validate_env(_), do: {:error, "env must be a map"}
end
