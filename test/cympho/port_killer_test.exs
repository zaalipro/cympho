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

  defp process_alive?(os_pid) do
    case System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
