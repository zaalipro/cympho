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
  end

end
