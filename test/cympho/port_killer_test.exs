defmodule Cympho.PortKillerTest do
  use ExUnit.Case, async: false

  import Cympho.WaitHelpers

  alias Cympho.PortKiller

  test "close terminates a stubborn port OS process" do
    tmp_dir = Path.join(System.tmp_dir!(), "cympho-port-killer-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    command = Path.join(tmp_dir, "stubborn")

    File.write!(
      command,
      """
      #!/bin/sh
      trap '' TERM
      printf 'ready\\n'
      while true; do sleep 1; done
      """
    )

    File.chmod!(command, 0o755)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    assert_receive {^port, {:data, "ready\n"}}, 1_000
    assert {:os_pid, os_pid} = Port.info(port, :os_pid)
    assert process_alive?(os_pid)

    assert :ok = PortKiller.close(port, grace_ms: 10)
    wait_until(fn -> refute process_alive?(os_pid) end)
  end

  test "close reaps the descendant tree without signalling the caller's group" do
    # Parent spawns a lingering grandchild; both ignore TERM so PortKiller must
    # escalate to KILL. The port child shares the BEAM's process group, so a
    # negative (process-group) signal would also hit this test's node. Reaching
    # the assertions at all proves PortKiller only signalled specific PIDs.
    tmp_dir = Path.join(System.tmp_dir!(), "cympho-port-killer-tree-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    command = Path.join(tmp_dir, "parent")

    File.write!(
      command,
      """
      #!/bin/sh
      trap '' TERM
      sh -c "trap '' TERM; while true; do sleep 1; done" &
      printf '%s\\n' "$!"
      while true; do sleep 1; done
      """
    )

    File.chmod!(command, 0o755)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    assert_receive {^port, {:data, data}}, 2_000
    grandchild_pid = data |> String.trim() |> String.to_integer()
    assert {:os_pid, parent_pid} = Port.info(port, :os_pid)

    assert process_alive?(parent_pid)
    assert process_alive?(grandchild_pid)

    assert :ok = PortKiller.close(port, grace_ms: 50)

    wait_until(fn -> refute process_alive?(parent_pid) end)
    wait_until(fn -> refute process_alive?(grandchild_pid) end)
  end

  defp process_alive?(os_pid) do
    case System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
