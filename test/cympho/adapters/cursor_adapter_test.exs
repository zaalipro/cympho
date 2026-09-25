defmodule Cympho.Adapters.CursorAdapterTest do
  use ExUnit.Case, async: false

  alias Cympho.Adapters.CursorAdapter
  alias Cympho.RuntimeAdmission

  @issue %{id: "cursor-terminal", title: "Cursor terminal ordering", description: "Run."}

  test "a Cursor output flood fails at the lower configured cap and reaps its child" do
    root =
      Path.join(System.tmp_dir!(), "cympho-cursor-flood-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    pid_path = Path.join(root, "pid")
    go_path = Path.join(root, "go")
    agent_path = Path.join(root, "agent")
    sleep = System.find_executable("sleep") || "/bin/sleep"

    server =
      start_supervised!(
        {RuntimeAdmission, name: nil, max_total_runs: 1, max_local_runs: 1, memory_check?: false}
      )

    assert {:ok, token} = RuntimeAdmission.checkout(CursorAdapter, server)

    File.write!(
      agent_path,
      "#!/bin/sh\necho $$ > #{pid_path}\nwhile [ ! -e #{go_path} ]; do #{sleep} 0.01; done\nwhile :; do printf 'tail-marker-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n'; done\n"
    )

    File.chmod!(agent_path, 0o755)

    session_id =
      CursorAdapter.run(@issue, "agent-1", self(),
        config: %{command: agent_path, timeout: 2_000, max_output_bytes: 16_384},
        max_output_bytes: 80_000_000,
        runtime_admission_claim: {token, server, :local_process}
      )

    assert_receive {:session_started, ^session_id}, 3_000
    assert eventually(fn -> File.exists?(pid_path) end)
    assert RuntimeAdmission.snapshot(server).total_running == 1
    assert {:error, :total_slots_exhausted} = RuntimeAdmission.available(CursorAdapter, server)
    File.write!(go_path, "go")

    assert_receive {:turn_ended_with_error, ^session_id, {:output_limit_exceeded, 16_384, tail}},
                   5_000

    assert byte_size(tail) <= 8_192
    assert tail =~ "tail-marker"
    refute_receive {:turn_completed, ^session_id, _}, 100
    child_pid = pid_path |> File.read!() |> String.trim()
    assert {_output, code} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
    assert code != 0
    assert eventually(fn -> not Cympho.AdapterSessions.registered?(session_id) end)
    assert eventually(fn -> RuntimeAdmission.snapshot(server).total_running == 0 end)
    assert :ok = RuntimeAdmission.available(CursorAdapter, server)
  end

  test "cancellation reports terminal only after the Cursor child exits" do
    root =
      Path.join(System.tmp_dir!(), "cympho-cursor-terminal-#{System.unique_integer([:positive])}")

    marker = Path.join(root, "exited")
    pid_path = Path.join(root, "pid")
    agent_path = Path.join(root, "agent")
    File.mkdir_p!(root)

    File.write!(
      agent_path,
      """
      #!/bin/sh
      on_exit() { printf exited > #{marker}; exit 0; }
      trap on_exit TERM HUP INT
      printf '%s' "$$" > #{pid_path}
      printf 'ready\\n'
      while true; do :; done
      """
    )

    File.chmod!(agent_path, 0o755)

    session_id =
      CursorAdapter.run(@issue, "agent-1", self(),
        config: %{command: agent_path, timeout: 30_000}
      )

    on_exit(fn ->
      try do
        assert :ok = Cympho.AdapterSessions.cancel_and_wait(session_id, :test_cleanup)
      after
        File.rm_rf!(root)
      end
    end)

    assert Cympho.AdapterSessions.registered?(session_id)
    assert_receive {:session_started, ^session_id}, 3_000
    assert_receive {:turn_progress, ^session_id, _progress}, 2_000
    child_pid = pid_path |> File.read!() |> String.to_integer()
    assert process_alive?(child_pid)

    assert :ok = Cympho.AdapterSessions.cancel(session_id, :terminal_order_test)

    assert_receive {:turn_ended_with_error, ^session_id, {:cancelled, :terminal_order_test}},
                   2_000

    refute process_alive?(child_pid)
  end

  test "pre-run setup exceptions emit one fixed terminal error and unregister" do
    session_id =
      CursorAdapter.run(
        %{"id" => fn -> :invalid_issue end},
        "agent-1",
        self(),
        config: %{"command" => "SENTINEL_MUST_NOT_LEAK"}
      )

    assert_receive {:turn_ended_with_error, ^session_id,
                    {:adapter_crash, :cursor_adapter_failed}},
                   1_000

    refute_receive {:session_started, ^session_id}, 100
    refute_receive {:turn_ended_with_error, ^session_id, _duplicate}, 100
    refute inspect(Process.info(self(), :messages)) =~ "SENTINEL_MUST_NOT_LEAK"
    refute Cympho.AdapterSessions.registered?(session_id)
  end

  test "run setup failures expose no exception or configured value" do
    sentinel = "CURSOR_SETUP_SECRET_SENTINEL"

    session_id =
      CursorAdapter.run(@issue, "agent-1", self(), config: %{"command" => {sentinel, self()}})

    assert_receive {:turn_ended_with_error, ^session_id, :cursor_process_failed}, 1_000
    refute_receive {:session_started, ^session_id}, 100
    refute_receive {:turn_ended_with_error, ^session_id, _duplicate}, 100
    refute inspect(Process.info(self(), :messages)) =~ sentinel
    refute Cympho.AdapterSessions.registered?(session_id)
  end

  defp process_alive?(os_pid) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp eventually(fun, attempts \\ 40) do
    cond do
      fun.() -> true
      attempts <= 1 -> false
      true -> Process.sleep(25) && eventually(fun, attempts - 1)
    end
  end
end
