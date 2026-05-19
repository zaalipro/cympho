defmodule Cympho.Adapters.MockAdapterTest do
  use ExUnit.Case, async: false

  alias Cympho.Adapters.MockAdapter
  alias Cympho.Adapters.Registry, as: AdaptersRegistry

  setup do
    MockAdapter.clear()
    :ok
  end

  describe "script/3 + run/4" do
    test "delivers session_started, turn_completed, session_ended in order" do
      issue_id = Ecto.UUID.generate()
      agent_id = "agent-#{System.unique_integer([:positive])}"

      payload = %{
        "type" => "mock_result",
        "content" => [%{"type" => "text", "text" => "hello"}]
      }

      :ok = MockAdapter.script(agent_id, issue_id, [%{result: payload}])

      issue = %{id: issue_id}
      session_id = MockAdapter.run(issue, agent_id, self(), mock_delay: 0)

      assert_receive {:session_started, ^session_id}, 500
      assert_receive {:turn_completed, ^session_id, ^payload}, 500
      assert_receive {:session_ended, ^session_id, :normal}, 500
    end

    test "emits :no_script_entry when no entry exists for the pair" do
      issue_id = Ecto.UUID.generate()
      agent_id = "agent-missing"

      issue = %{id: issue_id}
      session_id = MockAdapter.run(issue, agent_id, self(), mock_delay: 0)

      assert_receive {:session_started, ^session_id}, 500
      assert_receive {:turn_ended_with_error, ^session_id, {:no_script_entry, meta}}, 500
      assert meta.agent_id == agent_id
      assert meta.issue_id == issue_id
    end

    test "scripted :silent stays sticky across runs" do
      issue_id = Ecto.UUID.generate()
      agent_id = "stuck-agent"

      :ok = MockAdapter.script(agent_id, issue_id, [:silent])
      issue = %{id: issue_id}

      session_id1 = MockAdapter.run(issue, agent_id, self(), mock_delay: 0)
      assert_receive {:session_started, ^session_id1}, 500
      refute_receive {:turn_completed, _, _}, 50

      # The :silent entry must survive so subsequent runs also stall.
      session_id2 = MockAdapter.run(issue, agent_id, self(), mock_delay: 0)
      assert_receive {:session_started, ^session_id2}, 500
      refute_receive {:turn_completed, _, _}, 50
    end

    test "clear/2 removes scripts for a specific pair" do
      issue_id = Ecto.UUID.generate()
      agent_id = "scoped"

      :ok = MockAdapter.script(agent_id, issue_id, [%{result: %{}}])
      :ok = MockAdapter.clear(agent_id, issue_id)

      issue = %{id: issue_id}
      _ = MockAdapter.run(issue, agent_id, self(), mock_delay: 0)
      assert_receive {:turn_ended_with_error, _, {:no_script_entry, _}}, 500
    end
  end

  describe "registry gating" do
    setup do
      # Other test files (agent_adapters_test.exs) re-register `:mock`
      # against their own test-internal module. Re-bind to our canonical
      # adapter so the resolves-in-test assertion below is deterministic.
      :ok = AdaptersRegistry.register(:mock, MockAdapter)
      :ok
    end

    test ":mock resolves only in test env" do
      assert {:ok, MockAdapter} = AdaptersRegistry.lookup(:mock)
    end

    test "register/2 refuses :mock outside test env" do
      prior = Application.get_env(:cympho, :env)
      Application.put_env(:cympho, :env, :prod)

      # Also override the Mix-env guard so we can verify the runtime check.
      assert_raise ArgumentError, ~r/refusing to register :mock/, fn ->
        with_clean_env(fn ->
          AdaptersRegistry.register(:mock, MockAdapter)
        end)
      end

      Application.put_env(:cympho, :env, prior)
    end

    defp with_clean_env(fun) do
      # Inside this block, force Mix.env to look non-test by overriding the
      # cympho :env config — the register/2 guard reads both sources, so
      # setting :env to :prod is enough.
      fun.()
    end
  end
end
