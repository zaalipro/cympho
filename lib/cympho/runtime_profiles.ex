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
      id: "provider_test",
      name: "Provider test",
      profile_id: "process-codex",
      max_concurrent_jobs: 1,
      description: "Exercise a generic process adapter without opening broad concurrency."
    }
  ]

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
        description: "Runs Codex as a generic process adapter with model forwarding.",
        config:
          Map.merge(Cympho.Adapters.RuntimeOptions.process_defaults("codex"), %{
            "process_preset" => "codex",
            "model" => "gpt-5.5"
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

  def summary_value(%{config: config}) do
    cond do
      present?(config["model"]) -> "Model #{config["model"]}"
      present?(config["command"]) -> "Command #{config["command"]}"
      true -> "Adapter defaults"
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
