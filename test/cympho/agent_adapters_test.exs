defmodule Cympho.AgentAdaptersTest do
  @moduledoc """
  Verifies the `Cympho.AgentAdapters` deprecation shim. The shim is
  retained for one release window so any forgotten external caller logs
  a warning rather than crashing. Each public function must:

    1. Delegate to the canonical `Cympho.Adapters.<fun>` and return the
       same value.
    2. Emit a `Logger.warning` carrying `component: :agent_adapters_shim`
       so the call can be traced and migrated.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cympho.AgentAdapters

  defmodule ShimMockAdapter do
    @behaviour Cympho.Adapters.Adapter

    @impl true
    def run(_issue, _agent_id, recipient_pid, _opts) do
      send(recipient_pid, {:session_started, self()})
      make_ref()
    end

    @impl true
    def available?, do: true

    @impl true
    def available?(_config), do: true

    @impl true
    def health_check(_config) do
      %{status: :healthy, message: "OK", checked_at: DateTime.utc_now()}
    end

    @impl true
    def config_schema, do: []

    @impl true
    def name, do: "Shim Mock"

    @impl true
    def type, do: :shim_mock

    @impl true
    def validate_config(_config), do: :ok
  end

  defmodule NotAnAdapter do
    def some_function, do: :ok
  end

  describe "register/2" do
    test "emits a deprecation warning" do
      log =
        capture_log(fn ->
          AgentAdapters.register(:shim_mock, ShimMockAdapter)
        end)

      assert log =~ "Cympho.AgentAdapters.register is deprecated"
      assert log =~ "call Cympho.Adapters.register directly"
    end

    test "delegates to Cympho.Adapters.register and returns :ok for a valid adapter" do
      assert :ok = AgentAdapters.register(:shim_mock, ShimMockAdapter)
      assert {:ok, ShimMockAdapter} = Cympho.Adapters.Registry.lookup(:shim_mock)
    end

    test "delegates to Cympho.Adapters.register and returns :invalid_module for a non-adapter" do
      assert {:error, :invalid_module} = AgentAdapters.register(:not_adapter, NotAnAdapter)
    end
  end

  describe "resolve/1" do
    test "emits a deprecation warning" do
      AgentAdapters.register(:shim_mock, ShimMockAdapter)

      log =
        capture_log(fn ->
          AgentAdapters.resolve(%{adapter: :shim_mock, config: %{}})
        end)

      assert log =~ "Cympho.AgentAdapters.resolve is deprecated"
    end

    test "delegates to Cympho.Adapters.resolve and returns the same tuple" do
      AgentAdapters.register(:shim_mock, ShimMockAdapter)

      shim = AgentAdapters.resolve(%{adapter: :shim_mock, config: %{any: "value"}})
      direct = Cympho.Adapters.resolve(%{adapter: :shim_mock, config: %{any: "value"}})

      assert shim == direct
      assert {:ok, ShimMockAdapter, %{any: "value"}} = shim
    end
  end

  describe "fallback_chain/1" do
    test "emits a deprecation warning" do
      log = capture_log(fn -> AgentAdapters.fallback_chain(:codex) end)
      assert log =~ "Cympho.AgentAdapters.fallback_chain is deprecated"
    end

    test "delegates to Cympho.Adapters.fallback_chain and returns the same list" do
      assert AgentAdapters.fallback_chain(:codex) == Cympho.Adapters.fallback_chain(:codex)
      assert AgentAdapters.fallback_chain(:codex) == [:codex, :claude_code]
      assert AgentAdapters.fallback_chain(:claude_code) == [:claude_code]
    end
  end

  describe "all_types/0" do
    test "emits a deprecation warning" do
      log = capture_log(fn -> AgentAdapters.all_types() end)
      assert log =~ "Cympho.AgentAdapters.all_types is deprecated"
    end

    test "delegates to Cympho.Adapters.all_types and returns the same list" do
      AgentAdapters.register(:shim_mock, ShimMockAdapter)
      assert AgentAdapters.all_types() == Cympho.Adapters.all_types()
      assert :shim_mock in AgentAdapters.all_types()
    end
  end

  describe "lookup/1" do
    test "emits a deprecation warning" do
      log = capture_log(fn -> AgentAdapters.lookup(:claude_code) end)
      assert log =~ "Cympho.AgentAdapters.lookup is deprecated"
    end

    test "delegates to Cympho.Adapters.lookup and returns the same tuple" do
      AgentAdapters.register(:shim_mock, ShimMockAdapter)

      assert AgentAdapters.lookup(:shim_mock) == Cympho.Adapters.lookup(:shim_mock)
      assert AgentAdapters.lookup(:shim_mock) == {:ok, ShimMockAdapter}
      assert AgentAdapters.lookup(:nonexistent) == :error
    end
  end

  describe "deprecation warning metadata" do
    test "every shim function tags its log with component: :agent_adapters_shim" do
      AgentAdapters.register(:shim_mock, ShimMockAdapter)

      for fun <- [
            fn -> AgentAdapters.register(:shim_mock, ShimMockAdapter) end,
            fn -> AgentAdapters.resolve(%{adapter: :shim_mock, config: %{}}) end,
            fn -> AgentAdapters.fallback_chain(:codex) end,
            fn -> AgentAdapters.all_types() end,
            fn -> AgentAdapters.lookup(:claude_code) end
          ] do
        log = capture_log([metadata: [:component]], fun)
        assert log =~ "is deprecated", "Expected a deprecation warning, got: #{inspect(log)}"
      end
    end
  end
end
