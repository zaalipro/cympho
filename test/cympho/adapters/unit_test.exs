defmodule Cympho.Adapters.UnitTest do
  use ExUnit.Case, async: true

  # Unit tests that don't require database connection

  alias Cympho.Adapters.ClaudeCodeAdapter
  alias Cympho.Adapters.CodexAdapter
  alias Cympho.Adapters.CursorAdapter
  alias Cympho.Adapters.HttpAdapter
  alias Cympho.Adapters.ProcessAdapter

  describe "ClaudeCodeAdapter" do
    test "name/0 returns correct name" do
      assert ClaudeCodeAdapter.name() == "Claude Code"
    end

    test "config_schema/0 returns valid schema" do
      schema = ClaudeCodeAdapter.config_schema()

      assert is_list(schema)
      assert length(schema) > 0

      api_key_entry = Enum.find(schema, fn e -> e.key == :api_key end)
      assert api_key_entry != nil
      assert api_key_entry.type == :string
      assert api_key_entry.required == false
    end

    test "validate_config/1 with valid config" do
      assert :ok = ClaudeCodeAdapter.validate_config(%{stall_timeout: 60_000})
      assert :ok = ClaudeCodeAdapter.validate_config(%{})
    end

    test "validate_config/1 with invalid stall_timeout" do
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{stall_timeout: -1})
      assert {:error, _} = ClaudeCodeAdapter.validate_config(%{stall_timeout: "invalid"})
    end

    test "health_check/1 returns health result" do
      result = ClaudeCodeAdapter.health_check(%{})

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :checked_at)
      assert result.status in [:healthy, :unhealthy]
      assert is_binary(result.message)
    end
  end

  describe "CodexAdapter" do
    test "name/0 returns correct name" do
      assert CodexAdapter.name() == "OpenAI Codex"
    end

    test "config_schema/0 returns valid schema" do
      schema = CodexAdapter.config_schema()

      assert is_list(schema)
      assert length(schema) > 0

      api_key_entry = Enum.find(schema, fn e -> e.key == :api_key end)
      assert api_key_entry != nil
      assert api_key_entry.type == :string
      assert api_key_entry.required == true
    end

    test "validate_config/1 with valid config" do
      config = %{
        api_key: "sk-test-key",
        model: "gpt-4",
        temperature: 0.7,
        max_tokens: 2000
      }

      assert :ok = CodexAdapter.validate_config(config)
    end

    test "validate_config/1 without api_key" do
      assert {:error, _} = CodexAdapter.validate_config(%{model: "gpt-4"})
    end

    test "validate_config/1 with invalid temperature" do
      assert {:error, _} = CodexAdapter.validate_config(%{api_key: "test", temperature: 3.0})
      assert {:error, _} = CodexAdapter.validate_config(%{api_key: "test", temperature: -0.1})
    end

    test "health_check/1 returns health result" do
      result = CodexAdapter.health_check(%{})

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :checked_at)
      assert result.status in [:healthy, :unhealthy]
    end
  end

  describe "CursorAdapter" do
    test "name/0 returns correct name" do
      assert CursorAdapter.name() == "Cursor IDE"
    end

    test "config_schema/0 returns valid schema" do
      schema = CursorAdapter.config_schema()

      assert is_list(schema)
      assert length(schema) > 0
    end

    test "validate_config/1 with valid config" do
      assert :ok = CursorAdapter.validate_config(%{timeout: 60_000})
      assert :ok = CursorAdapter.validate_config(%{})
    end

    test "validate_config/1 with invalid timeout" do
      assert {:error, _} = CursorAdapter.validate_config(%{timeout: -1})
    end

    test "health_check/1 returns health result" do
      result = CursorAdapter.health_check(%{})

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :checked_at)
      assert result.status in [:healthy, :unhealthy]
    end
  end

  describe "HttpAdapter" do
    test "name/0 returns correct name" do
      assert HttpAdapter.name() == "HTTP Webhook"
    end

    test "config_schema/0 returns valid schema" do
      schema = HttpAdapter.config_schema()

      assert is_list(schema)
      assert length(schema) > 0

      url_entry = Enum.find(schema, fn e -> e.key == :url end)
      assert url_entry != nil
      assert url_entry.type == :string
      assert url_entry.required == true
    end

    test "validate_config/1 with valid config" do
      config = %{
        url: "https://example.com/webhook",
        method: "post",
        timeout: 30_000
      }

      assert :ok = HttpAdapter.validate_config(config)
    end

    test "validate_config/1 without url" do
      assert {:error, _} = HttpAdapter.validate_config(%{method: "post"})
    end

    test "validate_config/1 with invalid url" do
      assert {:error, _} = HttpAdapter.validate_config(%{url: "not-a-url"})
      assert {:error, _} = HttpAdapter.validate_config(%{url: "ftp://example.com"})
    end

    test "health_check/1 returns health result" do
      result = HttpAdapter.health_check(%{url: "https://example.com"})

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :checked_at)
    end
  end

  describe "ProcessAdapter" do
    test "name/0 returns correct name" do
      assert ProcessAdapter.name() == "Local Process"
    end

    test "type/0 returns process atom" do
      assert ProcessAdapter.type() == :process
    end

    test "config_schema/0 returns valid schema" do
      schema = ProcessAdapter.config_schema()

      assert is_list(schema)
      assert length(schema) > 0

      command_entry = Enum.find(schema, fn e -> e.key == :command end)
      assert command_entry != nil
      assert command_entry.type == :string
      assert command_entry.required == true
    end

    test "validate_config/1 with valid config" do
      config = %{
        command: "/bin/echo",
        args: ["hello"],
        timeout: 5000
      }

      assert :ok = ProcessAdapter.validate_config(config)
    end

    test "validate_config/1 without command" do
      assert {:error, _} = ProcessAdapter.validate_config(%{timeout: 5000})
    end

    test "validate_config/1 with invalid timeout" do
      assert {:error, _} = ProcessAdapter.validate_config(%{command: "test", timeout: 0})
      assert {:error, _} = ProcessAdapter.validate_config(%{command: "test", timeout: 4_000_000})
    end

    test "health_check/1 returns healthy for valid command" do
      result = ProcessAdapter.health_check(%{command: "ls"})

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :checked_at)
      assert result.status in [:healthy, :degraded, :unhealthy]
      assert result.status == :healthy
    end

    test "health_check/1 returns unhealthy when no command configured" do
      result = ProcessAdapter.health_check(%{})

      assert result.status == :unhealthy
      assert result.message == "No command configured"
    end

    test "health_check/1 returns degraded for missing command" do
      result = ProcessAdapter.health_check(%{command: "nonexistent_command_xyz"})

      assert result.status == :degraded
      assert String.contains?(result.message, "not found")
    end

    test "available?/0 returns true for process adapter" do
      assert ProcessAdapter.available?() == true
    end

    test "available?/1 returns false when no command configured" do
      refute ProcessAdapter.available?(%{})
      refute ProcessAdapter.available?(%{command: nil})
      refute ProcessAdapter.available?(%{command: ""})
    end

    test "available?/1 returns true when command exists in PATH" do
      assert ProcessAdapter.available?(%{command: "ls"})
      assert ProcessAdapter.available?(%{command: "echo"})
    end

    test "available?/1 returns false when command does not exist in PATH" do
      refute ProcessAdapter.available?(%{command: "nonexistent_command_xyz"})
    end

    test "run/4 spawns process and sends session_started" do
      issue = %{id: "ISSUE-1", title: "Test Issue", description: "Test"}
      agent_id = "agent-1"
      config = %{
        command: "echo",
        args: ["-n", "hello"]
      }

      parent = self()
      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert is_reference(ref)

      assert_receive {:session_started, ^ref}
      assert_receive {:turn_completed, ^ref, result}
      assert result.output =~ "hello"
    end

    test "run/4 passes issue payload as environment variable" do
      issue = %{
        id: "ISSUE-123",
        title: "Test Issue",
        description: "Test Description",
        status: "open",
        priority: "high"
      }
      agent_id = "agent-456"

      # Use /bin/echo to test basic process spawning with environment variables
      parent = self()
      config = %{
        command: "/bin/echo",
        args: ["test"]
      }

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert is_reference(ref)

      assert_receive {:session_started, ^ref}
      assert_receive {:turn_completed, ^ref, result}

      # Verify basic output works
      assert result.output =~ "test"

      # Now test with environment variable using a simple shell script
      parent = self()
      config = %{
        command: "/bin/sh",
        args: ["-c", "echo ${ISSUE_PAYLOAD}"]
      }

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert_receive {:session_started, ^ref}
      assert_receive {:turn_completed, ^ref, result}

      # Verify that issue payload was passed in JSON format
      # The output is valid JSON, so it's returned as a map
      assert is_map(result)
      assert result["id"] == "ISSUE-123"
      assert result["title"] == "Test Issue"
    end

    test "run/4 handles JSON output" do
      issue = %{id: "ISSUE-1", title: "Test", description: "Test"}
      agent_id = "agent-1"

      # Create a command that outputs JSON
      json_output = Jason.encode!(%{status: "success", data: "test result"})

      parent = self()
      config = %{
        command: "echo",
        args: [json_output]
      }

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert_receive {:session_started, ^ref}
      assert_receive {:turn_completed, ^ref, result}

      # JSON should be parsed into a map
      assert is_map(result)
      assert result.status == "success"
      assert result.data == "test result"
    end

    test "run/4 handles non-JSON output" do
      issue = %{id: "ISSUE-1", title: "Test", description: "Test"}
      agent_id = "agent-1"

      parent = self()
      config = %{
        command: "echo",
        args: ["plain text output"]
      }

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert_receive {:session_started, ^ref}
      assert_receive {:turn_completed, ^ref, result}

      # Non-JSON output should be returned as-is
      assert result.output =~ "plain text output"
      assert result.raw =~ "plain text output"
    end

    test "run/4 handles command errors" do
      issue = %{id: "ISSUE-1", title: "Test", description: "Test"}
      agent_id = "agent-1"

      parent = self()
      config = %{
        command: "ls",
        args: ["/nonexistent_directory_xyz"]
      }

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert_receive {:session_started, ^ref}
      assert_receive {:turn_ended_with_error, ^ref, {:exit_code, _code, _output}}
    end

    test "run/4 handles timeout" do
      issue = %{id: "ISSUE-1", title: "Test", description: "Test"}
      agent_id = "agent-1"

      parent = self()
      config = %{
        command: "sleep",
        args: ["10"],
        timeout: 100
      }

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert_receive {:session_started, ^ref}
      assert_receive {:turn_ended_with_error, ^ref, :timeout}
    end

    test "run/4 handles no command error" do
      issue = %{id: "ISSUE-1", title: "Test", description: "Test"}
      agent_id = "agent-1"

      parent = self()
      config = %{}

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert_receive {:turn_ended_with_error, ^ref, :no_command}
    end
  end
end
