defmodule Cympho.ConcurrencyPr3Test do
  @moduledoc """
  PR 3 (REQ-003) crash-safety: monotonic event ids across restart, and an
  adapter registry that tolerates the boot window without raising.
  """
  use ExUnit.Case, async: true

  alias Cympho.Adapters.Registry
  alias Cympho.EventStore

  describe "EventStore sequence (AC-017)" do
    test "event ids are wall-clock-seeded and strictly increasing" do
      topic = "company:#{Ecto.UUID.generate()}:issues"

      id1 = EventStore.append(topic, %{n: 1})
      id2 = EventStore.append(topic, %{n: 2})

      # A from-zero counter would yield tiny ids; the wall-clock seed makes them
      # large (~10^12), so a restart can't reuse ids reconnecting clients hold.
      assert id1 > 1_000_000_000_000
      assert id2 > id1
    end
  end

  describe "Adapters.Registry.lookup/1 (AC-015)" do
    test "resolves a registered adapter and returns :error (never raises) for unknown keys" do
      assert {:ok, _module} = Registry.lookup(:claude_code)
      assert :error = Registry.lookup(:does_not_exist)
    end
  end
end
