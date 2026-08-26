defmodule Cympho.Adapters.CursorAdapterTest do
  use ExUnit.Case, async: false

  alias Cympho.Adapters.CursorAdapter

  @issue %{id: "cursor-terminal", title: "Cursor terminal ordering", description: "Run."}

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
    on_exit(fn -> File.rm_rf!(root) end)

    session_id =
      CursorAdapter.run(@issue, "agent-1", self(),
        config: %{command: agent_path, timeout: 30_000}
      )

    assert Cympho.AdapterSessions.registered?(session_id)
    assert_receive {:session_started, ^session_id}
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
end
