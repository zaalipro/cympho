defmodule Cympho.Adapters.CursorAdapter do
  @moduledoc """
  Adapter for Cursor IDE CLI.

  Spawns Cursor's CLI agent process in non-interactive mode. Newer Cursor
  installs expose the `agent` entrypoint, while `cursor-agent` and older
  `cursor` binaries remain supported as fallbacks.
  """

  @behaviour Cympho.Adapters.Adapter

  @impl true
  def execution_class, do: :local_process

  alias Cympho.Adapters.RunDeadline
  alias Cympho.Adapters.RuntimeTimeout

  @default_timeout 300_000
  @max_timeout 3_600_000

  @impl true
  def run(issue, agent_id, recipient_pid, opts) when is_pid(recipient_pid) do
    session_id = make_ref()
    config = opts[:config] || %{}

    _worker =
      Cympho.AdapterSessions.spawn_registered(session_id, opts, fn ->
        # See Cympho.AgentRunner: a brutally killed orchestrator never runs its
        # cancel path, so without this the CLI outlives its owner.
        Process.monitor(recipient_pid)

        try do
          do_run(session_id, issue, agent_id, recipient_pid, config, opts)
        rescue
          _exception ->
            send(
              recipient_pid,
              {:turn_ended_with_error, session_id, {:adapter_crash, :cursor_adapter_failed}}
            )
        catch
          _kind, _reason ->
            send(
              recipient_pid,
              {:turn_ended_with_error, session_id, {:adapter_exit, :cursor_adapter_failed}}
            )
        after
          Cympho.AdapterSessions.unregister(session_id)
        end
      end)

    session_id
  end

  defp do_run(session_id, issue, agent_id, recipient_pid, config, opts) do
    prompt = build_prompt(issue, agent_id, opts)
    Cympho.PromptTelemetry.attach_to_run(opts, prompt, %{"adapter" => "cursor"})

    case run_cursor(session_id, prompt, config, opts, recipient_pid) do
      {:ok, output} ->
        send(recipient_pid, {:turn_completed, session_id, output})

      {:error, reason} ->
        send(recipient_pid, {:turn_ended_with_error, session_id, reason})
    end
  end

  defp build_prompt(issue, agent_id, opts) do
    Cympho.AgentPrompt.build(issue, agent_id,
      skills: Keyword.get(opts, :skills, []),
      runtime_context: Keyword.get(opts, :runtime_context),
      wake_context: Keyword.get(opts, :wake_context)
    )
  rescue
    _ ->
      fallback_prompt(issue, agent_id)
  end

  defp fallback_prompt(issue, agent_id) do
    id = (is_map(issue) && Map.get(issue, :id)) || Map.get(issue, "id") || issue.id
    title = (is_map(issue) && Map.get(issue, :title)) || Map.get(issue, "title") || issue.title

    description =
      (is_map(issue) && Map.get(issue, :description)) || Map.get(issue, "description") ||
        issue.description

    """
    You are agent #{agent_id} working on the following issue:

    Issue ID: #{id}
    Title: #{title}

    #{description || "No description provided."}

    Please analyze this issue and provide your response.
    """
    |> String.trim()
  end

  defp run_cursor(session_id, prompt, config, opts, recipient_pid) do
    try do
      cursor_bin = find_cursor_binary(config)
      timeout = RuntimeTimeout.resolve(config, default_ms: @default_timeout)
      {args, stdin} = build_cursor_invocation(prompt, cursor_bin, config)

      env = config |> build_env() |> port_env()

      port_opts =
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout, {:args, args}, {:env, env}] ++
          cursor_cwd_opt(config)

      with_port({:spawn_executable, cursor_bin}, port_opts, session_id, opts, fn port ->
        send(recipient_pid, {:session_started, session_id})

        if stdin do
          write_stdin(port, stdin)
        end

        case collect_output(port, "", timeout, session_id, recipient_pid) do
          {:ok, raw} ->
            case Cympho.Adapters.ProviderFailure.detect(raw) do
              :ok -> parse_cursor_output(raw)
              {:error, _} = err -> err
            end

          {:error, _} = err ->
            err
        end
      end)
    rescue
      _exception ->
        {:error, :cursor_process_failed}
    catch
      _kind, _reason ->
        {:error, :cursor_process_failed}
    end
  end

  defp with_port(open_spec, port_opts, session_id, runtime_opts, fun) do
    port = Port.open(open_spec, port_opts)

    try do
      case mark_local_process_started(session_id, runtime_opts) do
        :ok -> fun.(port)
        {:error, :runtime_admission_start_failed} = error -> error
      end
    after
      close_port(port)
    end
  end

  defp close_port(port) when is_port(port) do
    Cympho.PortKiller.close_and_await(port)
  end

  defp close_port(_port), do: :ok

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

  defp build_cursor_invocation(prompt, cursor_bin, config) do
    executable = cursor_bin |> Path.basename() |> String.downcase()

    if executable in ["agent", "cursor-agent"] do
      args =
        ["-p", prompt, "--output-format", "json"] ++
          mode_args(config) ++ force_args(config) ++ model_args(config)

      {args, nil}
    else
      args =
        ["--cli", "--format", "json", "--quiet"] ++ headless_args(config) ++ model_args(config)

      {args, prompt}
    end
  end

  defp mode_args(config) do
    case config[:mode] || config["mode"] do
      mode when mode in ["ask", "plan"] -> ["--mode", mode]
      _ -> []
    end
  end

  defp force_args(config), do: if(config[:force] || config["force"], do: ["--force"], else: [])

  defp headless_args(config),
    do: if(config[:headless] || config["headless"], do: ["--headless"], else: [])

  defp model_args(config) do
    case config[:model] || config["model"] do
      nil -> []
      "" -> []
      "auto" -> []
      model -> ["--model", to_string(model)]
    end
  end

  defp cursor_cwd_opt(config) do
    case config[:workspace_path] || config["workspace_path"] || config[:cwd] || config["cwd"] do
      nil -> []
      path -> [{:cd, path}]
    end
  end

  defp collect_output(port, acc, timeout, session_id, recipient_pid) when is_integer(timeout) do
    collect_output(port, acc, RunDeadline.new(timeout), session_id, recipient_pid)
  end

  defp collect_output(port, acc, %RunDeadline{} = deadline, session_id, recipient_pid) do
    receive do
      {^port, {:data, data}} ->
        collect_output(
          port,
          acc <> data,
          RunDeadline.observe(deadline, data, session_id, recipient_pid),
          session_id,
          recipient_pid
        )

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, code}} ->
        {:error, {:exit_code, code}}

      {:cancel_session, ^session_id, reason} ->
        close_port(port)
        {:error, {:cancelled, reason}}

      {:DOWN, _ref, :process, ^recipient_pid, _reason} ->
        # Owner orchestrator died without cancelling us. See Cympho.AgentRunner.
        close_port(port)
        {:error, :owner_down}
    after
      RunDeadline.wait_ms(deadline) ->
        # The stall timer resets on every chunk; only the absolute deadline can
        # end a CLI that keeps talking.
        case RunDeadline.expired(deadline) do
          nil ->
            collect_output(port, acc, deadline, session_id, recipient_pid)

          :max_run ->
            close_port(port)
            {:error, :max_run_timeout}

          :stall ->
            close_port(port)
            {:error, :timeout}
        end
    end
  end

  defp write_stdin(port, stdin) do
    Port.command(port, "#{stdin}\n")
    :ok
  rescue
    ArgumentError -> :closed
  end

  defp parse_cursor_output(raw) do
    raw = String.trim(raw)

    if raw == "" do
      {:error, :no_output}
    else
      parse_cursor_lines(String.split(raw, "\n"), raw)
    end
  end

  defp parse_cursor_lines([line], raw) do
    case Jason.decode(line) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, {:parse_error, raw}}
    end
  end

  defp parse_cursor_lines(lines, raw) do
    parsed =
      lines
      |> Enum.map(&Jason.decode/1)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, m} -> m end)

    if Enum.empty?(parsed) do
      {:error, {:parse_error, raw}}
    else
      {:ok, %{"turns" => parsed}}
    end
  end

  defp find_cursor_binary(config) do
    case config[:command] || config["command"] || config[:cursor_path] || config["cursor_path"] do
      nil ->
        System.find_executable("agent") ||
          System.find_executable("cursor-agent") ||
          System.find_executable("cursor") ||
          raise "Cursor agent binary not found in PATH"

      path ->
        resolve_command_path(path)
    end
  end

  defp build_env(config) do
    runtime_env = config[:env] || config["env"] || %{}
    [{"TERM", "dumb"} | normalize_env(runtime_env)]
  end

  defp normalize_env(env) when is_map(env) do
    Enum.map(env, fn {key, value} -> {env_string(key), env_string(value)} end)
  end

  defp normalize_env(_env), do: []

  defp port_env(env) do
    Enum.map(env, fn {key, value} ->
      {env_charlist(key), env_charlist(value)}
    end)
  end

  defp env_string(value) when is_binary(value), do: value
  defp env_string(value) when is_list(value), do: List.to_string(value)
  defp env_string(value), do: to_string(value)

  defp env_charlist(value) when is_list(value), do: value
  defp env_charlist(value), do: value |> env_string() |> String.to_charlist()

  @impl true
  def health_check(config) do
    cursor_bin = resolve_cursor_path(config)

    cond do
      is_nil(cursor_bin) ->
        %{status: :unhealthy, message: "Cursor binary not found", checked_at: DateTime.utc_now()}

      not File.exists?(cursor_bin) ->
        %{
          status: :unhealthy,
          message: "Cursor binary path does not exist",
          checked_at: DateTime.utc_now()
        }

      true ->
        %{status: :healthy, message: "Cursor adapter ready", checked_at: DateTime.utc_now()}
    end
  end

  @impl true
  def config_schema do
    [
      %{
        key: :command,
        type: :string,
        required: false,
        default: nil,
        description: "Cursor CLI command (defaults to agent, cursor-agent, then cursor)"
      },
      %{
        key: :cursor_path,
        type: :string,
        required: false,
        default: nil,
        description: "Legacy path to Cursor executable"
      },
      %{
        key: :workspace_path,
        type: :string,
        required: false,
        default: nil,
        description: "Cursor workspace path for project context"
      },
      %{
        key: :model,
        type: :string,
        required: false,
        default: Cympho.Adapters.RuntimeOptions.cursor_default_model(),
        options: Cympho.Adapters.RuntimeOptions.cursor_model_options(),
        description: "Model to pass to Cursor with --model; Auto omits the flag"
      },
      %{
        key: :headless,
        type: :boolean,
        required: false,
        default: false,
        description: "Run Cursor in headless mode"
      },
      %{
        key: :mode,
        type: :string,
        required: false,
        default: nil,
        options: [{"Agent", ""}, {"Ask", "ask"}, {"Plan", "plan"}],
        description: "Cursor CLI mode for newer agent entrypoints"
      },
      %{
        key: :force,
        type: :boolean,
        required: false,
        default: false,
        description: "Allow Cursor print mode to write files without confirmation"
      },
      %{
        key: :timeout,
        type: :integer,
        required: false,
        default: @default_timeout,
        description:
          "CLI process timeout in milliseconds. Prefer timeout_sec for human-entered values."
      },
      %{
        key: :timeout_sec,
        type: :integer,
        required: false,
        default: div(@default_timeout, 1_000),
        description:
          "CLI process timeout in seconds; conflicts with timeout/timeout_ms are rejected."
      }
    ]
  end

  @impl true
  def name, do: "Cursor IDE"

  @impl true
  def type, do: :cursor

  @impl true
  def available?(config) do
    cursor_bin = resolve_cursor_path(config)
    not is_nil(cursor_bin) and File.exists?(cursor_bin)
  end

  @impl true
  def available? do
    available?(%{})
  end

  @impl true
  def validate_config(config) do
    with :ok <- validate_command(config_value(config, :command)),
         :ok <- validate_cursor_path(config_value(config, :cursor_path)),
         :ok <- validate_workspace_path(config_value(config, :workspace_path)),
         :ok <- validate_model(config_value(config, :model)),
         :ok <- validate_mode(config_value(config, :mode)),
         :ok <- validate_force(config_value(config, :force)),
         :ok <- validate_timeout(config),
         :ok <- validate_headless(config_value(config, :headless)) do
      :ok
    end
  end

  defp config_value(config, key) when is_map(config) and is_atom(key) do
    case Map.fetch(config, key) do
      {:ok, value} -> value
      :error -> Map.get(config, Atom.to_string(key))
    end
  end

  defp config_value(_config, _key), do: nil

  defp resolve_cursor_path(config) do
    case config[:command] || config["command"] || config[:cursor_path] || config["cursor_path"] do
      nil ->
        System.find_executable("agent") ||
          System.find_executable("cursor-agent") ||
          System.find_executable("cursor")

      path ->
        resolve_command_path(path)
    end
  end

  defp resolve_command_path(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "/") -> path
      true -> System.find_executable(path) || path
    end
  end

  defp validate_command(nil), do: :ok
  defp validate_command(command) when is_binary(command), do: :ok
  defp validate_command(_), do: {:error, "command must be a string"}

  defp validate_cursor_path(nil), do: :ok

  defp validate_cursor_path(path) when is_binary(path) do
    if File.exists?(path), do: :ok, else: {:error, "cursor_path must be a valid file path"}
  end

  defp validate_cursor_path(_), do: {:error, "cursor_path must be a string"}

  defp validate_workspace_path(nil), do: :ok

  defp validate_workspace_path(path) when is_binary(path) do
    if File.dir?(path), do: :ok, else: {:error, "workspace_path must be a valid directory"}
  end

  defp validate_workspace_path(_), do: {:error, "workspace_path must be a string"}

  defp validate_model(nil), do: :ok
  defp validate_model(model) when is_binary(model), do: :ok
  defp validate_model(_), do: {:error, "model must be a string"}

  defp validate_mode(nil), do: :ok
  defp validate_mode(mode) when mode in ["", "ask", "plan"], do: :ok
  defp validate_mode(_), do: {:error, "mode must be ask or plan"}

  defp validate_force(nil), do: :ok
  defp validate_force(force) when is_boolean(force), do: :ok
  defp validate_force(_), do: {:error, "force must be a boolean"}

  defp validate_timeout(config),
    do: RuntimeTimeout.validate(config, max_ms: @max_timeout, field: "timeout")

  defp validate_headless(nil), do: :ok

  defp validate_headless(val) when is_boolean(val), do: :ok

  defp validate_headless(_), do: {:error, "headless must be a boolean"}
end
