defmodule Cympho.Adapters.CursorAdapter do
  @moduledoc """
  Adapter for Cursor IDE.

  Runs agents via Cursor's CLI or extension API.
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
    send(recipient_pid, {:session_started, session_id})

    case run_cursor_command(issue, agent_id, opts) do
      {:ok, result} ->
        send(recipient_pid, {:turn_completed, session_id, result})

      {:error, reason} ->
        send(recipient_pid, {:turn_ended_with_error, session_id, reason})
    end
  end

  defp run_cursor_command(issue, agent_id, opts) do
    # Placeholder for Cursor-specific implementation
    # This would use Cursor's CLI or extension API
    {:error, :not_implemented}
  end

  @impl true
  def health_check(_config) do
    case System.cmd("which", ["cursor"]) do
      {_, 0} ->
        %{status: :healthy, message: "Cursor CLI available", checked_at: DateTime.utc_now()}

      _ ->
        %{status: :unhealthy, message: "Cursor CLI not found in PATH", checked_at: DateTime.utc_now()}
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
        description: "Cursor workspace path"
      },
      %{
        key: :timeout,
        type: :integer,
        required: false,
        default: 300_000,
        description: "Operation timeout in milliseconds"
      }
    ]
  end

  @impl true
  def name, do: "Cursor IDE"

  @impl true
  def type, do: :cursor

  @impl true
  def available? do
    case System.cmd("which", ["cursor"]) do
      {_, 0} -> true
      _ -> false
    end
  end

  @impl true
  def validate_config(config) do
    with :ok <- validate_cursor_path(config["cursor_path"] || config[:cursor_path]),
         :ok <- validate_workspace_path(config["workspace_path"] || config[:workspace_path]),
         :ok <- validate_timeout(config["timeout"] || config[:timeout]) do
      :ok
    end
  end

  defp validate_cursor_path(nil), do: :ok

  defp validate_cursor_path(path) when is_binary(path) do
    if File.exists?(path) do
      :ok
    else
      {:error, "cursor_path must be a valid file path"}
    end
  end

  defp validate_cursor_path(_), do: {:error, "cursor_path must be a string"}

  defp validate_workspace_path(nil), do: :ok

  defp validate_workspace_path(path) when is_binary(path) do
    if File.dir?(path) do
      :ok
    else
      {:error, "workspace_path must be a valid directory"}
    end
  end

  defp validate_workspace_path(_), do: {:error, "workspace_path must be a string"}

  defp validate_timeout(nil), do: :ok

  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0 do
    if timeout <= 3_600_000 do
      :ok
    else
      {:error, "timeout must be less than 1 hour (3600000ms)"}
    end
  end

  defp validate_timeout(_), do: {:error, "timeout must be a positive integer"}
end
