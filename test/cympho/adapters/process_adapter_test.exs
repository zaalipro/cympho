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
