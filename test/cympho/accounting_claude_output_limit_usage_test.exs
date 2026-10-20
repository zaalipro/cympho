defmodule Cympho.T1Review.AccountingClaudeOutputLimitUsageTest do
  # Finding accounting-astra-missed-1: Claude output-limit handling discards an
  # already-delivered billed result.
  use ExUnit.Case, async: false

  alias Cympho.AgentRunner

  @receive_timeout 5_000

  test "an output-limit failure keeps the billed result the over-limit chunk completed" do
    tmp_dir = Path.join(System.tmp_dir!(), "t1-review-claude-limit-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    billed =
      Jason.encode!(%{
        "type" => "result",
        "result" => "Done.",
        "usage" => %{"input_tokens" => 1_000, "output_tokens" => 200},
        "total_cost_usd" => 0.12
      })

    # The relay passes limit + 1 bytes, so with the limit one byte short of
    # the result, the result's closing brace is the byte past the limit.
    limit = byte_size(billed) - 1
    command = Path.join(tmp_dir, "fake-claude")
    File.write!(command, "#!/bin/sh\nprintf '%s\\n' '#{billed}'\nexit 0\n")
    File.chmod!(command, 0o755)

    session_id =
      AgentRunner.run(
        %{id: "t1-review-claude-limit", title: "Limit", description: "Limit"},
        "agent-1",
        self(),
        cwd: tmp_dir,
        config: %{"command" => command},
        env: %{"ANTHROPIC_API_KEY" => "test-key"},
        stall_timeout: 5_000,
        max_run_ms: 5_000,
        max_output_bytes: limit
      )

    outcome =
      receive do
        {:turn_ended_with_error, ^session_id, _reason} = message -> message
        {:turn_ended_with_error, ^session_id, _reason, _billed} = message -> message
        {:turn_completed, ^session_id, _result} = message -> message
      after
        @receive_timeout -> flunk("no terminal outcome")
      end

    assert {:turn_ended_with_error, ^session_id, {:output_limit_exceeded, ^limit, _tail}, result} =
             outcome

    assert result["total_cost_usd"] == 0.12
  end
end
