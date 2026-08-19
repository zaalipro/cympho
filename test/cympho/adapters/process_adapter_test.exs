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

        assert_receive {:session_started, ^session_id}, 5_000
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

        assert_receive {:session_started, ^session_id}, 5_000
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

        assert_receive {:session_started, ^session_id}, 5_000
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

        assert_receive {:session_started, ^session_id}, 5_000
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

        assert_receive {:session_started, ^session_id}, 5_000

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

  test "does not inherit parent environment while adding runtime issue variables" do
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
      refute result.output =~ "from-parent"
      assert result.output == "|#{@issue.id}"
    after
      if original do
        System.put_env("CYMPHO_PARENT_ENV_TEST", original)
      else
        System.delete_env("CYMPHO_PARENT_ENV_TEST")
      end
    end
  end

  test "an absolute deadline kills a subprocess that keeps talking past its stall timeout" do
    original = Application.get_env(:cympho, :adapter_max_run_ms)
    Application.put_env(:cympho, :adapter_max_run_ms, 700)

    on_exit(fn ->
      if original do
        Application.put_env(:cympho, :adapter_max_run_ms, original)
      else
        Application.delete_env(:cympho, :adapter_max_run_ms)
      end
    end)

    # with_fake_command/3 replaces PATH with the temp dir, so the script needs
    # an absolute sleep — and PortKiller must not depend on PATH either, or the
    # subprocess this test kills would survive as a CPU-burning orphan.
    sleep = System.find_executable("sleep")

    pid_file =
      Path.join(
        System.tmp_dir!(),
        "cympho-chatty-pid-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(pid_file) end)

    with_fake_command(
      "chatty-agent",
      """
      echo $$ > '#{pid_file}'
      while true; do
        printf 'still working\\n'
        #{sleep} 0.1
      done
      """,
      fn ->
        assert_chatty_process_reaped(pid_file)
      end
    )
  end

  test "a subprocess does not outlive the orchestrator that owns it" do
    sleep = System.find_executable("sleep")

    pid_file =
      Path.join(System.tmp_dir!(), "cympho-owned-pid-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(pid_file) end)

    # A brutally killed orchestrator never runs its cancel path, and every
    # recovery step from there is a database write. Nothing signalled the
    # worker, so the CLI kept running in a workspace the next dispatch reuses.
    owner = spawn(fn -> Process.sleep(:infinity) end)

    with_fake_command(
      "owned-agent",
      """
      echo $$ > '#{pid_file}'
      #{sleep} 30
      """,
      fn ->
        _session_id =
          ProcessAdapter.run(@issue, "agent-1", owner,
            config: %{
              "command" => "owned-agent",
              "timeout" => 30_000,
              "prompt_stdin" => false
            }
          )

        assert wait_until(fn -> File.exists?(pid_file) end)
        os_pid = pid_file |> File.read!() |> String.trim()
        assert os_process_alive?(os_pid)

        Process.exit(owner, :kill)

        assert wait_until_gone(os_pid),
               "the subprocess (#{os_pid}) outlived the orchestrator that owned it"
      end
    )
  end

  defp wait_until(fun, attempts \\ 40) do
    cond do
      fun.() -> true
      attempts <= 1 -> false
      true -> Process.sleep(50) && wait_until(fun, attempts - 1)
    end
  end

  defp wait_until_gone(os_pid, attempts \\ 40) do
    cond do
      not os_process_alive?(os_pid) -> true
      attempts <= 1 -> false
      true -> Process.sleep(50) && wait_until_gone(os_pid, attempts - 1)
    end
  end

  defp assert_chatty_process_reaped(pid_file, attempts \\ 5)

  defp assert_chatty_process_reaped(_pid_file, 0) do
    flunk("the subprocess did not publish its PID before five absolute-deadline attempts")
  end

  defp assert_chatty_process_reaped(pid_file, attempts) do
    File.rm(pid_file)

    # The configured timeout is a *stall* timeout and this process never
    # stalls, so before the absolute deadline existed this run could hold its
    # dispatch slot and bill forever. Each attempt retains the exact 700 ms
    # wall-clock cap. A retry only handles a saturated host delaying the OS
    # child until after that cap, before its first shell instruction can publish
    # the PID this test needs for the independent reaping assertion.
    session_id =
      ProcessAdapter.run(@issue, "agent-1", self(),
        config: %{
          "command" => "chatty-agent",
          "timeout" => 60_000,
          "prompt_stdin" => false
        }
      )

    assert_receive {:session_started, ^session_id}, 5_000
    assert_receive {:turn_ended_with_error, ^session_id, :max_run_timeout}, 6_000
    assert wait_until(fn -> not Cympho.AdapterSessions.registered?(session_id) end)

    case File.read(pid_file) do
      {:ok, contents} when contents != "" ->
        os_pid = String.trim(contents)

        assert wait_until_gone(os_pid),
               "the subprocess (#{os_pid}) outlived its absolute deadline"

      {:ok, ""} ->
        assert_chatty_process_reaped(pid_file, attempts - 1)

      {:error, :enoent} ->
        assert_chatty_process_reaped(pid_file, attempts - 1)

      {:error, reason} ->
        flunk("could not read the subprocess PID file: #{inspect(reason)}")
    end
  end

  defp os_process_alive?(os_pid) do
    match?({_output, 0}, System.cmd("/bin/kill", ["-0", os_pid], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  test "a silent subprocess still fails as a stall, not as a max run" do
    sleep = System.find_executable("sleep")

    with_fake_command(
      "silent-agent",
      "#{sleep} 30\n",
      fn ->
        session_id =
          ProcessAdapter.run(@issue, "agent-1", self(),
            config: %{
              "command" => "silent-agent",
              "timeout" => 500,
              "prompt_stdin" => false
            }
          )

        assert_receive {:session_started, ^session_id}, 5_000
        assert_receive {:turn_ended_with_error, ^session_id, :timeout}, 6_000
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
