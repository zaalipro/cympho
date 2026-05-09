defmodule Cympho.Adapters.ConfigSafetyTest do
  use ExUnit.Case, async: true

  alias Cympho.Adapters.ClaudeCodeAdapter
  alias Cympho.Adapters.CodexAdapter
  alias Cympho.Adapters.CursorAdapter

  test "adapter config validation does not atomize unknown string keys" do
    unknown_key = "unknown_config_key_#{System.unique_integer([:positive])}"

    refute atom_exists?(unknown_key)

    assert :ok = ClaudeCodeAdapter.validate_config(%{unknown_key => "value"})
    assert :ok = CodexAdapter.validate_config(%{"api_key" => "test-key", unknown_key => "value"})
    assert :ok = CursorAdapter.validate_config(%{unknown_key => "value"})

    refute atom_exists?(unknown_key)
  end

  defp atom_exists?(key) do
    String.to_existing_atom(key)
    true
  rescue
    ArgumentError -> false
  end
end
