defmodule Cympho.AgentAdapters.MockAdapterTest do
  use ExUnit.Case, async: false

  alias Cympho.AgentAdapters.MockAdapter

  describe "type/0" do
    test "returns :mock" do
      assert MockAdapter.type() == :mock
    end
  end

  describe "available?/1" do
    test "always returns true" do
      assert MockAdapter.available?(%{}) == true
    end
  end

  describe "health_check/1" do
    test "returns healthy status" do
      result = MockAdapter.health_check(%{})

      assert result.status == :healthy
      assert Map.has_key?(result, :message)
      assert Map.has_key?(result, :checked_at)
      assert %DateTime{} = result.checked_at
    end
  end

  describe "validate_config/1" do
    test "always returns :ok" do
      assert :ok = MockAdapter.validate_config(%{})
      assert :ok = MockAdapter.validate_config(%{anything: "allowed"})
    end
  end

  describe "run/4 — message protocol" do
    test "sends session_started and turn_completed" do
      recipient = self()
      issue = %{id: "test-123", title: "Test Issue", description: "Test description"}

      session_id = MockAdapter.run(issue, "agent-1", recipient, mock_delay: 5)

      assert_receive {:session_started, ^session_id}
      assert_receive {:turn_completed, ^session_id, result}
      assert result["type"] == "mock_result"
    end

    test "sends tool_call_detected when include_tool_calls is true" do
      recipient = self()
      issue = %{id: "test-789", title: "Tool Call Issue", description: "Test"}

      session_id =
        MockAdapter.run(issue, "agent-1", recipient, mock_delay: 5, include_tool_calls: true)

      assert_receive {:session_started, ^session_id}

      assert_receive {:tool_call_detected, ^session_id, tool_call_1}
      assert tool_call_1["name"] == "bash"
      assert tool_call_1["input"]["command"] == "echo 'test'"

      assert_receive {:tool_call_detected, ^session_id, tool_call_2}
      assert tool_call_2["name"] == "read_file"
      assert tool_call_2["input"]["file_path"] == "/tmp/test.txt"

      assert_receive {:turn_completed, ^session_id, result}
      assert result["type"] == "mock_result"
    end

    test "does not send tool_call_detected when include_tool_calls is false" do
      recipient = self()
      issue = %{id: "test-999", title: "No Tool Call Issue", description: "Test"}

      session_id =
        MockAdapter.run(issue, "agent-1", recipient, mock_delay: 5, include_tool_calls: false)

      assert_receive {:session_started, ^session_id}
      assert_receive {:turn_completed, ^session_id, _result}

      refute_receive {:tool_call_detected, _, _}
    end

    test "returns a reference as session_id" do
      issue = %{id: "test-ref", title: "Ref Test", description: "Test"}

      session_id = MockAdapter.run(issue, "agent-1", self(), mock_delay: 5)

      assert is_reference(session_id)
    end
  end

  describe "run_with_error/4 — error protocol" do
    test "sends session_started then turn_ended_with_error" do
      recipient = self()
      issue = %{id: "test-456", title: "Error Issue", description: "Test"}

      session_id = MockAdapter.run_with_error(issue, "agent-1", recipient, :test_error)

      assert_receive {:session_started, ^session_id}
      assert_receive {:turn_ended_with_error, ^session_id, :test_error}
    end

    test "defaults to :mock_error reason" do
      recipient = self()
      issue = %{id: "test-default", title: "Default Error", description: "Test"}

      session_id = MockAdapter.run_with_error(issue, "agent-1", recipient)

      assert_receive {:session_started, ^session_id}
      assert_receive {:turn_ended_with_error, ^session_id, :mock_error}
    end
  end

  describe "behaviour compliance" do
    test "implements Cympho.AgentAdapters.Adapter" do
      behaviours =
        MockAdapter.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Cympho.AgentAdapters.Adapter in behaviours
    end

    test "exports all required callbacks" do
      callbacks = [
        {MockAdapter, :run, 4},
        {MockAdapter, :available?, 1},
        {MockAdapter, :health_check, 1},
        {MockAdapter, :type, 0},
        {MockAdapter, :validate_config, 1}
      ]

      Enum.each(callbacks, fn {mod, fun, arity} ->
        assert function_exported?(mod, fun, arity),
               "Expected #{inspect(mod)}.#{fun}/#{arity} to be exported"
      end)
    end
  end
end
