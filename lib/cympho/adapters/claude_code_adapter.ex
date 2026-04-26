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
  def health_check(config) do
    api_key = get_api_key(config)
    has_claude = System.find_executable("claude") != nil

    cond do
      (is_nil(api_key) or api_key == "") and not has_claude ->
        %{
          status: :unhealthy,
          message: "Claude CLI not found and API key not configured",
          checked_at: DateTime.utc_now()
        }

      is_nil(api_key) or api_key == "" ->
        %{
          status: :degraded,
          message: "Claude CLI available but API key not configured",
          checked_at: DateTime.utc_now()
        }

      not has_claude ->
        %{
          status: :degraded,
          message: "API key configured but Claude CLI not found in PATH",
          checked_at: DateTime.utc_now()
        }

      true ->
        %{status: :healthy, message: "Claude CLI available", checked_at: DateTime.utc_now()}
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
      },
      %{
        key: :resume,
        type: :boolean,
        required: false,
        default: false,
        description: "Resume a multi-turn session"
      }
    ]
  end

  @impl true
  def name, do: "Claude Code"

  @impl true
  def type, do: :claude_code

  @impl true
  def available?(config) do
    api_key = get_api_key(config)
    has_key = not is_nil(api_key) and api_key != ""
    has_binary = System.find_executable("claude") != nil
    has_key or has_binary
  end

  @impl true
  def available? do
    available?(%{})
  end

  @impl true
  def validate_config(config) do
    config = atomize_keys(config)

    with :ok <- validate_stall_timeout(config[:stall_timeout]),
         :ok <- validate_cwd(config[:cwd]),
         :ok <- validate_resume(config[:resume]) do
      :ok
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp get_api_key(config) do
    config[:api_key] || config["api_key"] ||
      Application.get_env(:cympho, :anthropic_api_key) ||
      System.get_env("ANTHROPIC_API_KEY")
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

  defp validate_resume(nil), do: :ok
  defp validate_resume(val) when is_boolean(val), do: :ok
  defp validate_resume(_), do: {:error, "resume must be a boolean"}
end
