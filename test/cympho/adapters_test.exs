defmodule Cympho.AdaptersTest do
  use ExUnit.Case, async: true

  alias Cympho.Adapters
  alias Cympho.Adapters.Registry

  describe "list_adapters/0" do
    test "returns all registered adapters" do
      adapters = Adapters.list_adapters()

      assert is_list(adapters)
      assert length(adapters) > 0

      Enum.each(adapters, fn adapter ->
        assert Map.has_key?(adapter, :key)
        assert Map.has_key?(adapter, :name)
        assert Map.has_key?(adapter, :module)
        assert Map.has_key?(adapter, :available)
        assert Map.has_key?(adapter, :config_schema)
        assert is_atom(adapter.key)
        assert is_binary(adapter.name)
        assert is_atom(adapter.module)
        assert is_boolean(adapter.available)
        assert is_list(adapter.config_schema)
      end)
    end

    test "includes all expected adapters" do
      adapters = Adapters.list_adapters()
      adapter_keys = Enum.map(adapters, & &1.key)

      assert :claude_code in adapter_keys
      assert :codex in adapter_keys
      assert :cursor in adapter_keys
      assert :http in adapter_keys
      assert :process in adapter_keys
    end
  end

  describe "get_adapter/1" do
    test "returns adapter for valid key" do
      assert {:ok, adapter} = Adapters.get_adapter(:claude_code)
      assert adapter.key == :claude_code
      assert adapter.name == "Claude Code"
      assert is_atom(adapter.module)
      assert is_list(adapter.config_schema)
    end

    test "returns error for invalid key" do
      assert {:error, :not_found} = Adapters.get_adapter(:nonexistent_adapter)
    end
  end

  describe "check_health/2" do
    test "returns health result for claude_code adapter" do
      result = Adapters.check_health(:claude_code)

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :checked_at)
      assert result.status in [:healthy, :degraded, :unhealthy, :unknown]
    end

    test "returns unknown status for unregistered adapter" do
      result = Adapters.check_health(:fake_adapter)
      assert result.status == :unknown
      assert result.message =~ "not registered"
    end
  end

  describe "check_all_health/0" do
    test "returns health status for all adapters" do
      health_map = Adapters.check_all_health()

      assert is_map(health_map)
      assert map_size(health_map) > 0

      Enum.each(health_map, fn {key, result} ->
        assert is_atom(key)
        assert Map.has_key?(result, :status)
        assert Map.has_key?(result, :checked_at)
      end)
    end
  end

  describe "validate_config/2" do
    test "validates claude_code config with valid data" do
      assert :ok = Adapters.validate_config(:claude_code, %{stall_timeout: 60_000})
    end

    test "validates claude_code config with invalid stall_timeout" do
      assert {:error, _} = Adapters.validate_config(:claude_code, %{stall_timeout: -1})
      assert {:error, _} = Adapters.validate_config(:claude_code, %{stall_timeout: "invalid"})
    end

    test "validates http adapter config with valid data" do
      config = %{
        url: "https://example.com/webhook",
        method: "post",
        timeout: 30_000
      }

      assert :ok = Adapters.validate_config(:http, config)
    end

    test "validates http adapter config with invalid url" do
      assert {:error, _} = Adapters.validate_config(:http, %{url: "not-a-url"})
      assert {:error, _} = Adapters.validate_config(:http, %{url: ""})
    end

    test "validates process adapter config with valid data" do
      config = %{
        command: "/bin/echo",
        args: ["hello"],
        timeout: 5000
      }

      assert :ok = Adapters.validate_config(:process, config)
    end

    test "validates process adapter config without command" do
      assert {:error, _} = Adapters.validate_config(:process, %{timeout: 5000})
    end

    test "returns error for unknown adapter" do
      assert {:error, _} = Adapters.validate_config(:fake, %{})
    end
  end

  describe "config_schema/1" do
    test "returns schema for claude_code adapter" do
      assert {:ok, schema} = Adapters.config_schema(:claude_code)
      assert is_list(schema)
      assert length(schema) > 0

      Enum.each(schema, fn entry ->
        assert Map.has_key?(entry, :key)
        assert Map.has_key?(entry, :type)
        assert Map.has_key?(entry, :required)
        assert Map.has_key?(entry, :description)
      end)
    end

    test "returns error for unknown adapter" do
      assert {:error, :not_found} = Adapters.config_schema(:fake_adapter)
    end
  end

  describe "Registry" do
    test "registers and looks up adapters" do
      assert {:ok, _} = Registry.lookup(:claude_code)
      assert :error = Registry.lookup(:fake_adapter)
    end

    test "returns default adapter" do
      default = Registry.default_adapter()
      assert is_atom(default)
    end

    test "resolves adapter key to module" do
      assert {:ok, module} = Registry.resolve(:claude_code)
      assert is_atom(module)
    end

    test "resolves nil to default adapter" do
      assert {:ok, _} = Registry.resolve(nil)
    end
  end
end
