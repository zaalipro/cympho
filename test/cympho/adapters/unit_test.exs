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
      assert result.status in [:healthy, :degraded, :unhealthy]
    end

    test "type/0 returns :codex" do
      assert CodexAdapter.type() == :codex
    end

    test "available?/1 with api key returns true" do
      assert CodexAdapter.available?(%{api_key: "sk-test"}) == true
    end

    test "available?/1 without api key returns false" do
      assert CodexAdapter.available?(%{}) == false
    end

    test "run/4 returns a reference" do
      issue = %{id: "issue-1", title: "Test", description: "Do something"}
      ref = CodexAdapter.run(issue, "agent-1", self(), config: %{api_key: "sk-test"})
      assert is_reference(ref)
    end

    test "run/4 sends session_started message" do
      issue = %{id: "issue-1", title: "Test", description: "Do something"}
      _ref = CodexAdapter.run(issue, "agent-1", self(), config: %{api_key: "sk-test", timeout: 500})
      assert_receive {:session_started, _session_id}, 1000
    end

    test "validate_config/1 accepts atom and string keys" do
      assert :ok = CodexAdapter.validate_config(%{"api_key" => "sk-test"})
      assert :ok = CodexAdapter.validate_config(%{api_key: "sk-test"})
    end

    test "health_check/1 with api key reports healthy or degraded" do
      result = CodexAdapter.health_check(%{api_key: "sk-test"})
      assert result.status in [:healthy, :degraded]
    end

    test "health_check/1 without api key reports unhealthy" do
      result = CodexAdapter.health_check(%{})
      assert result.status == :unhealthy
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

    test "health_check/1 returns health result" do
      result = ProcessAdapter.health_check(%{command: "ls"})

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :checked_at)
      assert result.status in [:healthy, :degraded, :unhealthy]
    end
  end
end
