defmodule Cympho.Adapters.CodexAdapter do
  @moduledoc """
  Adapter for OpenAI Codex.

  Runs agents via OpenAI's API using the Codex model.
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

    prompt = build_prompt(issue, agent_id)

    case call_codex_api(prompt, opts[:config] || %{}) do
      {:ok, result} ->
        send(recipient_pid, {:turn_completed, session_id, result})

      {:error, reason} ->
        send(recipient_pid, {:turn_ended_with_error, session_id, reason})
    end
  end

  defp build_prompt(issue, agent_id) do
    """
    You are agent #{agent_id} working on the following issue:

    Issue ID: #{issue.id}
    Title: #{issue.title}

    #{issue.description || "No description provided."}

    Please analyze this issue and provide your response.
    """
    |> String.trim()
  end

  defp call_codex_api(prompt, config) do
    api_key = get_api_key(config)
    model = config[:model] || config["model"] || "gpt-4"

    # Placeholder for actual OpenAI API call
    # This would use HTTPoison or similar to call the OpenAI API
    {:error, :not_implemented}
  end

  defp get_api_key(config) do
    config[:api_key] || config["api_key"] ||
      Application.get_env(:cympho, :openai_api_key) ||
      System.get_env("OPENAI_API_KEY")
  end

  @impl true
  def health_check(config) do
    api_key = get_api_key(config)

    cond do
      is_nil(api_key) or api_key == "" ->
        %{status: :unhealthy, message: "OpenAI API key not configured", checked_at: DateTime.utc_now()}

      true ->
        # Could add actual API health check here
        %{status: :healthy, message: "OpenAI API configured", checked_at: DateTime.utc_now()}
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
        default: "gpt-4",
        description: "Model to use (e.g., gpt-4, gpt-3.5-turbo)"
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
      }
    ]
  end

  @impl true
  def name, do: "OpenAI Codex"

  @impl true
  def type, do: :codex

  @impl true
  def available? do
    # Always available if configured
    api_key =
      Application.get_env(:cympho, :openai_api_key) || System.get_env("OPENAI_API_KEY")

    not is_nil(api_key) and api_key != ""
  end

  @impl true
  def validate_config(config) do
    with :ok <- validate_api_key(config["api_key"] || config[:api_key]),
         :ok <- validate_model(config["model"] || config[:model]),
         :ok <- validate_temperature(config["temperature"] || config[:temperature]),
         :ok <- validate_max_tokens(config["max_tokens"] || config[:max_tokens]) do
      :ok
    end
  end

  defp validate_api_key(nil), do: {:error, "api_key is required"}
  defp validate_api_key(key) when is_binary(key), do: :ok
  defp validate_api_key(_), do: {:error, "api_key must be a string"}

  defp validate_model(nil), do: :ok
  defp validate_model(model) when is_binary(model), do: :ok
  defp validate_model(_), do: {:error, "model must be a string"}

  defp validate_temperature(nil), do: :ok

  defp validate_temperature(temp) when is_float(temp) or is_integer(temp) do
    if temp >= 0.0 and temp <= 2.0 do
      :ok
    else
      {:error, "temperature must be between 0.0 and 2.0"}
    end
  end

  defp validate_temperature(_), do: {:error, "temperature must be a number"}

  defp validate_max_tokens(nil), do: :ok

  defp validate_max_tokens(tokens) when is_integer(tokens) do
    if tokens > 0 do
      :ok
    else
      {:error, "max_tokens must be positive"}
    end
  end

  defp validate_max_tokens(_), do: {:error, "max_tokens must be an integer"}
end
