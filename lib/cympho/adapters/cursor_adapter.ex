defmodule Cympho.Adapters.CursorAdapter do
  @moduledoc """
  Adapter for Cursor IDE CLI.

  Spawns Cursor's CLI agent process in non-interactive mode. Newer Cursor
  installs expose the `agent` entrypoint, while `cursor-agent` and older
  `cursor` binaries remain supported as fallbacks.
  """

  @behaviour Cympho.Adapters.Adapter

  @default_timeout 300_000

  @impl true
  def run(issue, agent_id, recipient_pid, opts) when is_pid(recipient_pid) do
    session_id = make_ref()
    config = opts[:config] || %{}

    spawn(fn ->
      do_run(session_id, issue, agent_id, recipient_pid, config)
    end)

    session_id
  end

  defp do_run(session_id, issue, agent_id, recipient_pid, config) do
    send(recipient_pid, {:session_started, session_id})

    prompt = build_prompt(issue, agent_id)

    case run_cursor(prompt, config) do
      {:ok, output} ->
        send(recipient_pid, {:turn_completed, session_id, output})

      {:error, reason} ->
        send(recipient_pid, {:turn_ended_with_error, session_id, reason})
    end
  end

  defp build_prompt(issue, agent_id) do
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

  defp run_cursor(prompt, config) do
    try do
      cursor_bin = find_cursor_binary(config)
      timeout = config[:timeout] || config["timeout"] || @default_timeout
      {args, stdin} = build_cursor_invocation(prompt, cursor_bin, config)

      env = build_env(config)

      port_opts =
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout, {:args, args}, {:env, env}] ++
          cursor_cwd_opt(config)

      port = Port.open({:spawn_executable, cursor_bin}, port_opts)

      if stdin do
        Port.command(port, "#{stdin}\n")
      end

      result = collect_output(port, "", timeout)
      Port.close(port)

      case result do
        {:ok, raw} ->
          parse_cursor_output(raw)

        {:error, _} = err ->
          err
      end
    rescue
      e ->
        {:error, "Cursor process failed: #{inspect(e)}"}
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
    case config[:workspace_path] || config["workspace_path"] do
      nil -> []
      path -> [{:cd, path}]
    end
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, code}} ->
        {:error, "Cursor exited with status #{code}: #{acc}"}
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp parse_cursor_output(raw) do
    raw = String.trim(raw)

    case String.split(raw, "\n") do
      [line] ->
        case Jason.decode(line) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:ok, %{"output" => raw}}
        end

      lines ->
        parsed =
          lines
          |> Enum.map(&Jason.decode/1)
          |> Enum.filter(fn
            {:ok, _} -> true
            _ -> false
          end)
          |> Enum.map(fn {:ok, m} -> m end)

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

  defp build_env(_config) do
    [{"TERM", "dumb"}]
  end

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
        description: "CLI process timeout (ms)"
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
    config = atomize_keys(config)

    with :ok <- validate_command(config[:command]),
         :ok <- validate_cursor_path(config[:cursor_path]),
         :ok <- validate_workspace_path(config[:workspace_path]),
         :ok <- validate_model(config[:model]),
         :ok <- validate_mode(config[:mode]),
         :ok <- validate_force(config[:force]),
         :ok <- validate_timeout(config[:timeout]),
         :ok <- validate_headless(config[:headless]) do
      :ok
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

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

  defp validate_timeout(nil), do: :ok

  defp validate_timeout(timeout) when is_integer(timeout) do
    if timeout > 0 and timeout <= 3_600_000,
      do: :ok,
      else: {:error, "timeout must be between 1 and 3600000ms"}
  end

  defp validate_timeout(_), do: {:error, "timeout must be an integer"}

  defp validate_headless(nil), do: :ok

  defp validate_headless(val) when is_boolean(val), do: :ok

  defp validate_headless(_), do: {:error, "headless must be a boolean"}
end
