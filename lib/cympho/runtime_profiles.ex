defmodule Cympho.RuntimeProfiles do
  @moduledoc """
  Built-in runtime profiles for agent adapter configuration.

  Profiles are intentionally small and deterministic: they provide good
  defaults for adapter, model, command, and runtime env without hiding the
  underlying adapter config. Agents persist the selected profile id in
  `runtime_config["profile_id"]`; the concrete adapter config is still written
  to `agent.config` so existing runners keep working.
  """

  @custom_id "custom"
  @quick_presets [
    %{
      id: "low_ram",
      name: "Low RAM",
      profile_id: "codex-mini",
      max_concurrent_jobs: 1,
      description: "Keep one local CLI slot for small laptops and review-mode testing."
    },
    %{
      id: "balanced",
      name: "Balanced",
      profile_id: "claude-cm",
      max_concurrent_jobs: 2,
      description: "Use the low-cost Claude-compatible wrapper with modest parallelism."
    },
    %{
      id: "fast",
      name: "Fast",
      profile_id: "claude-cz",
      max_concurrent_jobs: 3,
      description: "Allow more local throughput when RAM and provider quotas are comfortable."
    },
    %{
      id: "qwen_dashscope_flash",
      name: "Qwen DashScope Flash",
      profile_id: "openai-chat-qwen-dashscope-flash",
      max_concurrent_jobs: 1,
      description: "Use low-cost DashScope Qwen flash chat completions for smoke runs."
    },
    %{
      id: "qwen_dashscope",
      name: "Qwen DashScope",
      profile_id: "openai-chat-qwen-dashscope",
      max_concurrent_jobs: 1,
      description:
        "Use stronger DashScope compatible-mode chat completions with one safe gateway slot."
    },
    %{
      id: "qwen_dashscope_intl",
      name: "Qwen DashScope Intl",
      profile_id: "openai-chat-qwen-dashscope-intl",
      max_concurrent_jobs: 1,
      description: "Use DashScope International compatible-mode chat completions."
    },
    %{
      id: "llmotions_gemma",
      name: "LLMotions Gemma",
      profile_id: "openai-chat-llmotions-gemma",
      max_concurrent_jobs: 1,
      description: "Use LLMotions Gemma for low-cost CEO/CTO governance smoke runs."
    },
    %{
      id: "llmotions_gemini_flash_low",
      name: "LLMotions Gemini Flash Low",
      profile_id: "openai-chat-llmotions-gemini-flash-low",
      max_concurrent_jobs: 1,
      description: "Use the lower-cost LLMotions Gemini Flash profile for cheap smoke runs."
    },
    %{
      id: "llmotions_gemini_flash",
      name: "LLMotions Gemini Flash",
      profile_id: "openai-chat-llmotions-gemini-flash",
      max_concurrent_jobs: 1,
      description: "Use LLMotions Gemini Flash when the smoke run needs a stronger pass."
    },
    %{
      id: "provider_test",
      name: "Provider test",
      profile_id: "process-codex",
      max_concurrent_jobs: 1,
      description: "Exercise a generic process adapter without opening broad concurrency."
    }
  ]
  @default_fallback_chains %{
    "codex-gpt-5.5" => ["codex-mini", "process-codex"],
    "codex-mini" => ["process-codex"],
    "claude-cz" => ["claude-cm", "openai-chat-qwen-dashscope-flash"],
    "claude-cm" => ["claude-cz", "openai-chat-qwen-dashscope-flash"],
    "claude-qwen-dashscope" => [
      "openai-chat-qwen-dashscope",
      "openai-chat-qwen-dashscope-flash"
    ],
    "openai-chat-qwen-dashscope" => [
      "openai-chat-qwen-dashscope-flash",
      "openai-chat-qwen-dashscope-intl"
    ],
    "openai-chat-qwen-dashscope-flash" => ["openai-chat-qwen-dashscope-intl"],
    "openai-chat-qwen-dashscope-intl" => ["openai-chat-qwen-dashscope-flash"],
    "openai-chat-llmotions-gemma" => [
      "openai-chat-llmotions-gemini-flash-low",
      "openai-chat-qwen-dashscope-flash"
    ],
    "openai-chat-llmotions-gemini-flash-low" => [
      "openai-chat-llmotions-gemma"
    ],
    "openai-chat-llmotions-gemini-flash" => [
      "openai-chat-llmotions-gemini-flash-low",
      "openai-chat-llmotions-gemma"
    ],
    "openclaw-zai" => ["openclaw-minimax", "codex-mini"],
    "openclaw-minimax" => ["openclaw-zai", "codex-mini"],
    "cursor-auto" => ["codex-mini", "process-codex"],
    "process-codex" => ["codex-mini"]
  }

  def custom_id, do: @custom_id

  def all do
    [
      %{
        id: @custom_id,
        name: "Custom adapter config",
        adapter: nil,
        posture: "Manual",
        description: "Use the adapter fields below without applying a runtime profile.",
        config: %{},
        runtime_config: %{}
      },
      %{
        id: "claude-cz",
        name: "Claude-compatible via cz",
        adapter: "claude_code",
        posture: "Low-cost wrapper",
        description: "Runs Claude Code through the cz wrapper. Good for Z.AI-compatible routing.",
        config: %{"command" => "cz"},
        runtime_config: %{}
      },
      %{
        id: "claude-cm",
        name: "Claude-compatible via cm",
        adapter: "claude_code",
        posture: "Low-cost wrapper",
        description:
          "Runs Claude Code through the cm wrapper. Good for MiniMax-compatible routing.",
        config: %{"command" => "cm"},
        runtime_config: %{}
      },
      %{
        id: "claude-qwen-dashscope",
        name: "Claude-compatible Qwen DashScope",
        adapter: "claude_code",
        posture: "Gateway",
        description:
          "Legacy Claude CLI route for providers that speak Anthropic-style messages. Use the OpenAI Chat Qwen profile for /chat/completions endpoints.",
        config: %{"command" => "claude"},
        runtime_config: %{
          "env" => %{
            "ANTHROPIC_MODEL" => "qwen3.7-plus",
            "ANTHROPIC_BASE_URL" => "https://dashscope.aliyuncs.com/compatible-mode/v1"
          }
        }
      },
      %{
        id: "openai-chat-qwen-dashscope-flash",
        name: "OpenAI Chat Qwen DashScope Flash",
        adapter: "openai_chat",
        posture: "Low-cost gateway",
        description:
          "Calls DashScope compatible-mode chat completions directly with qwen3.6-flash for cheap CEO smoke tests. Add DASHSCOPE_API_KEY in Secrets before execution; OPENAI_API_KEY and ANTHROPIC_API_KEY remain accepted aliases for compatible gateways.",
        config: %{
          "endpoint" => "https://dashscope.aliyuncs.com/compatible-mode/v1",
          "model" => "qwen3.6-flash"
        },
        runtime_config: %{}
      },
      %{
        id: "openai-chat-qwen-dashscope",
        name: "OpenAI Chat Qwen DashScope",
        adapter: "openai_chat",
        posture: "Gateway",
        description:
          "Calls DashScope compatible-mode chat completions directly with qwen3.7-plus for stronger CEO planning. Add DASHSCOPE_API_KEY in Secrets before execution; OPENAI_API_KEY and ANTHROPIC_API_KEY remain accepted aliases for compatible gateways.",
        config: %{
          "endpoint" => "https://dashscope.aliyuncs.com/compatible-mode/v1",
          "model" => "qwen3.7-plus"
        },
        runtime_config: %{}
      },
      %{
        id: "openai-chat-qwen-dashscope-intl",
        name: "OpenAI Chat Qwen DashScope Intl",
        adapter: "openai_chat",
        posture: "Gateway",
        description:
          "Calls DashScope International compatible-mode chat completions directly. Add DASHSCOPE_API_KEY or OPENAI_API_KEY in Secrets before execution.",
        config: %{
          "endpoint" => "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
          "model" => "qwen3.7-plus"
        },
        runtime_config: %{}
      },
      %{
        id: "openai-chat-llmotions-gemma",
        name: "OpenAI Chat LLMotions Gemma",
        adapter: "openai_chat",
        posture: "Low-cost gateway",
        description:
          "Calls LLMotions OpenAI-compatible chat completions with gemma-4-31b for CEO/CTO smoke tests. Add LLMOTIONS_API_KEY in Secrets before execution; OPENAI_API_KEY remains accepted as a compatible-gateway alias.",
        config: %{
          "endpoint" => "https://cli.llmotions.com/v1",
          "model" => "gemma-4-31b"
        },
        runtime_config: %{}
      },
      %{
        id: "openai-chat-llmotions-gemini-flash-low",
        name: "OpenAI Chat LLMotions Gemini Flash Low",
        adapter: "openai_chat",
        posture: "Low-cost gateway",
        description:
          "Calls LLMotions OpenAI-compatible chat completions with gemini-3.5-flash-low for cheap governance and routing smoke tests. Add LLMOTIONS_API_KEY in Secrets before execution.",
        config: %{
          "endpoint" => "https://cli.llmotions.com/v1",
          "model" => "gemini-3.5-flash-low"
        },
        runtime_config: %{}
      },
      %{
        id: "openai-chat-llmotions-gemini-flash",
        name: "OpenAI Chat LLMotions Gemini Flash",
        adapter: "openai_chat",
        posture: "Gateway",
        description:
          "Calls LLMotions OpenAI-compatible chat completions with gemini-3.5-flash for stronger CEO/CTO planning turns. Add LLMOTIONS_API_KEY in Secrets before execution.",
        config: %{
          "endpoint" => "https://cli.llmotions.com/v1",
          "model" => "gemini-3.5-flash"
        },
        runtime_config: %{}
      },
      %{
        id: "codex-gpt-5.5",
        name: "Codex GPT-5.5",
        adapter: "codex",
        posture: "Highest reasoning",
        description: "Uses Codex CLI with GPT-5.5 for difficult engineering and review work.",
        config: %{"provider" => "openai-codex", "model" => "gpt-5.5"},
        runtime_config: %{}
      },
      %{
        id: "codex-mini",
        name: "Codex mini",
        adapter: "codex",
        posture: "Fast/cheap",
        description: "Uses Codex CLI with a smaller model for routine changes and QA passes.",
        config: %{"provider" => "openai-codex", "model" => "gpt-5.4-mini"},
        runtime_config: %{}
      },
      %{
        id: "cursor-auto",
        name: "Cursor auto",
        adapter: "cursor",
        posture: "Local account",
        description: "Uses Cursor's agent CLI and lets Cursor pick the model from the account.",
        config: %{"command" => "agent", "model" => "auto"},
        runtime_config: %{}
      },
      %{
        id: "openclaw-zai",
        name: "OpenClaw Z.AI",
        adapter: "openclaw",
        posture: "Gateway",
        description: "Routes through OpenClaw with the Z.AI provider profile.",
        config: %{
          "provider" => "zai",
          "model" => "zai/glm-4.7",
          "agent_runtime" => "subagent"
        },
        runtime_config: %{}
      },
      %{
        id: "openclaw-minimax",
        name: "OpenClaw MiniMax",
        adapter: "openclaw",
        posture: "Gateway",
        description: "Routes through OpenClaw with a MiniMax provider profile.",
        config: %{
          "provider" => "minimax",
          "model" => "minimax/MiniMax-M2.7-highspeed",
          "agent_runtime" => "subagent"
        },
        runtime_config: %{}
      },
      %{
        id: "process-codex",
        name: "Process Codex CLI",
        adapter: "process",
        posture: "Local process",
        description: "Runs Codex as a generic process adapter with lower-cost model forwarding.",
        config:
          Map.merge(Cympho.Adapters.RuntimeOptions.process_defaults("codex"), %{
            "process_preset" => "codex",
            "model" => "gpt-5.4-mini"
          }),
        runtime_config: %{}
      }
    ]
  end

  def options do
    Enum.map(all(), &{&1.name, &1.id})
  end

  def quick_presets, do: @quick_presets

  def quick_preset(id) when is_binary(id), do: Enum.find(@quick_presets, &(&1.id == id))
  def quick_preset(_), do: nil

  def max_concurrent_jobs_for_profile(profile_id, fallback \\ nil) do
    profile_id = normalize_id(profile_id)

    @quick_presets
    |> Enum.find(&(&1.profile_id == profile_id))
    |> case do
      %{max_concurrent_jobs: max_jobs} -> max_jobs
      _ -> fallback
    end
  end

  def get(id) do
    id = normalize_id(id)
    Enum.find(all(), &(&1.id == id))
  end

  def get!(id), do: get(id) || get!(@custom_id)

  def known?(id), do: not is_nil(get(id))

  def custom?(id), do: normalize_id(id) == @custom_id

  def normalize_id(nil), do: @custom_id
  def normalize_id(""), do: @custom_id

  def normalize_id(id) when is_atom(id),
    do: id |> Atom.to_string() |> normalize_id()

  def normalize_id(id) when is_binary(id) do
    if Enum.any?(all(), &(&1.id == id)), do: id, else: @custom_id
  end

  def normalize_id(_), do: @custom_id

  def from_agent(%{runtime_config: runtime_config, config: config}) do
    normalize_id(
      Map.get(runtime_config || %{}, "profile_id") ||
        Map.get(config || %{}, "runtime_profile_id")
    )
  end

  def adapter_for(profile_id, fallback_adapter) do
    case get!(profile_id) do
      %{adapter: adapter} when is_binary(adapter) and adapter != "" -> adapter
      _ -> fallback_adapter
    end
  end

  def config(profile_id), do: get!(profile_id).config || %{}
  def runtime_config(profile_id), do: get!(profile_id).runtime_config || %{}

  def fallback_profile_ids(agent_or_profile_id)

  def fallback_profile_ids(%{runtime_config: runtime_config, config: config} = agent) do
    current = from_agent(agent)

    explicit =
      first_present_list([
        map_get(runtime_config || %{}, "fallback_profile_ids"),
        map_get(runtime_config || %{}, "fallback_profiles"),
        map_get(runtime_config || %{}, "fallback_runtime_profile_ids"),
        map_get(config || %{}, "fallback_profile_ids"),
        map_get(config || %{}, "fallback_profiles"),
        map_get(config || %{}, "fallback_runtime_profile_ids")
      ])

    ids =
      case explicit do
        [] -> Map.get(@default_fallback_chains, current, [])
        ids -> ids
      end

    normalize_fallback_ids(ids, current)
  end

  def fallback_profile_ids(profile_id) do
    profile_id = normalize_id(profile_id)

    profile_id
    |> then(&Map.get(@default_fallback_chains, &1, []))
    |> normalize_fallback_ids(profile_id)
  end

  def summary_value(%{config: config, runtime_config: runtime_config}) do
    runtime_env = runtime_env_from_profile(%{runtime_config: runtime_config})

    cond do
      present?(config["model"]) -> "Model #{config["model"]}"
      present?(runtime_env["ANTHROPIC_MODEL"]) -> "Model #{runtime_env["ANTHROPIC_MODEL"]}"
      present?(config["command"]) -> "Command #{config["command"]}"
      true -> "Adapter defaults"
    end
  end

  def summary_value(%{config: config}) do
    cond do
      present?(config["model"]) -> "Model #{config["model"]}"
      present?(config["command"]) -> "Command #{config["command"]}"
      true -> "Adapter defaults"
    end
  end

  defp runtime_env_from_profile(%{runtime_config: %{} = runtime_config}) do
    Map.get(runtime_config, "env") || Map.get(runtime_config, :env) || %{}
  end

  defp runtime_env_from_profile(_profile), do: %{}

  defp first_present_list(values) do
    Enum.find_value(values, [], fn value ->
      ids = normalize_list(value)
      if ids == [], do: nil, else: ids
    end)
  end

  defp normalize_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_list/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_list(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_list(value) when is_atom(value), do: [Atom.to_string(value)]
  defp normalize_list(_), do: []

  defp normalize_fallback_ids(ids, current) do
    ids
    |> normalize_list()
    |> Enum.map(&normalize_id/1)
    |> Enum.reject(&(&1 in [@custom_id, current]))
    |> Enum.uniq()
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, existing_atom_key(key))
  end

  defp map_get(_map, _key), do: nil

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom_key(key), do: key

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
