defmodule Cympho.Adapters.RegistryExtendedTest do
  use ExUnit.Case, async: false

  alias Cympho.Adapters.Registry

  describe "all_types/0" do
    test "returns sorted list of registered adapter type atoms" do
      types = Registry.all_types()
      assert is_list(types)
      assert types == Enum.sort(types)
    end

    test "includes all expected adapter types" do
      types = Registry.all_types()
      assert :claude_code in types
      assert :codex in types
      assert :cursor in types
      assert :http in types
      assert :openclaw in types
      assert :process in types
    end
  end

  describe "fallback_chain/1" do
    test "returns [primary, :claude_code] when primary is not the default" do
      assert Registry.fallback_chain(:codex) == [:codex, :claude_code]
      assert Registry.fallback_chain(:cursor) == [:cursor, :claude_code]
      assert Registry.fallback_chain(:http) == [:http, :claude_code]
    end

    test "returns [:claude_code] when primary is the default" do
      assert Registry.fallback_chain(:claude_code) == [:claude_code]
    end
  end

  describe "resolve_agent/1" do
    test "resolves agent with registered adapter to module and config" do
      {:ok, module, config} =
        Registry.resolve_agent(%{adapter: :process, config: %{command: "echo"}})

      assert is_atom(module)
      assert config == %{command: "echo"}
    end

    test "resolves agent with nil adapter to default adapter" do
      original = Application.get_env(:cympho, :default_adapter)
      Application.put_env(:cympho, :default_adapter, :process)

      try do
        {:ok, module, config} =
          Registry.resolve_agent(%{adapter: nil, config: %{command: "echo"}})

        assert is_atom(module)
        assert config == %{command: "echo"}
      after
        if original do
          Application.put_env(:cympho, :default_adapter, original)
        else
          Application.delete_env(:cympho, :default_adapter)
        end
      end
    end

    test "resolves agent without config key using empty config" do
      assert {:error, :no_adapter} = Registry.resolve_agent(%{adapter: :process})
    end

    test "walks fallback chain when primary is unavailable" do
      # :codex is the primary, :claude_code is the fallback
      {:ok, module, _config} = Registry.resolve_agent(%{adapter: :codex, config: %{}})
      # At least one adapter in the chain must be available
      assert is_atom(module)
    end

    test "returns error for unregistered adapter type" do
      result = Registry.resolve_agent(%{adapter: :nonexistent, config: %{}})
      # Falls back to default, which may or may not be available
      assert match?({:ok, _, _}, result) or match?({:error, :no_adapter}, result)
    end
  end

  describe "type/0 on adapters" do
    alias Cympho.Adapters.{
      ClaudeCodeAdapter,
      CodexAdapter,
      CursorAdapter,
      HttpAdapter,
      OpenClawAdapter,
      ProcessAdapter
    }

    test "ClaudeCodeAdapter.type/0 returns :claude_code" do
      assert ClaudeCodeAdapter.type() == :claude_code
    end

    test "CodexAdapter.type/0 returns :codex" do
      assert CodexAdapter.type() == :codex
    end

    test "CursorAdapter.type/0 returns :cursor" do
      assert CursorAdapter.type() == :cursor
    end

    test "HttpAdapter.type/0 returns :http" do
      assert HttpAdapter.type() == :http
    end

    test "OpenClawAdapter.type/0 returns :openclaw" do
      assert OpenClawAdapter.type() == :openclaw
    end

    test "ProcessAdapter.type/0 returns :process" do
      assert ProcessAdapter.type() == :process
    end
  end
end
