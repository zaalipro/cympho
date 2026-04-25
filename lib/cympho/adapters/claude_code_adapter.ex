defmodule Cympho.Adapters.ClaudeCodeAdapter do
  @moduledoc """
  Adapter for Anthropic Claude Code CLI.

  Runs agents via the local Claude CLI with JSON output and structured messaging.
  """

  @behaviour Cympho.Adapters.Adapter

  alias Cympho.AgentRunner

  @impl true
  def run(issue, agent_id, recipient_pid, opts) when is_pid(recipient_pid) do
    AgentRunner.run(issue, agent_id, recipient_pid, opts)
  end

  @impl true
  def health_check(_config) do
    # Check if claude CLI is available
    case System.cmd("which", ["claude"]) do
      {_, 0} ->
        %{status: :healthy, message: "Claude CLI available", checked_at: DateTime.utc_now()}

      _ ->
        %{status: :unhealthy, message: "Claude CLI not found in PATH", checked_at: DateTime.utc_now()}
    end
  end

  @impl true
  def config_schema do
    [
      %{
        key: :api_key,
        type: :string,
        required: false,
        default: nil,
        description: "ANTHROPIC_API_KEY for Claude CLI (defaults to system env)"
      },
      %{
        key: :stall_timeout,
        type: :integer,
        required: false,
        default: 300_000,
        description: "Milliseconds before killing hung process (default 300000 / 5 min)"
      },
      %{
        key: :cwd,
        type: :string,
        required: false,
        default: nil,
        description: "Working directory for Claude CLI (defaults to workspace path)"
      }
    ]
  end

  @impl true
  def name, do: "Claude Code"

  @impl true
  def available? do
    case System.cmd("which", ["claude"]) do
      {_, 0} -> true
      _ -> false
    end
  end

  @impl true
  def validate_config(config) do
    with :ok <- validate_stall_timeout(config["stall_timeout"] || config[:stall_timeout]),
         :ok <- validate_cwd(config["cwd"] || config[:cwd]) do
      :ok
    end
  end

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
    if File.dir?(path) do
      :ok
    else
      {:error, "cwd must be a valid directory path"}
    end
  end

  defp validate_cwd(_), do: {:error, "cwd must be a string"}
end
