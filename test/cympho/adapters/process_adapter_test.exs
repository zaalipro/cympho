defmodule Cympho.Adapters.ProcessAdapterTest do
  use ExUnit.Case, async: false

  alias Cympho.Adapters.ProcessAdapter

  @issue %{
    id: "issue-1",
    title: "Prompt Arg Feature",
    description: "Exercise prompt argument forwarding.",
    status: :todo,
    priority: :medium
  }

  test "passes model and prompt through argv templates without requiring stdin" do
    with_fake_command(
      "fake-agent",
      """
      for arg in "$@"; do
        printf 'ARG:%s\\n' "$arg"
      done
      """,
      fn ->
        session_id =
          ProcessAdapter.run(@issue, "agent-1", self(),
            config: %{
              "command" => "fake-agent",
              "timeout" => 5_000,
              "model" => "kimi-code/kimi-for-coding",
              "model_arg_template" => ["-m", "{{model}}"],
              "prompt_arg_template" => ["-p", "{{prompt}}"],
              "prompt_stdin" => false
            }
          )

        assert_receive {:session_started, ^session_id}
        assert_receive {:turn_completed, ^session_id, result}, 6_000

        assert result.output =~ "ARG:-m"
        assert result.output =~ "ARG:kimi-code/kimi-for-coding"
        assert result.output =~ "ARG:-p"
        assert result.output =~ "Prompt Arg Feature"
      end
    )
  end

  test "summarizes newline-delimited JSON messages" do
    with_fake_command(
      "fake-jsonl-agent",
      """
      printf '{"text":"first"}\\n'
      printf '{"text":"second"}\\n'
      """,
      fn ->
        session_id =
          ProcessAdapter.run(@issue, "agent-1", self(),
            config: %{"command" => "fake-jsonl-agent", "timeout" => 5_000}
          )

        assert_receive {:session_started, ^session_id}
        assert_receive {:turn_completed, ^session_id, result}, 6_000

        assert result.output == "first\nsecond"
        assert [%{"text" => "first"}, %{"text" => "second"}] = result.messages
      end
    )
  end

  test "preserves UTF-8 process output for multilingual delivery text" do
    expected =
      <<0xE7, 0x8A, 0xB6, 0xE6, 0x80, 0x81, 0xE6, 0x9B, 0xB4, 0xE6, 0x96, 0xB0, 0x20, 0xF0, 0x9F,
        0x9A, 0x80>>

    with_fake_command(
      "fake-unicode-agent",
      """
      printf '\\347\\212\\266\\346\\200\\201\\346\\233\\264\\346\\226\\260 \\360\\237\\232\\200'
      """,
      fn ->
        session_id =
          ProcessAdapter.run(@issue, "agent-1", self(),
            config: %{
              "command" => "fake-unicode-agent",
              "timeout" => 5_000,
              "prompt_stdin" => false
            }
          )

        assert_receive {:session_started, ^session_id}
        assert_receive {:turn_completed, ^session_id, result}, 6_000

        assert String.valid?(result.output)
        assert result.output == expected
        assert result.raw == expected
      end
    )
  end

  test "normalizes malformed process bytes before parsing output" do
    replacement = <<0xEF, 0xBF, 0xBD>>

    with_fake_command(
      "fake-invalid-bytes-agent",
      """
      printf 'prefix\\377suffix'
      """,
      fn ->
        session_id =
          ProcessAdapter.run(@issue, "agent-1", self(),
            config: %{
              "command" => "fake-invalid-bytes-agent",
              "timeout" => 5_000,
              "prompt_stdin" => false
            }
          )

        assert_receive {:session_started, ^session_id}
        assert_receive {:turn_completed, ^session_id, result}, 6_000

        assert String.valid?(result.output)
        assert result.output == "prefix" <> replacement <> "suffix"
        assert result.raw == result.output
      end
    )
  end

  test "treats provider rate-limit text on exit zero as an adapter error" do
    with_fake_command(
      "fake-rate-limited-agent",
      """
      printf 'HTTP 429 Too Many Requests: rate limit exceeded'
      exit 0
      """,
      fn ->
        session_id =
          ProcessAdapter.run(@issue, "agent-1", self(),
            config: %{"command" => "fake-rate-limited-agent", "timeout" => 5_000}
          )

        assert_receive {:session_started, ^session_id}

        assert_receive {:turn_ended_with_error, ^session_id,
                        {:provider_failure, :rate_limited, snippet}},
                       6_000

        assert snippet =~ "429"
        refute_receive {:turn_completed, ^session_id, _result}, 100
      end
    )
  end

  test "cancels a running local process through adapter sessions" do
    with_fake_command(
      "fake-slow-agent",
      """
      sleep 30
      printf 'should-not-finish'
      """,
      fn ->
        session_id =
          ProcessAdapter.run(@issue, "agent-1", self(),
            config: %{
              "command" => "fake-slow-agent",
              "timeout" => 30_000,
              "prompt_stdin" => false
            }
          )

        assert_receive {:session_started, ^session_id}, 1_000
        assert Cympho.AdapterSessions.registered?(session_id)
        assert :ok = Cympho.AdapterSessions.cancel(session_id, :test_stop)

        assert_receive {:turn_ended_with_error, ^session_id, {:cancelled, :test_stop}}, 1_000
        refute_receive {:turn_completed, ^session_id, _result}, 200
      end
    )
  end

  test "inherits parent environment while adding runtime issue variables" do
    original = System.get_env("CYMPHO_PARENT_ENV_TEST")
    System.put_env("CYMPHO_PARENT_ENV_TEST", "from-parent")

    try do
      session_id =
        ProcessAdapter.run(@issue, "agent-1", self(),
          config: %{
            "command" => "/bin/sh",
            "args" => ["-c", "printf '%s|%s' \"$CYMPHO_PARENT_ENV_TEST\" \"$ISSUE_ID\""],
            "timeout" => 5_000,
            "prompt_stdin" => false
          }
        )

      assert_receive {:session_started, ^session_id}, 1_000
      assert_receive {:turn_completed, ^session_id, result}, 1_000
      assert result.output == "from-parent|#{@issue.id}"
    after
      if original do
        System.put_env("CYMPHO_PARENT_ENV_TEST", original)
      else
        System.delete_env("CYMPHO_PARENT_ENV_TEST")
      end
    end
  end

  defp with_fake_command(command, script, fun) do
    dir =
      Path.join(System.tmp_dir!(), "cympho-process-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    command_path = Path.join(dir, command)
    File.write!(command_path, "#!/bin/sh\n#{script}\n")
    File.chmod!(command_path, 0o755)

    try do
      with_path(dir, fun)
    after
      File.rm_rf!(dir)
    end
  end

  defp with_path(path, fun) do
    original = System.get_env("PATH") || ""
    System.put_env("PATH", path)

    try do
      fun.()
    after
      System.put_env("PATH", original)
    end
  end
end
