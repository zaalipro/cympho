defmodule Cympho.Adapters.ModelCompatibility do
  @moduledoc """
  Conservative adapter/model sanity checks.

  These checks only reject clear mismatches. Gateway and wrapper routes stay
  flexible because many providers expose OpenAI- or Anthropic-compatible APIs
  with non-native model names.
  """

  @anthropic_family ~r/(^|[\/:_-])(anthropic|claude|sonnet|opus|haiku)([\/:_-]|$)/
  @openai_family ~r/^(openai\/|openai-codex\/|gpt-|o[0-9](?:-|$)|codex-)/
  @openclaw_flexible_providers ~w(custom openrouter ollama vllm)

  @spec validate(atom() | module() | String.t() | nil, map()) :: :ok | {:error, String.t()}
  def validate(adapter, config) when is_map(config) do
    adapter = adapter_key(adapter)
    model = config_value(config, "model") |> normalize_text()
    provider = config_value(config, "provider") |> normalize_text()
    command = config_value(config, "command") |> normalize_text()

    endpoint =
      (config_value(config, "endpoint") || config_value(config, "base_url")) |> to_string()

    cond do
      model == "" ->
        :ok

      adapter == "codex" and anthropic_model?(model) ->
        {:error,
         "Codex cannot run Claude-family model `#{model}`. Choose a Codex/OpenAI model or switch this runtime profile to Claude Code or OpenClaw."}

      adapter == "claude_code" and default_claude_command?(command) and openai_model?(model) ->
        {:error,
         "Claude Code with the default `claude` command cannot run OpenAI/Codex model `#{model}`. Choose a Claude-family model, select an OpenAI-compatible runtime, or use an explicit wrapper command."}

      adapter == "openai_chat" and official_openai_endpoint?(endpoint) and anthropic_model?(model) ->
        {:error,
         "The OpenAI chat endpoint cannot serve Claude-family model `#{model}`. Choose an OpenAI model, switch to a compatible gateway endpoint, or use Claude Code/OpenClaw."}

      adapter == "openclaw" and openclaw_provider_mismatch?(provider, model) ->
        {:error,
         "OpenClaw provider `#{provider}` does not match model `#{model}`. Choose a model with the same provider prefix or change the provider."}

      true ->
        :ok
    end
  end

  def validate(_adapter, _config), do: :ok

  @spec adapter_key(atom() | module() | String.t() | nil) :: String.t()
  def adapter_key(nil), do: ""
  def adapter_key(adapter) when is_binary(adapter), do: normalize_text(adapter)

  def adapter_key(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :type, 0) do
      adapter.type() |> Atom.to_string()
    else
      Atom.to_string(adapter)
    end
    |> normalize_text()
  end

  def adapter_key(adapter), do: adapter |> to_string() |> normalize_text()

  defp config_value(config, key) do
    Map.get(config, key) || Map.get(config, String.to_atom(key))
  end

  defp normalize_text(value) when value in [nil, ""], do: ""

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp anthropic_model?(model), do: Regex.match?(@anthropic_family, model)
  defp openai_model?(model), do: Regex.match?(@openai_family, model)

  defp default_claude_command?(command), do: command in ["", "claude"]

  defp official_openai_endpoint?(endpoint) when endpoint in [nil, ""], do: false

  defp official_openai_endpoint?(endpoint) do
    endpoint
    |> URI.parse()
    |> Map.get(:host)
    |> case do
      host when is_binary(host) -> String.ends_with?(String.downcase(host), "openai.com")
      _ -> false
    end
  rescue
    _ -> false
  end

  defp openclaw_provider_mismatch?("", _model), do: false

  defp openclaw_provider_mismatch?(provider, _model)
       when provider in @openclaw_flexible_providers,
       do: false

  defp openclaw_provider_mismatch?(provider, model) do
    String.contains?(model, "/") and not String.starts_with?(model, provider <> "/")
  end
end
