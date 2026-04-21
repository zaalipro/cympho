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
  """
  def run(_issue, _agent_id, recipient_pid, opts \\ []) when is_pid(recipient_pid) do
    session_id = make_ref()
    delay = Keyword.get(opts, :mock_delay, 10)

    spawn(fn ->
      send(recipient_pid, {:session_started, session_id})

      Process.sleep(delay)

      result = %{
        "type" => "mock_result",
        "content" => [%{"type" => "text", "text" => "Mock Claude response"}],
        "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
      }

      send(recipient_pid, {:turn_completed, session_id, result})
    end)

    session_id
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
