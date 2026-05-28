defmodule Cympho.AgentRunner.Mock do
  @moduledoc """
  Mock implementation of AgentRunner for testing without spawning Claude CLI.

  Simulates the standard message protocol by immediately sending responses
  to the recipient. Used by `test/cympho/agent_runner_test.exs`.
  """

  @type session_id :: reference()

  @doc """
  Returns the adapter type atom.
  """
  @spec type() :: atom()
  def type, do: :mock

  @doc """
  Whether the adapter is available given the provided config.
  """
  @spec available?(map()) :: boolean()
  def available?(_config), do: true

  @doc """
  Performs a health check.
  """
  @spec health_check(map()) :: map()
  def health_check(_config) do
    %{status: :healthy, message: "Mock adapter always healthy", checked_at: DateTime.utc_now()}
  end

  @doc """
  Validates adapter-specific config.
  """
  @spec validate_config(map()) :: :ok
  def validate_config(_config), do: :ok

  @doc """
  Starts a mock session that emits `:session_started`, optional `:tool_call_detected`
  messages, then `:turn_completed`.
  """
  @spec run(map(), String.t(), pid(), keyword()) :: session_id()
  def run(_issue, _agent_id, recipient_pid, opts \\ []) when is_pid(recipient_pid) do
    session_id = make_ref()
    delay = Keyword.get(opts, :mock_delay, 10)
    include_tool_calls = Keyword.get(opts, :include_tool_calls, false)

    spawn(fn ->
      send(recipient_pid, {:session_started, session_id})

      Process.sleep(delay)

      result = build_mock_result(include_tool_calls)

      send_tool_calls(result, session_id, recipient_pid)
      send(recipient_pid, {:turn_completed, session_id, result})
    end)

    session_id
  end

  @doc """
  Simulates a session that errors immediately.
  """
  @spec run_with_error(map(), String.t(), pid(), term()) :: session_id()
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

  defp build_mock_result(include_tool_calls) do
    base_content = [%{"type" => "text", "text" => "Mock Claude response"}]

    content =
      if include_tool_calls do
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

  defp send_tool_calls(result, session_id, recipient_pid) when is_map(result) do
    content = result["content"] || []

    Enum.each(content, fn item ->
      if item["type"] == "tool_use" do
        tool_call = %{
          "type" => "tool_use",
          "id" => item["id"],
          "name" => item["name"],
          "input" => item["input"],
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        send(recipient_pid, {:tool_call_detected, session_id, tool_call})
      end
    end)
  end

  defp send_tool_calls(_result, _session_id, _recipient_pid), do: :ok
end
