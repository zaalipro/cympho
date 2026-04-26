defmodule Cympho.AgentAdaptersTest do
  use ExUnit.Case, async: false

  alias Cympho.AgentAdapters

  # A mock adapter that satisfies the Adapter behaviour
  defmodule MockAdapter do
    @behaviour Cympho.AgentAdapters.Adapter

    @impl true
    def run(issue, agent_id, recipient_pid, _opts) do
      send(recipient_pid, {:session_started, self()})
      make_ref()
    end

    @impl true
    def available?(_config), do: true

    @impl true
    def health_check(_config) do
      %{status: :healthy, message: "OK", checked_at: DateTime.utc_now()}
    end

    @impl true
    def type, do: :mock

    @impl true
    def validate_config(_config), do: :ok
  end

  # A mock adapter that is always unavailable
  defmodule UnavailableAdapter do
    @behaviour Cympho.AgentAdapters.Adapter

    @impl true
    def run(_issue, _agent_id, _recipient_pid, _opts), do: make_ref()

    @impl true
    def available?(_config), do: false

    @impl true
    def health_check(_config) do
      %{status: :unhealthy, message: "Down", checked_at: DateTime.utc_now()}
    end

    @impl true
    def type, do: :unavailable

    @impl true
    def validate_config(_config), do: :ok
  end

  # A module that does NOT implement the behaviour — for register guard tests
  defmodule NotAnAdapter do
    def some_function, do: :ok
  end

  setup do
    # Clear the ETS table between tests
    :ets.delete_all_objects(Cympho.AgentAdapters)

    :ok
  end

  describe "register/2" do
    test "registers a valid adapter module" do
      assert :ok = AgentAdapters.register(:mock, MockAdapter)
      assert {:ok, MockAdapter} = AgentAdapters.lookup(:mock)
    end

    test "rejects a module that does not implement the behaviour" do
      assert {:error, :invalid_module} = AgentAdapters.register(:bad, NotAnAdapter)
      assert :error = AgentAdapters.lookup(:bad)
    end

    test "overwrites an existing registration" do
      :ok = AgentAdapters.register(:mock, MockAdapter)
      :ok = AgentAdapters.register(:mock, UnavailableAdapter)
      assert {:ok, UnavailableAdapter} = AgentAdapters.lookup(:mock)
    end

    test "registers multiple types" do
      :ok = AgentAdapters.register(:mock, MockAdapter)
      :ok = AgentAdapters.register(:unavailable, UnavailableAdapter)
      assert {:ok, MockAdapter} = AgentAdapters.lookup(:mock)
      assert {:ok, UnavailableAdapter} = AgentAdapters.lookup(:unavailable)
    end
  end

  describe "all_types/0" do
    test "returns empty list when nothing registered" do
      assert AgentAdapters.all_types() == []
    end

    test "returns sorted list of registered type atoms" do
      AgentAdapters.register(:beta, MockAdapter)
      AgentAdapters.register(:alpha, MockAdapter)

      assert AgentAdapters.all_types() == [:alpha, :beta]
    end
  end

  describe "lookup/1" do
    test "returns error for unregistered type" do
      assert :error = AgentAdapters.lookup(:nonexistent)
    end

    test "returns module for registered type" do
      AgentAdapters.register(:mock, MockAdapter)
      assert {:ok, MockAdapter} = AgentAdapters.lookup(:mock)
    end
  end

  describe "fallback_chain/1" do
    test "returns [primary, :claude_code] when primary is not claude_code" do
      assert AgentAdapters.fallback_chain(:codex) == [:codex, :claude_code]
    end

    test "returns [:claude_code] when primary is claude_code" do
      assert AgentAdapters.fallback_chain(:claude_code) == [:claude_code]
    end

    test "works with any atom" do
      assert AgentAdapters.fallback_chain(:cursor) == [:cursor, :claude_code]
      assert AgentAdapters.fallback_chain(:http) == [:http, :claude_code]
    end
  end

  describe "resolve/1" do
    test "resolves agent with registered adapter to module and config" do
      AgentAdapters.register(:mock, MockAdapter)

      agent = %{adapter: :mock, config: %{timeout: 5000}}
      assert {:ok, MockAdapter, %{timeout: 5000}} = AgentAdapters.resolve(agent)
    end

    test "resolves agent with nil adapter to default adapter when available" do
      AgentAdapters.register(:claude_code, MockAdapter)

      agent = %{adapter: nil, config: %{}}
      assert {:ok, MockAdapter, %{}} = AgentAdapters.resolve(agent)
    end

    test "resolves agent without config key using empty config" do
      AgentAdapters.register(:mock, MockAdapter)

      agent = %{adapter: :mock}
      assert {:ok, MockAdapter, %{}} = AgentAdapters.resolve(agent)
    end

    test "falls back through chain when primary is unavailable" do
      AgentAdapters.register(:unavailable, UnavailableAdapter)
      AgentAdapters.register(:claude_code, MockAdapter)

      agent = %{adapter: :unavailable, config: %{}}
      # Primary is unavailable, so fallback to :claude_code
      assert {:ok, MockAdapter, %{}} = AgentAdapters.resolve(agent)
    end

    test "returns error when no adapter in chain is available" do
      AgentAdapters.register(:unavailable, UnavailableAdapter)

      agent = %{adapter: :unavailable, config: %{}}
      assert {:error, :no_adapter} = AgentAdapters.resolve(agent)
    end

    test "returns error when adapter type is not registered" do
      agent = %{adapter: :nonexistent, config: %{}}
      assert {:error, :no_adapter} = AgentAdapters.resolve(agent)
    end
  end

  describe "Adapter behaviour compliance" do
    test "MockAdapter implements all required callbacks" do
      behaviours =
        MockAdapter.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Cympho.AgentAdapters.Adapter in behaviours
    end

    test "type/0 returns the adapter type atom" do
      assert MockAdapter.type() == :mock
      assert UnavailableAdapter.type() == :unavailable
    end

    test "available?/1 accepts config" do
      assert MockAdapter.available?(%{}) == true
      assert UnavailableAdapter.available?(%{}) == false
    end

    test "health_check/1 returns expected shape" do
      result = MockAdapter.health_check(%{})
      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :message)
      assert Map.has_key?(result, :checked_at)
      assert result.status in [:healthy, :degraded, :unhealthy, :unknown]
    end

    test "validate_config/1 returns ok or error tuple" do
      assert :ok = MockAdapter.validate_config(%{})
    end

    test "run/4 returns a reference and sends session_started" do
      ref = MockAdapter.run(%{id: "1"}, "agent-1", self(), [])
      assert is_reference(ref)
    end
  end
end
