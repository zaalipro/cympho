defmodule Cympho.Adapters.CursorAdapter do
  @moduledoc """
  Adapter for Cursor IDE CLI.

  Spawns a `cursor` CLI process and communicates via stdin/stdout using JSON
  output mode. Emits the standard session message protocol.
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
    """
    You are agent #{agent_id} working on the following issue:

    Issue ID: #{issue[:id] || issue.id}
    Title: #{issue[:title] || issue.title}

    #{issue[:description] || issue.description || "No description provided."}

    Please analyze this issue and provide your response.
    """
    |> String.trim()
  end

  defp run_cursor(prompt, config) do
    cursor_bin = find_cursor_binary(config)
    timeout = config[:timeout] || config["timeout"] || @default_timeout

    args = build_cursor_args(config)

    env = build_env(config)

    try do
      port_opts =
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout, {:args, args}, {:env, env}] ++
          cursor_cwd_opt(config)

      port = Port.open({:spawn_executable, cursor_bin}, port_opts)

      Port.command(port, "#{prompt}\n")

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

  defp build_cursor_args(config) do
    base_args = ["--cli", "--format", "json", "--quiet"]

    headless =
      if config[:headless] || config["headless"] do
        ["--headless"]
      else
        []
      end

    model_args =
      case config[:model] || config["model"] do
        nil -> []
        model -> ["--model", to_string(model)]
      end

    base_args ++ headless ++ model_args
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
    case config[:cursor_path] || config["cursor_path"] do
      nil -> System.find_executable("cursor") || raise "cursor binary not found in PATH"
      path -> path
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
        key: :cursor_path,
        type: :string,
        required: false,
        default: nil,
        description: "Path to Cursor executable (defaults to system PATH)"
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
        default: nil,
        description: "Model to use within Cursor"
      },
      %{
        key: :headless,
        type: :boolean,
        required: false,
        default: false,
        description: "Run Cursor in headless mode"
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
    not is_nil(cursor_bin)
  end

  @impl true
  def available? do
    available?(%{})
  end

  @impl true
  def validate_config(config) do
    config = atomize_keys(config)

    with :ok <- validate_cursor_path(config[:cursor_path]),
         :ok <- validate_workspace_path(config[:workspace_path]),
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
    case config[:cursor_path] || config["cursor_path"] do
      nil -> System.find_executable("cursor")
      path -> path
    end
  end

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
