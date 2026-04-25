defmodule Cympho.AgentRunnerTest do
  use ExUnit.Case, async: false

  alias Cympho.AgentRunner.Mock

  describe "Mock.run/4" do
    test "sends session_started and turn_completed messages" do
      recipient = self()
      issue = %{id: "test-123", title: "Test Issue", description: "Test description"}

      session_id = Mock.run(issue, "agent-1", recipient, mock_delay: 5)

      assert_receive {:session_started, ^session_id}
      assert_receive {:turn_completed, ^session_id, result}
      assert result["type"] == "mock_result"
    end

    test "sends turn_ended_with_error for error mock" do
      recipient = self()
      issue = %{id: "test-456", title: "Error Issue", description: "Test"}

      session_id = Mock.run_with_error(issue, "agent-1", recipient, :test_error)

      assert_receive {:session_started, ^session_id}
      assert_receive {:turn_ended_with_error, ^session_id, :test_error}
    end

    test "sends tool_call_detected messages when include_tool_calls is true" do
      recipient = self()
      issue = %{id: "test-789", title: "Tool Call Issue", description: "Test"}

      session_id = Mock.run(issue, "agent-1", recipient, mock_delay: 5, include_tool_calls: true)

      assert_receive {:session_started, ^session_id}

      # Should receive tool_call_detected for each tool use
      assert_receive {:tool_call_detected, ^session_id, tool_call_1}
      assert tool_call_1["name"] == "bash"
      assert tool_call_1["input"]["command"] == "echo 'test'"

      assert_receive {:tool_call_detected, ^session_id, tool_call_2}
      assert tool_call_2["name"] == "read_file"
      assert tool_call_2["input"]["file_path"] == "/tmp/test.txt"

      # Finally receive turn_completed
      assert_receive {:turn_completed, ^session_id, result}
      assert result["type"] == "mock_result"
    end

    test "does not send tool_call_detected when include_tool_calls is false" do
      recipient = self()
      issue = %{id: "test-999", title: "No Tool Call Issue", description: "Test"}

      session_id = Mock.run(issue, "agent-1", recipient, mock_delay: 5, include_tool_calls: false)

      assert_receive {:session_started, ^session_id}
      assert_receive {:turn_completed, ^session_id, result}

      # Should not receive any tool_call_detected messages
      refute_receive {:tool_call_detected, _, _}
    end
  end
end
