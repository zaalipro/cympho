defmodule Cympho.RuntimeProfilesTest do
  use Cympho.DataCase, async: true

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

    test "resolves selected agent profile from runtime_config" do
      agent = %{
        runtime_config: %{"profile_id" => "claude-cm"},
        config: %{"runtime_profile_id" => "codex-mini"}
      }

      assert RuntimeProfiles.from_agent(agent) == "claude-cm"
    end

    test "profile adapter overrides stale adapter form values" do
      assert RuntimeProfiles.adapter_for("openclaw-zai", "claude_code") == "openclaw"
      assert RuntimeProfiles.adapter_for("custom", "codex") == "codex"
    end

    test "quick presets map to profiles and safe concurrency" do
      assert %{profile_id: "codex-mini", max_concurrent_jobs: 1} =
               RuntimeProfiles.quick_preset("low_ram")

      assert %{profile_id: "process-codex", max_concurrent_jobs: 1} =
               RuntimeProfiles.quick_preset("provider_test")

      assert is_nil(RuntimeProfiles.quick_preset("missing"))
    end
  end
end
