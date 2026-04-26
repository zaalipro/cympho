defmodule Cympho.AgentAdaptersTest do
  use ExUnit.Case, async: false

  alias Cympho.AgentAdapters

  defmodule MockAdapter do
    @behaviour Cympho.AgentAdapters.Adapter

    @impl true
    def run(_issue, _agent_id, recipient_pid, _opts) do
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

  defmodule BadConfigAdapter do
    @behaviour Cympho.AgentAdapters.Adapter

    @impl true
    def run(_issue, _agent_id, _recipient_pid, _opts), do: make_ref()

    @impl true
    def available?(_config), do: true

    @impl true
    def health_check(_config) do
      %{status: :healthy, message: nil, checked_at: DateTime.utc_now()}
    end

    @impl true
    def type, do: :bad_config

    @impl true
    def validate_config(%{invalid: true}), do: {:error, "invalid config"}
    def validate_config(_config), do: :ok
  end

  defmodule NotAnAdapter do
    def some_function, do: :ok
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
    after
      # Restore mock for other tests
      AgentAdapters.register(:mock, MockAdapter)
    end
  end

  describe "all_types/0" do
    test "returns list including registered type atoms" do
      AgentAdapters.register(:mock, MockAdapter)
      types = AgentAdapters.all_types()
      assert is_list(types)
      assert :mock in types
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

    test "resolves agent without config key using empty config" do
      AgentAdapters.register(:mock, MockAdapter)

      agent = %{adapter: :mock}
      assert {:ok, MockAdapter, %{}} = AgentAdapters.resolve(agent)
    end

    test "returns error when adapter type is not registered" do
      agent = %{adapter: :nonexistent, config: %{}}
      assert {:error, :no_adapter} = AgentAdapters.resolve(agent)
    end

    test "rejects adapter with invalid config via validate_config" do
      AgentAdapters.register(:bad_config, BadConfigAdapter)

      agent = %{adapter: :bad_config, config: %{invalid: true}}
      assert {:error, :no_adapter} = AgentAdapters.resolve(agent)
    end

    test "accepts adapter with valid config via validate_config" do
      AgentAdapters.register(:bad_config, BadConfigAdapter)

      agent = %{adapter: :bad_config, config: %{valid: true}}
      assert {:ok, BadConfigAdapter, %{valid: true}} = AgentAdapters.resolve(agent)
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
      assert {:error, _} = BadConfigAdapter.validate_config(%{invalid: true})
    end

    test "run/4 returns a reference and sends session_started" do
      ref = MockAdapter.run(%{id: "1"}, "agent-1", self(), [])
      assert is_reference(ref)
      assert_receive {:session_started, _pid}
    end
  end
end
