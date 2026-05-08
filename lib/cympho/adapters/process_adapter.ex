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
    config = runtime_config(opts[:config] || %{}, opts)

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
      env = build_env(issue, agent_id, config)
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

      # Spawn a long-lived process to manage the port and handle its messages
      spawn_link(fn ->
        run_process(session_id, command, args, opts, recipient_pid, config)
      end)

      {:ok, self()}
    end
  end

  defp build_args(_issue, _agent_id, config) do
    # Return configured args plus optional model forwarding args.
    args = config[:args] || config["args"] || []
    model = config[:model] || config["model"]

    args ++ model_args(config, model)
  end

  defp model_args(_config, model) when model in [nil, ""], do: []

  defp model_args(config, model) do
    case config[:model_arg_template] || config["model_arg_template"] do
      template when is_list(template) ->
        Enum.map(template, &String.replace(to_string(&1), "{{model}}", to_string(model)))

      _ ->
        []
    end
  end

  defp build_env(issue, agent_id, config) do
    # Encode issue payload as JSON for the subprocess
    issue_json =
      Jason.encode!(%{
        id: issue.id,
        title: issue.title,
        description: Map.get(issue, :description),
        status: Map.get(issue, :status),
        priority: Map.get(issue, :priority),
        agent_id: agent_id
      })

    base_env = [
      {"ISSUE_PAYLOAD", issue_json},
      {"ISSUE_ID", to_string(issue.id)},
      {"AGENT_ID", to_string(agent_id)}
    ]

    custom_env = config[:env] || config["env"] || %{}
    model_env = model_env(config)

    custom_env_list =
      Map.merge(custom_env, model_env)
      |> Enum.map(fn {k, v} ->
        {to_string(k), to_string(v)}
      end)

    # Convert to charlist format for Port.open
    (base_env ++ custom_env_list)
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp runtime_config(config, opts) do
    runtime_env = Keyword.get(opts, :env, %{}) || runtime_context_env(opts[:runtime_context])
    cwd = opts[:cwd] || config[:cwd] || config["cwd"]
    configured_env = config[:env] || config["env"] || %{}

    config
    |> Map.delete(:env)
    |> Map.delete("env")
    |> Map.put_new("cwd", cwd)
    |> Map.put("env", Map.merge(configured_env, runtime_env))
  end

  defp runtime_context_env(%Cympho.RuntimeContext{env: env}) when is_map(env), do: env
  defp runtime_context_env(_), do: %{}

  defp model_env(config) do
    model = config[:model] || config["model"]
    key = config[:model_env_key] || config["model_env_key"]

    if model in [nil, ""] or key in [nil, ""] do
      %{}
    else
      %{to_string(key) => to_string(model)}
    end
  end

  defp run_process(session_id, command, args, opts, recipient_pid, config) do
    send(recipient_pid, {:session_started, session_id})

    # Use spawn_executable with explicit args to avoid shell injection
    # Resolve command to full path (Port.open requires absolute path)
    resolved_command = resolve_command_path(command)

    case resolved_command do
      nil ->
        send(
          recipient_pid,
          {:turn_ended_with_error, session_id, "command not found: #{command}"}
        )

      command_path ->
        try do
          command_charlist = String.to_charlist(command_path)
          opts_with_args = opts ++ [{:args, args}]
          port = Port.open({:spawn_executable, command_charlist}, opts_with_args)
          timeout = config[:timeout] || config["timeout"] || 300_000
          wait_for_process(port, session_id, recipient_pid, timeout, <<>>)
        rescue
          e ->
            send(recipient_pid, {:turn_ended_with_error, session_id, inspect(e)})
        end
    end
  end

  defp resolve_command_path(command) do
    cond do
      String.starts_with?(command, "/") and File.exists?(command) -> command
      true -> System.find_executable(command)
    end
  end

  defp wait_for_process(port, session_id, recipient_pid, timeout, acc) do
    receive do
      {port, {:data, data}} ->
        wait_for_process(port, session_id, recipient_pid, timeout, acc <> data)

      {^port, {:exit_status, 0}} ->
        result = parse_output(acc)
        send(recipient_pid, {:turn_completed, session_id, result})

      {^port, {:exit_status, code}} ->
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
        # First check if command exists in PATH
        case System.cmd("which", [command], stderr_to_stdout: true) do
          {_, 0} ->
            # Command exists, try running it with --health-check flag
            run_health_check_command(command, config)

          _ ->
            %{
              status: :degraded,
              message: "Command not found in PATH",
              checked_at: DateTime.utc_now()
            }
        end
    end
  end

  defp run_health_check_command(command, config) do
    args = config[:args] || config["args"] || []
    health_check_args = args ++ ["--health-check"]

    try do
      case System.cmd(command, health_check_args,
             stderr_to_stdout: true,
             cd: config[:cwd] || config["cwd"]
           ) do
        {_, 0} ->
          %{
            status: :healthy,
            message: "Command available and healthy",
            checked_at: DateTime.utc_now()
          }

        {_output, _code} ->
          # Command doesn't support --health-check, but it exists, so return healthy
          %{
            status: :healthy,
            message: "Command available (no health check)",
            checked_at: DateTime.utc_now()
          }
      end
    rescue
      _ ->
        # If System.cmd fails entirely (e.g., command not executable), still return healthy since we confirmed it exists
        %{
          status: :healthy,
          message: "Command available (no health check)",
          checked_at: DateTime.utc_now()
        }
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
        key: :process_preset,
        type: :string,
        required: false,
        default: Cympho.Adapters.RuntimeOptions.process_default_preset(),
        options: Cympho.Adapters.RuntimeOptions.process_preset_options(),
        description: "Known CLI runtime preset"
      },
      %{
        key: :provider,
        type: :string,
        required: false,
        default: nil,
        options: Cympho.Adapters.RuntimeOptions.process_provider_options(),
        description: "Provider family used by the command"
      },
      %{
        key: :model,
        type: :string,
        required: false,
        default: nil,
        description: "Model to forward through args or env when configured"
      },
      %{
        key: :model_arg_template,
        type: :list,
        required: false,
        default: [],
        description: "Argument template, e.g. [\"--model\", \"{{model}}\"]"
      },
      %{
        key: :model_env_key,
        type: :string,
        required: false,
        default: nil,
        description: "Environment variable name used to pass the model"
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
  def type, do: :process

  @impl true
  def available? do
    # Process adapter is always available on Unix-like systems
    true
  end

  @impl true
  def available?(config) do
    command = config[:command] || config["command"]

    if is_nil(command) or command == "" do
      false
    else
      # Check if command exists in PATH
      case System.cmd("which", [command], stderr_to_stdout: true) do
        {_, 0} -> true
        _ -> false
      end
    end
  end

  @impl true
  def validate_config(config) do
    with :ok <- validate_command(config["command"] || config[:command]),
         :ok <- validate_args(config["args"] || config[:args]),
         :ok <- validate_cwd(config["cwd"] || config[:cwd]),
         :ok <-
           validate_string(config["process_preset"] || config[:process_preset], "process_preset"),
         :ok <- validate_string(config["provider"] || config[:provider], "provider"),
         :ok <- validate_string(config["model"] || config[:model], "model"),
         :ok <- validate_args(config["model_arg_template"] || config[:model_arg_template]),
         :ok <-
           validate_string(config["model_env_key"] || config[:model_env_key], "model_env_key"),
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

  defp validate_string(nil, _field), do: :ok
  defp validate_string("", _field), do: :ok
  defp validate_string(value, _field) when is_binary(value), do: :ok
  defp validate_string(_value, field), do: {:error, "#{field} must be a string"}

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
