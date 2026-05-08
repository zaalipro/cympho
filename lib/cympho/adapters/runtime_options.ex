defmodule Cympho.Adapters.RuntimeOptions do
  @moduledoc """
  Runtime/provider/model options used by agent adapter configuration forms.

  The adapters do not all mean "model" the same way: Codex and Cursor pass it
  as a CLI argument, OpenClaw uses provider-qualified model ids, and Process
  needs an explicit preset/mapping before a model can be forwarded.
  """

  @cursor_models [
    {"Auto", "auto"},
    {"Composer 2", "composer-2"},
    {"Opus 4.6", "opus-4.6"},
    {"Codex 5.3 High Fast", "codex-5.3-high-fast"},
    {"Gemini 3 Pro", "gemini-3-pro"},
    {"Grok", "grok"}
  ]

  @openclaw_providers [
    {"OpenAI Codex", "openai-codex"},
    {"OpenAI", "openai"},
    {"Anthropic", "anthropic"},
    {"MiniMax", "minimax"},
    {"Z.AI", "zai"},
    {"OpenRouter", "openrouter"},
    {"Ollama", "ollama"},
    {"vLLM", "vllm"},
    {"Custom", "custom"}
  ]

  @openclaw_models %{
    "openai-codex" => [
      {"GPT-5.5", "openai-codex/gpt-5.5"},
      {"GPT-5.3 Codex", "openai-codex/gpt-5.3"},
      {"GPT-5.3 Codex Spark", "openai-codex/gpt-5.3-codex-spark"},
      {"GPT-5.2", "openai-codex/gpt-5.2"}
    ],
    "openai" => [
      {"GPT-5.5", "openai/gpt-5.5"},
      {"GPT-5.4 mini", "openai/gpt-5.4-mini"},
      {"GPT-5.3 Codex Spark", "openai/gpt-5.3-codex-spark"}
    ],
    "anthropic" => [
      {"Claude Opus 4.6", "anthropic/claude-opus-4-6"},
      {"Claude Sonnet 4.6", "anthropic/claude-sonnet-4-6"},
      {"Claude Haiku", "anthropic/claude-haiku"}
    ],
    "minimax" => [
      {"MiniMax M2.7 highspeed", "minimax/MiniMax-M2.7-highspeed"},
      {"MiniMax M2.5", "minimax/MiniMax-M2.5"}
    ],
    "zai" => [
      {"GLM 4.7", "zai/glm-4.7"},
      {"GLM 4.6", "zai/glm-4.6"}
    ],
    "openrouter" => [
      {"Auto", "openrouter/auto"},
      {"Custom OpenRouter model", "openrouter/custom"}
    ],
    "ollama" => [
      {"Llama 3.3", "ollama/llama3.3"},
      {"Custom Ollama model", "ollama/custom"}
    ],
    "vllm" => [
      {"Your vLLM model", "vllm/your-model-id"}
    ],
    "custom" => [
      {"Custom provider model", "custom/model"}
    ]
  }

  @process_presets [
    {"Custom command", "custom"},
    {"Codex CLI", "codex"},
    {"Claude-compatible CLI", "claude_code"},
    {"Cursor CLI", "cursor"},
    {"OpenClaw CLI", "openclaw"}
  ]

  @process_provider_options [
    {"Use process default", ""},
    {"OpenAI / Codex", "openai"},
    {"Anthropic-compatible", "anthropic"},
    {"Cursor", "cursor"},
    {"OpenClaw", "openclaw"},
    {"Custom", "custom"}
  ]

  def cursor_model_options do
    (configured_options("CYMPHO_CURSOR_MODELS") ++ @cursor_models)
    |> unique_options()
  end

  def cursor_default_model, do: "auto"

  def openclaw_provider_options, do: @openclaw_providers
  def openclaw_default_provider, do: "openai-codex"

  def openclaw_provider_model_options do
    Enum.flat_map(@openclaw_providers, fn {_label, provider} ->
      provider
      |> openclaw_model_options()
      |> Enum.map(fn {label, value} -> {provider, label, value} end)
    end)
  end

  def openclaw_model_options(provider) do
    provider = blank_default(provider, openclaw_default_provider())

    (configured_options("CYMPHO_OPENCLAW_MODELS") ++
       Map.get(@openclaw_models, provider, @openclaw_models["custom"]))
    |> unique_options()
  end

  def openclaw_default_model(provider \\ openclaw_default_provider()) do
    provider
    |> openclaw_model_options()
    |> List.first()
    |> case do
      {_label, value} -> value
      nil -> "openai-codex/gpt-5.5"
    end
  end

  def process_preset_options, do: @process_presets
  def process_default_preset, do: "custom"
  def process_provider_options, do: @process_provider_options

  def process_provider_model_options do
    Enum.flat_map(@process_provider_options, fn {_label, provider} ->
      provider
      |> process_model_options()
      |> Enum.map(fn {label, value} -> {provider, label, value} end)
    end)
  end

  def process_model_options(provider) when provider in ["openclaw", "openai", "anthropic"] do
    provider
    |> case do
      "openclaw" -> openclaw_model_options(openclaw_default_provider())
      "openai" -> Cympho.Adapters.CodexAdapter.model_options()
      "anthropic" -> [{"Provider default", ""}, {"Sonnet", "sonnet"}, {"Opus", "opus"}]
    end
  end

  def process_model_options(_provider) do
    [{"Runtime default", ""}, {"Custom model", "custom"}]
  end

  def process_defaults("codex") do
    %{
      "command" => "codex",
      "provider" => "openai",
      "model_arg_template" => ["--model", "{{model}}"]
    }
  end

  def process_defaults("claude_code") do
    %{
      "command" => "claude",
      "provider" => "anthropic",
      "model_env_key" => "ANTHROPIC_MODEL"
    }
  end

  def process_defaults("cursor") do
    %{
      "command" => "agent",
      "provider" => "cursor",
      "model_arg_template" => ["--model", "{{model}}"]
    }
  end

  def process_defaults("openclaw") do
    %{
      "command" => "openclaw",
      "provider" => "openclaw",
      "model_arg_template" => ["--model", "{{model}}"]
    }
  end

  def process_defaults(_), do: %{}

  defp blank_default(value, fallback) when value in [nil, ""], do: fallback
  defp blank_default(value, _fallback), do: value

  defp configured_options(env_name) do
    env_name
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&{&1, &1})
  end

  defp unique_options(options) do
    options
    |> Enum.reverse()
    |> Enum.uniq_by(fn {_label, value} -> value end)
    |> Enum.reverse()
  end
end
