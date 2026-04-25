defmodule Cympho.AgentRunner.Mock do
  @moduledoc """
  Mock implementation of AgentRunner for testing without spawning Claude CLI.

  Instead of running the actual Claude process, this module simulates
  the message protocol by immediately sending responses to the recipient.
  """

  @doc """
  Simulates a Claude session without spawning the actual CLI.

  Immediately sends `{:session_started, session_id}` to recipient_pid,
  then `{:turn_completed, session_id, mock_result}` after a configurable delay.

  Options:
    - `:include_tool_calls` — if true, includes mock tool_use blocks in response
  """
  def run(_issue, _agent_id, recipient_pid, opts \\ []) when is_pid(recipient_pid) do
    session_id = make_ref()
    delay = Keyword.get(opts, :mock_delay, 10)
    include_tool_calls = Keyword.get(opts, :include_tool_calls, false)

    spawn(fn ->
      send(recipient_pid, {:session_started, session_id})

      Process.sleep(delay)

      result = build_mock_result(include_tool_calls)

      send(recipient_pid, {:turn_completed, session_id, result})
    end)

    session_id
  end

  defp build_mock_result(include_tool_calls) do
    base_content = [%{"type" => "text", "text" => "Mock Claude response"}]

    content = if include_tool_calls do
      [
        %{
          "type" => "tool_use",
          "id" => "toolu_0123456789",
          "name" => "bash",
          "input" => %{"command" => "echo 'test'"}
        },
        %{
          "type" => "tool_use",
          "id" => "toolu_9876543210",
          "name" => "read_file",
          "input" => %{"file_path" => "/tmp/test.txt"}
        }
        | base_content
      ]
    else
      base_content
    end

    %{
      "type" => "mock_result",
      "content" => content,
      "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
    }
  end

  @doc """
  Simulates a session that errors immediately.
  """
  def run_with_error(_issue, _agent_id, recipient_pid, error_reason \\ :mock_error)
      when is_pid(recipient_pid) do
    session_id = make_ref()

    spawn(fn ->
      send(recipient_pid, {:session_started, session_id})
      Process.sleep(10)
      send(recipient_pid, {:turn_ended_with_error, session_id, error_reason})
    end)

    session_id
  end
end
