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

  describe "CodexAdapter — behaviour and metadata" do
    test "name/0 returns correct name" do
      assert CodexAdapter.name() == "OpenAI Codex"
    end

    test "type/0 returns :codex" do
      assert CodexAdapter.type() == :codex
    end

    test "implements Adapter behaviour" do
      behaviours =
        CodexAdapter.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Cympho.Adapters.Adapter in behaviours
    end
  end

  describe "CodexAdapter — config_schema" do
    test "returns valid schema with required api_key" do
      schema = CodexAdapter.config_schema()

      assert is_list(schema)
      assert length(schema) > 0

      api_key_entry = Enum.find(schema, fn e -> e.key == :api_key end)
      assert api_key_entry != nil
      assert api_key_entry.type == :string
      assert api_key_entry.required == true
    end

    test "includes model entry with o4-mini default" do
      schema = CodexAdapter.config_schema()
      model_entry = Enum.find(schema, fn e -> e.key == :model end)

      assert model_entry != nil
      assert model_entry.default == "o4-mini"
      assert model_entry.required == false
    end

    test "includes temperature entry" do
      schema = CodexAdapter.config_schema()
      temp_entry = Enum.find(schema, fn e -> e.key == :temperature end)

      assert temp_entry != nil
      assert temp_entry.type == :float
      assert temp_entry.default == 0.7
    end

    test "includes max_tokens and timeout entries" do
      schema = CodexAdapter.config_schema()
      tokens_entry = Enum.find(schema, fn e -> e.key == :max_tokens end)
      timeout_entry = Enum.find(schema, fn e -> e.key == :timeout end)

      assert tokens_entry != nil
      assert tokens_entry.type == :integer
      assert tokens_entry.default == 2000

      assert timeout_entry != nil
      assert timeout_entry.type == :integer
      assert timeout_entry.default == 300_000
    end
  end

  describe "CodexAdapter — validate_config" do
    test "with valid full config" do
      config = %{
        api_key: "sk-test-key",
        model: "gpt-4",
        temperature: 0.7,
        max_tokens: 2000
      }

      assert :ok = CodexAdapter.validate_config(config)
    end

    test "accepts atom and string keys" do
      assert :ok = CodexAdapter.validate_config(%{"api_key" => "sk-test"})
      assert :ok = CodexAdapter.validate_config(%{api_key: "sk-test"})
    end

    test "rejects missing api_key" do
      assert {:error, msg} = CodexAdapter.validate_config(%{model: "gpt-4"})
      assert msg =~ "api_key"
    end

    test "rejects non-string api_key" do
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: 123})
      assert msg =~ "api_key"
    end

    test "accepts nil model" do
      assert :ok = CodexAdapter.validate_config(%{api_key: "test"})
    end

    test "rejects non-string model" do
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: "test", model: 123})
      assert msg =~ "model"
    end

    test "rejects temperature above 2.0" do
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: "test", temperature: 3.0})
      assert msg =~ "temperature"
    end

    test "rejects negative temperature" do
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: "test", temperature: -0.1})
      assert msg =~ "temperature"
    end

    test "accepts boundary temperatures 0.0 and 2.0" do
      assert :ok = CodexAdapter.validate_config(%{api_key: "test", temperature: 0.0})
      assert :ok = CodexAdapter.validate_config(%{api_key: "test", temperature: 2.0})
    end

    test "accepts integer temperature" do
      assert :ok = CodexAdapter.validate_config(%{api_key: "test", temperature: 1})
    end

    test "rejects non-numeric temperature" do
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: "test", temperature: "hot"})
      assert msg =~ "temperature"
    end

    test "rejects non-positive max_tokens" do
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: "test", max_tokens: 0})
      assert msg =~ "max_tokens"
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: "test", max_tokens: -5})
      assert msg =~ "max_tokens"
    end

    test "rejects non-integer max_tokens" do
      assert {:error, msg} = CodexAdapter.validate_config(%{api_key: "test", max_tokens: 1.5})
      assert msg =~ "max_tokens"
    end

    test "accepts nil optional fields" do
      assert :ok = CodexAdapter.validate_config(%{api_key: "test", model: nil, temperature: nil, max_tokens: nil})
    end
  end

  describe "CodexAdapter — health_check" do
    test "returns well-formed result" do
      result = CodexAdapter.health_check(%{})

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :checked_at)
      assert Map.has_key?(result, :message)
      assert result.status in [:healthy, :degraded, :unhealthy]
      assert %DateTime{} = result.checked_at
    end

    test "without api key reports unhealthy" do
      result = CodexAdapter.health_check(%{})
      assert result.status == :unhealthy
      assert result.message =~ "API key"
    end

    test "with api key reports healthy or degraded" do
      result = CodexAdapter.health_check(%{api_key: "sk-test"})
      assert result.status in [:healthy, :degraded]
    end

    test "with empty api key reports unhealthy" do
      result = CodexAdapter.health_check(%{api_key: ""})
      assert result.status == :unhealthy
    end
  end

  describe "CodexAdapter — available?" do
    test "available?/1 without api key returns false" do
      assert CodexAdapter.available?(%{}) == false
    end

    test "available?/1 with empty api key returns false" do
      assert CodexAdapter.available?(%{api_key: ""}) == false
    end

    test "available?/1 with api key depends on binary presence" do
      has_codex = System.find_executable("codex") != nil
      result = CodexAdapter.available?(%{api_key: "sk-test"})

      if has_codex do
        assert result == true
      else
        assert result == false
      end
    end

    test "available?/0 delegates to available?/1" do
      assert CodexAdapter.available?() == CodexAdapter.available?(%{})
    end
  end

  describe "CodexAdapter — run/4" do
    test "returns a reference" do
      issue = %{id: "issue-1", title: "Test", description: "Do something"}
      ref = CodexAdapter.run(issue, "agent-1", self(), config: %{api_key: "sk-test"})
      assert is_reference(ref)
    end

    test "sends session_started message" do
      issue = %{id: "issue-1", title: "Test", description: "Do something"}
      _ref = CodexAdapter.run(issue, "agent-1", self(), config: %{api_key: "sk-test", timeout: 500})
      assert_receive {:session_started, session_id}, 1000
      assert is_reference(session_id)
    end

    test "sends turn_ended_with_error when codex binary not available" do
      has_codex = System.find_executable("codex") != nil

      unless has_codex do
        issue = %{id: "issue-1", title: "Test", description: "Do something"}
        _ref = CodexAdapter.run(issue, "agent-1", self(), config: %{api_key: "sk-test", timeout: 500})

        assert_receive {:session_started, _session_id}, 1000
        assert_receive {:turn_ended_with_error, _session_id, reason}, 2000
        assert is_binary(reason)
      end
    end

    test "works with string-keyed issue map" do
      issue = %{"id" => "issue-1", "title" => "Test", "description" => "Do something"}
      ref = CodexAdapter.run(issue, "agent-1", self(), config: %{api_key: "sk-test", timeout: 500})
      assert is_reference(ref)
      assert_receive {:session_started, _session_id}, 1000
    end

    test "works without config" do
      issue = %{id: "issue-1", title: "Test", description: "Do something"}
      ref = CodexAdapter.run(issue, "agent-1", self(), [])
      assert is_reference(ref)
      assert_receive {:session_started, _session_id}, 1000
    end
  end

  describe "CursorAdapter" do
    test "name/0 returns correct name" do
      assert CursorAdapter.name() == "Cursor IDE"
    end

    test "type/0 returns :cursor" do
      assert CursorAdapter.type() == :cursor
    end

    test "config_schema/0 returns valid schema with all entries" do
      schema = CursorAdapter.config_schema()

      assert is_list(schema)
      assert length(schema) == 5

      keys = Enum.map(schema, fn e -> e.key end)
      assert :cursor_path in keys
      assert :workspace_path in keys
      assert :model in keys
      assert :headless in keys
      assert :timeout in keys

      headless_entry = Enum.find(schema, fn e -> e.key == :headless end)
      assert headless_entry.type == :boolean
    end

    test "validate_config/1 with valid config" do
      assert :ok = CursorAdapter.validate_config(%{})
      assert :ok = CursorAdapter.validate_config(%{timeout: 60_000})
      assert :ok = CursorAdapter.validate_config(%{headless: true})
      assert :ok = CursorAdapter.validate_config(%{headless: false})
    end

    test "validate_config/1 accepts atom and string keys" do
      assert :ok = CursorAdapter.validate_config(%{"timeout" => 60_000})
      assert :ok = CursorAdapter.validate_config(%{timeout: 60_000})
    end

    test "validate_config/1 rejects negative timeout" do
      assert {:error, _} = CursorAdapter.validate_config(%{timeout: -1})
    end

    test "validate_config/1 rejects zero timeout" do
      assert {:error, _} = CursorAdapter.validate_config(%{timeout: 0})
    end

    test "validate_config/1 rejects timeout exceeding 1 hour" do
      assert {:error, _} = CursorAdapter.validate_config(%{timeout: 5_000_000})
    end

    test "validate_config/1 rejects non-integer timeout" do
      assert {:error, _} = CursorAdapter.validate_config(%{timeout: "slow"})
    end

    test "validate_config/1 rejects non-boolean headless" do
      assert {:error, _} = CursorAdapter.validate_config(%{headless: "yes"})
      assert {:error, _} = CursorAdapter.validate_config(%{headless: 1})
    end

    test "validate_config/1 rejects non-string cursor_path" do
      assert {:error, _} = CursorAdapter.validate_config(%{cursor_path: 123})
    end

    test "validate_config/1 rejects nonexistent cursor_path" do
      assert {:error, _} = CursorAdapter.validate_config(%{cursor_path: "/nonexistent/path/to/cursor"})
    end

    test "validate_config/1 rejects non-string workspace_path" do
      assert {:error, _} = CursorAdapter.validate_config(%{workspace_path: 123})
    end

    test "validate_config/1 rejects nonexistent workspace_path" do
      assert {:error, _} = CursorAdapter.validate_config(%{workspace_path: "/nonexistent/dir"})
    end

    test "health_check/1 returns well-formed result" do
      result = CursorAdapter.health_check(%{})

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :checked_at)
      assert Map.has_key?(result, :message)
      assert result.status in [:healthy, :unhealthy]
      assert %DateTime{} = result.checked_at
    end

    test "health_check/1 without cursor binary reports unhealthy" do
      has_cursor = System.find_executable("cursor") != nil

      unless has_cursor do
        assert CursorAdapter.health_check(%{}).status == :unhealthy
      end
    end

    test "health_check/1 with nonexistent cursor_path reports unhealthy" do
      result = CursorAdapter.health_check(%{cursor_path: "/nonexistent/path"})
      assert result.status == :unhealthy
    end

    test "available?/1 without cursor binary returns false" do
      has_cursor = System.find_executable("cursor") != nil

      unless has_cursor do
        assert CursorAdapter.available?(%{}) == false
      end
    end

    test "available?/1 with nonexistent cursor_path returns false" do
      assert CursorAdapter.available?(%{cursor_path: "/nonexistent/path"}) == false
    end

    test "available?/0 delegates to available?/1" do
      assert CursorAdapter.available?() == CursorAdapter.available?(%{})
    end

    test "run/4 returns a reference" do
      issue = %{id: "issue-1", title: "Test", description: "Do something"}
      ref = CursorAdapter.run(issue, "agent-1", self(), config: %{timeout: 500})
      assert is_reference(ref)
    end

    test "run/4 sends session_started message" do
      issue = %{id: "issue-1", title: "Test", description: "Do something"}
      _ref = CursorAdapter.run(issue, "agent-1", self(), config: %{timeout: 500})
      assert_receive {:session_started, session_id}, 1000
      assert is_reference(session_id)
    end

    test "run/4 sends error when cursor binary not available" do
      has_cursor = System.find_executable("cursor") != nil

      unless has_cursor do
        issue = %{id: "issue-1", title: "Test", description: "Do something"}
        _ref = CursorAdapter.run(issue, "agent-1", self(), config: %{timeout: 500})

        assert_receive {:session_started, _session_id}, 1000
        assert_receive {:turn_ended_with_error, _session_id, reason}, 2000
        assert is_binary(reason)
      end
    end

    test "run/4 works without config" do
      issue = %{id: "issue-1", title: "Test", description: "Do something"}
      ref = CursorAdapter.run(issue, "agent-1", self(), [])
      assert is_reference(ref)
      assert_receive {:session_started, _session_id}, 1000
    end

    test "run/4 works with string-keyed issue" do
      issue = %{"id" => "issue-1", "title" => "Test", "description" => "Do something"}
      ref = CursorAdapter.run(issue, "agent-1", self(), config: %{timeout: 500})
      assert is_reference(ref)
      assert_receive {:session_started, _session_id}, 1000
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

      # Use a shell command that prints the environment variable
      parent = self()
      config = %{
        command: "sh",
        args: ["-c", "echo $ISSUE_PAYLOAD"]
      }

      ref = ProcessAdapter.run(issue, agent_id, parent, config: config)

      assert is_reference(ref)

      assert_receive {:session_started, ^ref}
      assert_receive {:turn_completed, ^ref, result}

      # Verify that issue payload was passed in JSON format
      assert result.output =~ "ISSUE-123"
      assert result.output =~ "Test Issue"
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
