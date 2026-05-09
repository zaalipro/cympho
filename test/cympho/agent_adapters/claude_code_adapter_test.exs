defmodule Cympho.AgentAdapters.ClaudeCodeAdapterTest do
  use ExUnit.Case, async: false

  alias Cympho.AgentAdapters.ClaudeCodeAdapter

  describe "type/0" do
    test "returns :claude_code" do
      assert ClaudeCodeAdapter.type() == :claude_code
    end
  end

  describe "available?/1" do
    test "returns boolean" do
      result = ClaudeCodeAdapter.available?(%{})
      assert is_boolean(result)
    end

    test "returns false when API key is missing from config and env" do
      original = Application.get_env(:cympho, :anthropic_api_key)
      original_env = System.get_env("ANTHROPIC_API_KEY")

      Application.delete_env(:cympho, :anthropic_api_key)
      System.delete_env("ANTHROPIC_API_KEY")

      # The result depends on whether claude is in PATH, but without API key
      # it should be false regardless
      refute ClaudeCodeAdapter.available?(%{})

      # Restore
      if original, do: Application.put_env(:cympho, :anthropic_api_key, original)
      if original_env, do: System.put_env("ANTHROPIC_API_KEY", original_env)
    end

    test "accepts config with explicit api_key" do
      result = ClaudeCodeAdapter.available?(%{api_key: "test-key-123"})
      # Will be false because claude binary likely not in test PATH,
      # but it should not crash
      assert is_boolean(result)
    end
  end

  describe "health_check/1" do
    test "returns map with required keys" do
      result = ClaudeCodeAdapter.health_check(%{})

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :message)
      assert Map.has_key?(result, :checked_at)
    end

    test "status is one of the valid values" do
      result = ClaudeCodeAdapter.health_check(%{})

      assert result.status in [:healthy, :degraded, :unhealthy, :unknown]
    end

    test "checked_at is a DateTime" do
      result = ClaudeCodeAdapter.health_check(%{})

      assert %DateTime{} = result.checked_at
    end

    test "returns unhealthy when API key is missing" do
      original = Application.get_env(:cympho, :anthropic_api_key)
      original_env = System.get_env("ANTHROPIC_API_KEY")

      Application.delete_env(:cympho, :anthropic_api_key)
      System.delete_env("ANTHROPIC_API_KEY")

      result = ClaudeCodeAdapter.health_check(%{})
      assert result.status == :unhealthy
      assert result.message =~ "ANTHROPIC_API_KEY"

      if original, do: Application.put_env(:cympho, :anthropic_api_key, original)
      if original_env, do: System.put_env("ANTHROPIC_API_KEY", original_env)
    end
  end

  describe "validate_config/1" do
    test "returns :ok for empty config" do
      assert :ok = ClaudeCodeAdapter.validate_config(%{})
    end

    test "returns :ok for valid stall_timeout" do
      assert :ok = ClaudeCodeAdapter.validate_config(%{stall_timeout: 60_000})
    end

    test "returns error for zero stall_timeout" do
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{stall_timeout: 0})
    end

    test "returns error for negative stall_timeout" do
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{stall_timeout: -1})
    end

    test "returns error for stall_timeout exceeding 1 hour" do
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{stall_timeout: 3_600_001})
    end

    test "returns error for non-integer stall_timeout" do
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{stall_timeout: "slow"})
    end

    test "returns :ok for valid cwd" do
      assert :ok = ClaudeCodeAdapter.validate_config(%{cwd: System.tmp_dir!()})
    end

    test "returns error for nonexistent cwd" do
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{cwd: "/no/such/directory"})
    end

    test "returns error for non-string cwd" do
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{cwd: 123})
    end

    test "returns :ok for resume true" do
      assert :ok = ClaudeCodeAdapter.validate_config(%{resume: true})
    end

    test "returns :ok for resume false" do
      assert :ok = ClaudeCodeAdapter.validate_config(%{resume: false})
    end

    test "returns error for non-boolean resume" do
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{resume: "yes"})
    end

    test "accepts keyword list config" do
      assert :ok =
               ClaudeCodeAdapter.validate_config(stall_timeout: 60_000, cwd: System.tmp_dir!())
    end
  end

  describe "run/4" do
    test "reports non-thinking non-json output as a parse error" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "cympho-claude-adapter-parse-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      script_path = Path.join(tmp_dir, "fake-claude")

      File.write!(script_path, """
      #!/usr/bin/env bash
      printf 'Plain progress line that is not JSON\\n'
      """)

      File.chmod!(script_path, 0o755)

      issue = %Cympho.Issues.Issue{
        id: Ecto.UUID.generate(),
        title: "Parser regression smoke test",
        description: "Confirm non-JSON output is not swallowed",
        lineage: %{}
      }

      session_id =
        ClaudeCodeAdapter.run(issue, Ecto.UUID.generate(), self(),
          command: script_path,
          cwd: tmp_dir
        )

      assert_receive {:session_started, ^session_id}, 5_000

      assert_receive {:turn_ended_with_error, ^session_id, {:parse_error, output}}, 5_000
      assert output =~ "Plain progress line"
    end

    test "passes runtime env into the adapter subprocess" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "cympho-claude-adapter-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      capture_path = Path.join(tmp_dir, "env.capture")
      script_path = Path.join(tmp_dir, "fake-claude")

      File.write!(script_path, """
      #!/usr/bin/env bash
      {
        echo "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"
        echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
        echo "ANTHROPIC_MODEL=$ANTHROPIC_MODEL"
      } > "#{capture_path}"
      printf '{"content":[{"type":"text","text":"ok"}]}'
      """)

      File.chmod!(script_path, 0o755)

      issue = %Cympho.Issues.Issue{
        id: Ecto.UUID.generate(),
        title: "Provider env smoke test",
        description: "Confirm env variables reach the subprocess",
        lineage: %{}
      }

      session_id =
        ClaudeCodeAdapter.run(issue, Ecto.UUID.generate(), self(),
          command: script_path,
          cwd: tmp_dir,
          env: %{
            "ANTHROPIC_BASE_URL" => "https://cheap-provider.example/anthropic",
            "ANTHROPIC_API_KEY" => "test-provider-key",
            "ANTHROPIC_MODEL" => "cheap-model"
          }
        )

      assert_receive {:session_started, ^session_id}, 5_000
      assert_receive {:turn_completed, ^session_id, %{"content" => [%{"text" => "ok"}]}}, 5_000

      assert File.read!(capture_path) =~
               "ANTHROPIC_BASE_URL=https://cheap-provider.example/anthropic"

      assert File.read!(capture_path) =~ "ANTHROPIC_API_KEY=test-provider-key"
      assert File.read!(capture_path) =~ "ANTHROPIC_MODEL=cheap-model"
    end
  end

  describe "behaviour compliance" do
    test "implements Cympho.AgentAdapters.Adapter" do
      behaviours =
        ClaudeCodeAdapter.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Cympho.AgentAdapters.Adapter in behaviours
    end

    test "exports all required callbacks" do
      callbacks = [
        {ClaudeCodeAdapter, :run, 4},
        {ClaudeCodeAdapter, :available?, 1},
        {ClaudeCodeAdapter, :health_check, 1},
        {ClaudeCodeAdapter, :type, 0},
        {ClaudeCodeAdapter, :validate_config, 1}
      ]

      Enum.each(callbacks, fn {mod, fun, arity} ->
        assert function_exported?(mod, fun, arity),
               "Expected #{inspect(mod)}.#{fun}/#{arity} to be exported"
      end)
    end
  end
end
