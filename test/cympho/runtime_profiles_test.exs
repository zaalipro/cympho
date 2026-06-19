defmodule Cympho.RuntimeProfilesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Adapters.RuntimeOptions
  alias Cympho.RuntimeProfiles

  describe "catalog" do
    test "normalizes unknown profile ids to custom" do
      assert RuntimeProfiles.normalize_id(nil) == "custom"
      assert RuntimeProfiles.normalize_id("") == "custom"
      assert RuntimeProfiles.normalize_id("missing") == "custom"
    end

    test "exposes adapter defaults for built-in profiles" do
      profile = RuntimeProfiles.get!("codex-gpt-5.5")

      assert profile.adapter == "codex"
      assert profile.config["provider"] == "openai-codex"
      assert profile.config["model"] == "gpt-5.5"
      assert RuntimeProfiles.summary_value(profile) == "Model gpt-5.5"
    end

    test "exposes non-secret DashScope Qwen defaults" do
      profile = RuntimeProfiles.get!("openai-chat-qwen-dashscope")

      assert profile.adapter == "openai_chat"
      assert profile.config["model"] == "qwen3.7-plus"

      assert profile.config["endpoint"] ==
               "https://dashscope.aliyuncs.com/compatible-mode/v1"

      assert profile.description =~ "Add DASHSCOPE_API_KEY"
      assert profile.description =~ "accepted aliases"
      refute Map.has_key?(profile.config, "api_key")
      assert RuntimeProfiles.summary_value(profile) == "Model qwen3.7-plus"
    end

    test "exposes non-secret low-cost DashScope Qwen flash defaults" do
      profile = RuntimeProfiles.get!("openai-chat-qwen-dashscope-flash")

      assert profile.adapter == "openai_chat"
      assert profile.posture == "Low-cost gateway"
      assert profile.config["model"] == "qwen3.6-flash"

      assert profile.config["endpoint"] ==
               "https://dashscope.aliyuncs.com/compatible-mode/v1"

      assert profile.description =~ "cheap CEO smoke tests"
      assert profile.description =~ "Add DASHSCOPE_API_KEY"
      refute Map.has_key?(profile.config, "api_key")
      assert RuntimeProfiles.summary_value(profile) == "Model qwen3.6-flash"
    end

    test "exposes non-secret DashScope international Qwen defaults" do
      profile = RuntimeProfiles.get!("openai-chat-qwen-dashscope-intl")

      assert profile.adapter == "openai_chat"
      assert profile.config["model"] == "qwen3.7-plus"

      assert profile.config["endpoint"] ==
               "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"

      refute Map.has_key?(profile.config, "api_key")
      assert RuntimeProfiles.summary_value(profile) == "Model qwen3.7-plus"
    end

    test "resolves selected agent profile from runtime_config" do
      agent = %{
        runtime_config: %{"profile_id" => "claude-cm"},
        config: %{"runtime_profile_id" => "codex-mini"}
      }

      assert RuntimeProfiles.from_agent(agent) == "claude-cm"
    end

    test "resolves explicit fallback profile chains before catalog defaults" do
      agent = %{
        runtime_config: %{
          "profile_id" => "codex-gpt-5.5",
          "fallback_profile_ids" => ["openai-chat-qwen-dashscope-flash", "missing", "custom"]
        },
        config: %{}
      }

      assert RuntimeProfiles.fallback_profile_ids(agent) == ["openai-chat-qwen-dashscope-flash"]
    end

    test "provides bounded catalog fallback chains" do
      assert RuntimeProfiles.fallback_profile_ids("codex-gpt-5.5") == [
               "codex-mini",
               "process-codex"
             ]

      assert RuntimeProfiles.fallback_profile_ids("custom") == []
    end

    test "profile adapter overrides stale adapter form values" do
      assert RuntimeProfiles.adapter_for("openclaw-zai", "claude_code") == "openclaw"
      assert RuntimeProfiles.adapter_for("custom", "codex") == "codex"
    end

    test "process runtime options expose researched CLI presets" do
      preset_values =
        RuntimeOptions.process_preset_options()
        |> Enum.map(fn {_label, value} -> value end)

      assert "antigravity" in preset_values
      assert "kimi_code" in preset_values
      assert "cline" in preset_values
      assert "gemini" in preset_values
      assert "aider" in preset_values
      assert "opencode" in preset_values

      assert RuntimeOptions.process_defaults("kimi_code")["prompt_arg_template"] == [
               "-p",
               "{{prompt}}",
               "--output-format",
               "stream-json"
             ]

      assert RuntimeOptions.process_defaults("cline")["args"] == ["--json"]

      assert RuntimeOptions.process_defaults("opencode")["args"] == [
               "run",
               "--format",
               "json",
               "--quiet"
             ]
    end

    test "quick presets map to profiles and safe concurrency" do
      assert %{profile_id: "codex-mini", max_concurrent_jobs: 1} =
               RuntimeProfiles.quick_preset("low_ram")

      assert %{profile_id: "openai-chat-qwen-dashscope-flash", max_concurrent_jobs: 1} =
               RuntimeProfiles.quick_preset("qwen_dashscope_flash")

      assert RuntimeProfiles.max_concurrent_jobs_for_profile("openai-chat-qwen-dashscope-flash") ==
               1

      assert %{profile_id: "openai-chat-qwen-dashscope", max_concurrent_jobs: 1} =
               RuntimeProfiles.quick_preset("qwen_dashscope")

      assert RuntimeProfiles.max_concurrent_jobs_for_profile("openai-chat-qwen-dashscope") == 1

      assert %{profile_id: "openai-chat-qwen-dashscope-intl", max_concurrent_jobs: 1} =
               RuntimeProfiles.quick_preset("qwen_dashscope_intl")

      assert RuntimeProfiles.max_concurrent_jobs_for_profile("openai-chat-qwen-dashscope-intl") ==
               1

      assert %{profile_id: "process-codex", max_concurrent_jobs: 1} =
               RuntimeProfiles.quick_preset("provider_test")

      assert RuntimeProfiles.get!("process-codex").config["model"] == "gpt-5.4-mini"

      assert is_nil(RuntimeProfiles.quick_preset("missing"))
      assert RuntimeProfiles.max_concurrent_jobs_for_profile("custom", 3) == 3
    end
  end
end
