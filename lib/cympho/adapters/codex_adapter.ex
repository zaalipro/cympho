defmodule Cympho.Adapters.CodexAdapter do
  @moduledoc """
  Adapter for OpenAI Codex CLI.

  Spawns a `codex` CLI process and communicates via stdin/stdout using JSON
  output mode. Emits the standard session message protocol.
  """

  @behaviour Cympho.Adapters.Adapter

  @default_model "o4-mini"
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

    prompt = Cympho.AgentPrompt.build(issue, agent_id)

    case run_codex(prompt, config) do
      {:ok, output} ->
        send(recipient_pid, {:turn_completed, session_id, output})

      {:error, reason} ->
        send(recipient_pid, {:turn_ended_with_error, session_id, reason})
    end
  end

  defp run_codex(prompt, config) do
    try do
      codex_bin = find_codex_binary()
      model = config[:model] || config["model"] || @default_model
      timeout = config[:timeout] || config["timeout"] || @default_timeout

      args = [
        "--model",
        to_string(model),
        "--format",
        "json",
        "--quiet"
      ]

      env = build_env(config)

      port =
        Port.open(
          {:spawn_executable, codex_bin},
          [:binary, :exit_status, :use_stdio, :stderr_to_stdout, {:args, args}, {:env, env}]
        )

      Port.command(port, "#{prompt}\n")

      result = collect_output(port, "", timeout)
      Port.close(port)

      case result do
        {:ok, raw} ->
          parse_codex_output(raw)

        {:error, _} = err ->
          err
      end
    rescue
      e ->
        {:error, "Codex process failed: #{inspect(e)}"}
    end
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, code}} ->
        {:error, "Codex exited with status #{code}: #{acc}"}
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp parse_codex_output(raw) do
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

  defp find_codex_binary do
    System.find_executable("codex") || raise "codex binary not found in PATH"
  end

  defp build_env(config) do
    api_key =
      config[:api_key] || config["api_key"] ||
        Application.get_env(:cympho, :openai_api_key) ||
        System.get_env("OPENAI_API_KEY")

    base = [{"TERM", "dumb"}]

    if api_key do
      [{"OPENAI_API_KEY", api_key} | base]
    else
      base
    end
  end

  @impl true
  def health_check(config) do
    api_key = get_api_key(config)

    cond do
      is_nil(api_key) or api_key == "" ->
        %{
          status: :unhealthy,
          message: "OpenAI API key not configured",
          checked_at: DateTime.utc_now()
        }

      is_nil(System.find_executable("codex")) ->
        %{
          status: :degraded,
          message: "codex binary not found in PATH",
          checked_at: DateTime.utc_now()
        }

      true ->
        %{status: :healthy, message: "Codex adapter ready", checked_at: DateTime.utc_now()}
    end
  end

  @impl true
  def config_schema do
    [
      %{
        key: :api_key,
        type: :string,
        required: true,
        default: nil,
        description: "OpenAI API key"
      },
      %{
        key: :model,
        type: :string,
        required: false,
        default: @default_model,
        description: "Model to use"
      },
      %{
        key: :temperature,
        type: :float,
        required: false,
        default: 0.7,
        description: "Sampling temperature (0.0 - 2.0)"
      },
      %{
        key: :max_tokens,
        type: :integer,
        required: false,
        default: 2000,
        description: "Maximum tokens to generate"
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
  def name, do: "OpenAI Codex"

  @impl true
  def type, do: :codex

  @impl true
  def available?(config) do
    api_key = get_api_key(config)
    has_key = not is_nil(api_key) and api_key != ""
    has_binary = not is_nil(System.find_executable("codex"))
    has_key and has_binary
  end

  @impl true
  def available? do
    available?(%{})
  end

  @impl true
  def validate_config(config) do
    config = atomize_keys(config)

    with :ok <- validate_api_key(config[:api_key]),
         :ok <- validate_model(config[:model]),
         :ok <- validate_temperature(config[:temperature]),
         :ok <- validate_max_tokens(config[:max_tokens]) do
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
      Application.get_env(:cympho, :openai_api_key) ||
      System.get_env("OPENAI_API_KEY")
  end

  defp validate_api_key(nil), do: {:error, "api_key is required"}
  defp validate_api_key(key) when is_binary(key), do: :ok
  defp validate_api_key(_), do: {:error, "api_key must be a string"}

  defp validate_model(nil), do: :ok
  defp validate_model(model) when is_binary(model), do: :ok
  defp validate_model(_), do: {:error, "model must be a string"}

  defp validate_temperature(nil), do: :ok

  defp validate_temperature(temp) when is_float(temp) or is_integer(temp) do
    if temp >= 0.0 and temp <= 2.0,
      do: :ok,
      else: {:error, "temperature must be between 0.0 and 2.0"}
  end

  defp validate_temperature(_), do: {:error, "temperature must be a number"}

  defp validate_max_tokens(nil), do: :ok

  defp validate_max_tokens(tokens) when is_integer(tokens) do
    if tokens > 0, do: :ok, else: {:error, "max_tokens must be positive"}
  end

  defp validate_max_tokens(_), do: {:error, "max_tokens must be an integer"}
end
