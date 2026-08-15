defmodule Cympho.Adapters.ProcessAdapter do
  @moduledoc """
  Local process/CLI adapter.

  Runs agents as local subprocesses or CLI commands.
  """

  @behaviour Cympho.Adapters.Adapter

  alias Cympho.Adapters.RunDeadline
  alias Cympho.Adapters.RuntimeTimeout

  @default_timeout 300_000
  @max_timeout 3_600_000
  @utf8_replacement <<0xEF, 0xBF, 0xBD>>

  @impl true
  def run(issue, agent_id, recipient_pid, opts) when is_pid(recipient_pid) do
    session_id = make_ref()

    worker =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        # See Cympho.AgentRunner: a brutally killed orchestrator never runs its
        # cancel path, and every recovery step from there is a database write.
        # Without this the subprocess outlives its owner.
        Process.monitor(recipient_pid)

        try do
          do_run(session_id, issue, agent_id, recipient_pid, opts)
        rescue
          exception ->
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

    Cympho.AdapterSessions.register(session_id, worker)

    session_id
  end

  defp do_run(session_id, issue, agent_id, recipient_pid, opts) do
    config = runtime_config(opts[:config] || %{}, opts)

    case command(config) do
      command when command in [nil, ""] ->
        send(recipient_pid, {:turn_ended_with_error, session_id, :no_command})

      _command ->
        prompt = build_prompt(issue, agent_id, opts)
        Cympho.PromptTelemetry.attach_to_run(opts, prompt, %{"adapter" => "process"})

        case start_process(issue, agent_id, config, recipient_pid, session_id, prompt) do
          {:ok, _pid} ->
            # Process started successfully
            :ok

          {:error, reason} ->
            send(recipient_pid, {:turn_ended_with_error, session_id, reason})
        end
    end
  end

  defp start_process(issue, agent_id, config, recipient_pid, session_id, prompt) do
    command = command(config)

    if is_nil(command) or command == "" do
      {:error, :no_command}
    else
      args = build_args(issue, agent_id, config, prompt)
      env = build_env(issue, agent_id, config)
      cwd = config[:cwd] || config["cwd"]

      opts = [:binary, :exit_status, :use_stdio, :stderr_to_stdout]

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

      run_process(session_id, command, args, opts, recipient_pid, config, prompt)
      {:ok, self()}
    end
  end

  defp command(config), do: config[:command] || config["command"]

  defp build_prompt(issue, agent_id, opts) do
    Cympho.AgentPrompt.build(issue, agent_id,
      skills: Keyword.get(opts, :skills, []),
      runtime_context: Keyword.get(opts, :runtime_context),
      wake_context: Keyword.get(opts, :wake_context)
    )
  rescue
    _ ->
      issue
      |> Map.take([:id, :title, :description, :status, :priority])
      |> Jason.encode!()
  end

  defp build_args(_issue, _agent_id, config, prompt) do
    # Return configured args plus optional model/prompt forwarding args.
    args = config[:args] || config["args"] || []
    model = config[:model] || config["model"]

    args ++ model_args(config, model) ++ prompt_args(config, prompt)
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

  defp prompt_args(config, prompt) do
    case config[:prompt_arg_template] || config["prompt_arg_template"] do
      template when is_list(template) ->
        Enum.map(template, &String.replace(to_string(&1), "{{prompt}}", prompt))

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

    host_whitelist =
      ["HOME", "PATH", "USER", "LOGNAME"]
      |> Enum.map(fn key -> {key, System.get_env(key)} end)
      |> Enum.reject(fn {_, val} -> is_nil(val) end)

    # Convert to charlist format for Port.open
    (host_whitelist ++ base_env ++ custom_env_list)
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

  defp run_process(session_id, command, args, opts, recipient_pid, config, prompt) do
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
          with_command_port(command_path, args, opts, prompt, config, fn port ->
            timeout = RuntimeTimeout.resolve(config, default_ms: @default_timeout)
            wait_for_process(port, session_id, recipient_pid, timeout, <<>>)
          end)
        rescue
          e ->
            send(recipient_pid, {:turn_ended_with_error, session_id, inspect(e)})
        end
    end
  end

  defp with_command_port(command_path, args, opts, prompt, config, fun) do
    if write_prompt_stdin?(config) do
      with_prompt_file(prompt, fn prompt_path ->
        shell = System.find_executable("sh") || "/bin/sh"

        shell_args = [
          "-c",
          "exec \"$0\" \"$@\" < \"$CYMPHO_PROMPT_FILE\"",
          command_path | args
        ]

        port_opts =
          opts
          |> put_port_args(shell_args)
          |> put_port_env([{"CYMPHO_PROMPT_FILE", prompt_path}])

        port = Port.open({:spawn_executable, String.to_charlist(shell)}, port_opts)
        fun.(port)
      end)
    else
      port_opts =
        opts
        |> put_port_args(args)
        |> put_port_env([])

      port = Port.open({:spawn_executable, String.to_charlist(command_path)}, port_opts)
      fun.(port)
    end
  end

  defp write_prompt_stdin?(config) do
    case config[:prompt_stdin] || config["prompt_stdin"] do
      false -> false
      "false" -> false
      "0" -> false
      _ -> true
    end
  end

  defp resolve_command_path(command) do
    cond do
      String.starts_with?(command, "/") and File.exists?(command) -> command
      true -> System.find_executable(command)
    end
  end

  defp wait_for_process(port, session_id, recipient_pid, timeout, acc) when is_integer(timeout) do
    wait_for_process(port, session_id, recipient_pid, RunDeadline.new(timeout), acc)
  end

  defp wait_for_process(port, session_id, recipient_pid, %RunDeadline{} = deadline, acc) do
    receive do
      {^port, {:data, data}} ->
        wait_for_process(
          port,
          session_id,
          recipient_pid,
          RunDeadline.observe(deadline, data, session_id, recipient_pid),
          acc <> data
        )

      {:EXIT, ^port, _reason} ->
        wait_for_process(port, session_id, recipient_pid, deadline, acc)

      {^port, {:exit_status, 0}} ->
        output = normalize_output_utf8(acc)

        case Cympho.Adapters.ProviderFailure.detect(output) do
          :ok ->
            result = parse_output(output)
            send(recipient_pid, {:turn_completed, session_id, result})

          {:error, reason} ->
            send(recipient_pid, {:turn_ended_with_error, session_id, reason})
        end

      {^port, {:exit_status, code}} ->
        output = normalize_output_utf8(acc)
        send(recipient_pid, {:turn_ended_with_error, session_id, {:exit_code, code, output}})

      {:cancel_session, ^session_id, reason} ->
        send(recipient_pid, {:turn_ended_with_error, session_id, {:cancelled, reason}})
        close_port(port)

      {:DOWN, _ref, :process, ^recipient_pid, _reason} ->
        # Owner is gone; nobody to report to and no reason to keep the
        # subprocess writing into a workspace that is about to be re-dispatched.
        close_port(port)
    after
      RunDeadline.wait_ms(deadline) ->
        # The stall timer resets on every chunk, so a chatty subprocess would
        # otherwise hold its dispatch slot forever.
        case RunDeadline.expired(deadline) do
          nil ->
            wait_for_process(port, session_id, recipient_pid, deadline, acc)

          :max_run ->
            send(recipient_pid, {:turn_ended_with_error, session_id, :max_run_timeout})
            close_port(port)

          :stall ->
            send(recipient_pid, {:turn_ended_with_error, session_id, :timeout})
            close_port(port)
        end
    end
  end

  defp close_port(port) when is_port(port) do
    Cympho.PortKiller.close(port)
  end

  def with_prompt_file(prompt, fun) do
    path = Path.join(System.tmp_dir!(), "cympho-prompt-#{System.unique_integer([:positive])}.txt")
    File.write!(path, prompt <> "\n", [:binary])
    File.chmod!(path, 0o600)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end

  defp put_port_args(opts, args), do: replace_port_option(opts, :args, args)

  defp put_port_env(opts, additions) do
    existing = find_port_option(opts, :env, [])
    additions = Enum.map(additions, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)

    replace_port_option(
      opts,
      :env,
      Cympho.Adapters.CodexAdapter.clean_port_env(existing ++ additions)
    )
  end

  defp find_port_option(opts, key, default) do
    Enum.find_value(opts, default, fn
      {^key, value} -> value
      _ -> nil
    end)
  end

  defp replace_port_option(opts, key, value) do
    opts
    |> Enum.reject(&match?({^key, _}, &1))
    |> Kernel.++([{key, value}])
  end

  defp normalize_output_utf8(output) when is_binary(output) do
    if String.valid?(output) do
      output
    else
      replace_invalid_utf8(output)
    end
  end

  defp replace_invalid_utf8(output) do
    case :unicode.characters_to_binary(output, :utf8, :utf8) do
      valid when is_binary(valid) ->
        valid

      {:error, valid_prefix, rest} ->
        valid_prefix <> @utf8_replacement <> replace_invalid_utf8(drop_invalid_byte(rest))

      {:incomplete, valid_prefix, rest} ->
        valid_prefix <> @utf8_replacement <> replace_invalid_utf8(drop_invalid_byte(rest))
    end
  end

  defp drop_invalid_byte(<<_byte, rest::binary>>), do: rest
  defp drop_invalid_byte(_), do: <<>>

  defp parse_output(output) do
    trimmed = String.trim(output)

    case Jason.decode(trimmed) do
      {:ok, result} when is_map(result) ->
        result

      {:ok, other} ->
        %{output: other, raw: trimmed}

      {:error, _} ->
        parse_json_lines(trimmed)
    end
  end

  defp parse_json_lines(trimmed) do
    entries =
      trimmed
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&Jason.decode/1)

    if entries != [] and Enum.all?(entries, &match?({:ok, _}, &1)) do
      messages = Enum.map(entries, fn {:ok, entry} -> entry end)

      output =
        messages
        |> Enum.map(&message_text/1)
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n")

      %{
        output: if(output == "", do: trimmed, else: output),
        messages: messages,
        raw: trimmed
      }
    else
      %{output: trimmed, raw: trimmed}
    end
  end

  defp message_text(%{"text" => text}) when is_binary(text), do: text
  defp message_text(%{"content" => text}) when is_binary(text), do: text
  defp message_text(%{"message" => text}) when is_binary(text), do: text
  defp message_text(%{"result" => text}) when is_binary(text), do: text
  defp message_text(_), do: nil

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
        key: :prompt_arg_template,
        type: :list,
        required: false,
        default: [],
        description: "Argument template for prompt-based CLIs, e.g. [\"-p\", \"{{prompt}}\"]"
      },
      %{
        key: :prompt_stdin,
        type: :boolean,
        required: false,
        default: true,
        description: "Whether to send the generated prompt to stdin after process start"
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
        default: @default_timeout,
        description:
          "Process timeout in milliseconds. Prefer timeout_sec for human-entered values."
      },
      %{
        key: :timeout_sec,
        type: :integer,
        required: false,
        default: div(@default_timeout, 1_000),
        description: "Process timeout in seconds; conflicts with timeout/timeout_ms are rejected."
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
         :ok <- validate_args(config["prompt_arg_template"] || config[:prompt_arg_template]),
         :ok <- validate_boolean(config["prompt_stdin"] || config[:prompt_stdin], "prompt_stdin"),
         :ok <-
           validate_string(config["model_env_key"] || config[:model_env_key], "model_env_key"),
         :ok <- validate_timeout(config),
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

  defp validate_boolean(nil, _field), do: :ok
  defp validate_boolean(value, _field) when is_boolean(value), do: :ok
  defp validate_boolean("true", _field), do: :ok
  defp validate_boolean("false", _field), do: :ok
  defp validate_boolean(_value, field), do: {:error, "#{field} must be a boolean"}

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

  defp validate_timeout(config),
    do: RuntimeTimeout.validate(config, max_ms: @max_timeout, field: "timeout")

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
