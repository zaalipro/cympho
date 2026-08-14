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

    # 5s (not 1s): under full-suite parallelism the OS spawn + first write can
    # lag well past a second, which flaked this assertion in CI.
    assert_receive {^port, {:data, "ready\n"}}, 5_000
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

    assert_receive {^port, {:data, data}}, 5_000
    grandchild_pid = data |> String.trim() |> String.to_integer()
    assert {:os_pid, parent_pid} = Port.info(port, :os_pid)

    assert process_alive?(parent_pid)
    assert process_alive?(grandchild_pid)

    assert :ok = PortKiller.close(port, grace_ms: 50)

    wait_until(fn -> refute process_alive?(parent_pid) end)
    wait_until(fn -> refute process_alive?(grandchild_pid) end)
  end

  test "close reaps a grandchild even when the parent dies with the port" do
    # The existing tree test uses a parent that ignores TERM and survives the
    # close, so the subtree is still discoverable afterwards. This one uses a
    # parent that dies as soon as its stdout pipe goes away: its children then
    # reparent to init and `pgrep -P <parent>` returns nothing. Snapshotting the
    # tree *after* closing the port therefore missed them entirely, which is the
    # exact invariant PortKiller's own docs claim to hold.
    tmp_dir = Path.join(System.tmp_dir!(), "cympho-port-killer-orphan-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    command = Path.join(tmp_dir, "dying-parent")

    File.write!(
      command,
      """
      #!/bin/sh
      sh -c "trap '' TERM; while true; do sleep 1; done" &
      printf '%s\\n' "$!"
      # Writing continuously means the parent takes SIGPIPE the moment the port
      # closes, before any signal from PortKiller could reach it.
      while true; do printf 'tick\\n'; sleep 0.2; done
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

    assert_receive {^port, {:data, data}}, 5_000
    grandchild_pid = data |> String.split("\n", trim: true) |> hd() |> String.to_integer()
    assert {:os_pid, parent_pid} = Port.info(port, :os_pid)

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
