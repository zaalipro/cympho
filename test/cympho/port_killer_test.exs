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

    assert :ok = PortKiller.close(port)
    refute process_alive?(os_pid)
  end

  test "close reaps the descendant tree without signalling the caller's group" do
    # Parent spawns a lingering grandchild. The port child shares the BEAM's process group, so a
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

    assert :ok = PortKiller.close(port, cleanup_timeout_ms: 2_500, helper_timeout_ms: 500)
    refute process_alive?(parent_pid)
    refute process_alive?(grandchild_pid)
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

    assert :ok = PortKiller.close(port)
    refute process_alive?(parent_pid)
    refute process_alive?(grandchild_pid)
  end

  test "freeze barrier captures a descendant forked after the initial scan" do
    tmp_dir = Path.join(System.tmp_dir!(), "cympho-port-killer-freeze-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    command = Path.join(tmp_dir, "late-forker.py")
    kill_helper = Path.join(tmp_dir, "freeze-kill")
    child_pid_file = Path.join(tmp_dir, "late-child.pid")
    fork_requested = Path.join(tmp_dir, "fork-requested")
    real_kill = System.find_executable("kill")
    real_pgrep = System.find_executable("pgrep")

    File.write!(command, """
    #!#{System.find_executable("python3")}
    import os, signal, time

    def fork_child(_signal, _frame):
        child = os.fork()
        if child == 0:
            while True:
                time.sleep(1)
        with open(#{inspect(child_pid_file)}, "w") as output:
            output.write(str(child))

    signal.signal(signal.SIGUSR1, fork_child)
    print("ready", flush=True)
    while True:
        time.sleep(0.01)
    """)

    # The first STOP is the exact boundary between initial discovery and the
    # freeze. Force the root to fork there, wait until the child is parented,
    # and only then allow STOP through. A one-pass snapshot would leak it; the
    # frozen-tree rescan must discover and stop it before Port.close/1.
    File.write!(kill_helper, """
    #!/bin/sh
    if [ "$1" = "-STOP" ] && [ ! -f "#{fork_requested}" ]; then
      : > "#{fork_requested}"
      "#{real_kill}" -USR1 "$2"
      i=0
      while [ ! -s "#{child_pid_file}" ] && [ "$i" -lt 100 ]; do
        sleep 0.005
        i=$((i + 1))
      done
    fi
    exec "#{real_kill}" "$@"
    """)

    File.chmod!(command, 0o755)
    File.chmod!(kill_helper, 0o755)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    assert_receive {^port, {:data, "ready\n"}}, 5_000

    assert :ok =
             PortKiller.close(port,
               cleanup_timeout_ms: 2_000,
               helper_timeout_ms: 1_000,
               helper_paths: %{"kill" => kill_helper, "pgrep" => real_pgrep}
             )

    assert File.exists?(fork_requested)
    assert File.exists?(child_pid_file)
    child_pid = child_pid_file |> File.read!() |> String.trim() |> String.to_integer()
    refute process_alive?(child_pid)
  end

  test "a hung discovery helper times out without closing the owned port" do
    tmp_dir = Path.join(System.tmp_dir!(), "cympho-port-killer-helper-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    command = Path.join(tmp_dir, "stubborn")
    helper = Path.join(tmp_dir, "hung-pgrep")
    helper_pid_file = Path.join(tmp_dir, "helper.pid")

    File.write!(
      command,
      "#!/bin/sh\ntrap '' TERM\nprintf 'ready\\n'\nwhile true; do sleep 1; done\n"
    )

    File.write!(
      helper,
      "#!/bin/sh\necho $$ > #{helper_pid_file}\ntrap '' TERM\nwhile true; do sleep 1; done\n"
    )

    File.chmod!(command, 0o755)
    File.chmod!(helper, 0o755)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    assert_receive {^port, {:data, "ready\n"}}, 5_000
    assert {:os_pid, os_pid} = Port.info(port, :os_pid)
    started = System.monotonic_time(:millisecond)

    assert {:error, {:cleanup_timeout, %PortKiller.Cleanup{phase: :snapshot}}} =
             PortKiller.close(port,
               helper_timeout_ms: 1_000,
               cleanup_timeout_ms: 1_200,
               helper_paths: %{"pgrep" => helper}
             )

    assert System.monotonic_time(:millisecond) - started < 1_450
    assert Port.info(port)
    assert process_alive?(os_pid)
    # On a heavily loaded host the helper Port can hit its deadline before the
    # shell reaches its first instruction. If it did publish a PID, it must be
    # gone; absence means no helper body (and therefore no descendant) started.
    case File.read(helper_pid_file) do
      {:ok, contents} ->
        helper_pid = contents |> String.trim() |> String.to_integer()
        refute process_alive?(helper_pid)

      {:error, :enoent} ->
        :ok
    end

    assert :ok = PortKiller.close(port)
    refute process_alive?(os_pid)
  end

  test "close_and_await preserves success after a delayed helper recovers" do
    tmp_dir = Path.join(System.tmp_dir!(), "cympho-port-killer-retry-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    command = Path.join(tmp_dir, "stubborn")
    helper = Path.join(tmp_dir, "gated-pgrep")
    helper_started = Path.join(tmp_dir, "helper.started")
    gate = Path.join(tmp_dir, "helper.ready")
    real_pgrep = System.find_executable("pgrep")

    File.write!(
      command,
      "#!/bin/sh\ntrap '' TERM\nprintf 'ready\\n'\nwhile true; do sleep 1; done\n"
    )

    File.write!(helper, """
    #!/bin/sh
    : > '#{helper_started}'
    if [ ! -f '#{gate}' ]; then
      trap '' TERM
      while true; do sleep 1; done
    fi
    exec '#{real_pgrep}' "$@"
    """)

    File.chmod!(command, 0o755)
    File.chmod!(helper, 0o755)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    assert_receive {^port, {:data, "ready\n"}}, 5_000
    assert {:os_pid, os_pid} = Port.info(port, :os_pid)

    task =
      Task.async(fn ->
        :ok =
          PortKiller.close_and_await(
            port,
            helper_timeout_ms: 250,
            cleanup_timeout_ms: 1_000,
            retry_ms: 20,
            helper_paths: %{"pgrep" => helper}
          )

        {:error, :original_terminal_reason}
      end)

    wait_until(fn -> assert File.exists?(helper_started) end)
    assert process_alive?(os_pid)
    File.write!(gate, "ready")

    assert {:error, :original_terminal_reason} = Task.await(task, 10_000)
    refute process_alive?(os_pid)
  end

  test "snapshot retries retain descendants after the original parent disappears" do
    tmp_dir = Path.join(System.tmp_dir!(), "cympho-port-killer-retain-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    command = Path.join(tmp_dir, "parent")
    helper = Path.join(tmp_dir, "stateful-pgrep")
    helper_calls = Path.join(tmp_dir, "helper.calls")
    retry_gate = Path.join(tmp_dir, "retry")

    File.write!(command, """
    #!/bin/sh
    sh -c "trap '' TERM; while true; do sleep 1; done" &
    printf '%s\n' "$!"
    trap '' TERM
    while true; do sleep 1; done
    """)

    File.chmod!(command, 0o755)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    assert_receive {^port, {:data, data}}, 5_000
    child_pid = data |> String.trim() |> String.to_integer()
    assert {:os_pid, root_pid} = Port.info(port, :os_pid)

    # Root discovery finds the child, then the child lookup hangs. This
    # produces a retryable snapshot holding both PIDs without closing the port.
    File.write!(helper, """
    #!/bin/sh
    printf '%s|%s\n' "$1" "$2" >> '#{helper_calls}'
    [ -f '#{retry_gate}' ] && exit 1
    if [ "$2" = '#{root_pid}' ]; then
      printf '%s\n' '#{child_pid}'
      exit 0
    fi
    if [ "$2" = '#{child_pid}' ]; then
      trap '' TERM
      while true; do sleep 1; done
    fi
    exit 1
    """)

    File.chmod!(helper, 0o755)
    assert {output, 0} = System.cmd(helper, ["-P", Integer.to_string(root_pid)])
    assert output == "#{child_pid}\n"

    assert {:error,
            {:cleanup_timeout, %PortKiller.Cleanup{phase: :snapshot, targets: retained} = cleanup}} =
             PortKiller.close(port,
               cleanup_timeout_ms: 500,
               helper_timeout_ms: 200,
               helper_paths: %{"pgrep" => helper}
             )

    assert Enum.any?(retained, &(&1.pid == root_pid))

    assert Enum.any?(retained, &(&1.pid == child_pid)),
           "helper calls: #{inspect(File.read(helper_calls))}"

    System.cmd("kill", ["-KILL", Integer.to_string(root_pid)], stderr_to_stdout: true)
    wait_until(fn -> refute process_alive?(root_pid) end)
    assert process_alive?(child_pid)
    File.write!(retry_gate, "ready")

    # Fresh discovery can no longer reach the reparented child. It must still
    # be killed from the retained union rather than being silently forgotten.
    assert :ok = PortKiller.retry_cleanup(cleanup)
    refute process_alive?(child_pid)
  end

  test "a timed-out custom helper does not orphan its background descendant" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-helper-tree-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    command = Path.join(tmp_dir, "stubborn")
    helper = Path.join(tmp_dir, "hung-tree-pgrep")
    helper_child_pid_file = Path.join(tmp_dir, "helper-child.pid")

    File.write!(command, "#!/bin/sh\nprintf 'ready\\n'\nwhile true; do sleep 1; done\n")

    File.write!(helper, """
    #!/bin/sh
    sh -c "trap '' TERM; while true; do sleep 1; done" &
    printf '%s' "$!" > '#{helper_child_pid_file}'
    trap '' TERM
    while true; do sleep 1; done
    """)

    File.chmod!(command, 0o755)
    File.chmod!(helper, 0o755)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    assert_receive {^port, {:data, "ready\n"}}, 5_000
    started = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        PortKiller.close(port,
          cleanup_timeout_ms: 1_200,
          helper_timeout_ms: 1_000,
          helper_paths: %{"pgrep" => helper}
        )
      end)

    wait_until(fn -> assert File.exists?(helper_child_pid_file) end)

    assert {:error, {:cleanup_timeout, %PortKiller.Cleanup{phase: :snapshot}}} =
             Task.await(task, 2_000)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 1_350

    helper_child_pid =
      helper_child_pid_file |> File.read!() |> String.trim() |> String.to_integer()

    refute process_alive?(helper_child_pid)

    assert :ok =
             PortKiller.close_and_await(port,
               cleanup_timeout_ms: 2_500,
               helper_timeout_ms: 500
             )
  end

  test "initial kill shares the snapshot attempt deadline" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-deadline-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    command = Path.join(tmp_dir, "single-process.py")
    pgrep_helper = Path.join(tmp_dir, "no-children-pgrep")
    kill_helper = Path.join(tmp_dir, "slow-stop-hung-kill")
    first_scan = Path.join(tmp_dir, "first-scan")
    real_kill = System.find_executable("kill")

    File.write!(command, """
    #!#{System.find_executable("python3")}
    import time
    print("ready", flush=True)
    while True:
        time.sleep(1)
    """)

    File.write!(pgrep_helper, """
    #!/bin/sh
    if [ ! -f '#{first_scan}' ]; then
      : > '#{first_scan}'
      sleep 1.2
    fi
    exit 1
    """)

    # Spend half the attempt on initial discovery, then make the KILL helper
    # hang. Before the deadline was threaded through, the kill phase got a
    # second full cleanup_timeout_ms and this call took roughly 4.2 seconds.
    File.write!(kill_helper, """
    #!/bin/sh
    if [ "$1" = "-STOP" ]; then
      exec '#{real_kill}' "$@"
    fi
    if [ "$1" = "-KILL" ]; then
      trap '' TERM
      while true; do sleep 1; done
    fi
    exec '#{real_kill}' "$@"
    """)

    File.chmod!(command, 0o755)
    File.chmod!(pgrep_helper, 0o755)
    File.chmod!(kill_helper, 0o755)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    assert_receive {^port, {:data, "ready\n"}}, 5_000
    started = System.monotonic_time(:millisecond)

    assert {:error, {:cleanup_timeout, %PortKiller.Cleanup{phase: :kill} = cleanup}} =
             PortKiller.close(port,
               cleanup_timeout_ms: 3_000,
               helper_timeout_ms: 5_000,
               helper_paths: %{"kill" => kill_helper, "pgrep" => pgrep_helper}
             )

    assert System.monotonic_time(:millisecond) - started < 3_500

    # The custom KILL was deliberately broken; use the trusted helper on the
    # retained cleanup so this test does not leak the stopped target.
    cleanup = put_in(cleanup.opts.helper_paths, %{})
    assert :ok = PortKiller.retry_cleanup(cleanup)
  end

  test "identity changes never signal a reused PID or discover its children" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-identity-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    command = Path.join(tmp_dir, "stubborn")
    pgrep_helper = Path.join(tmp_dir, "replacement-pgrep")
    kill_helper = Path.join(tmp_dir, "record-kill")
    signal_log = Path.join(tmp_dir, "signals")
    File.write!(command, "#!/bin/sh\nprintf 'ready\\n'\nwhile true; do sleep 1; done\n")
    File.write!(pgrep_helper, "#!/bin/sh\nprintf '999999\\n'\n")
    File.write!(kill_helper, "#!/bin/sh\nprintf '%s|%s\\n' \"$1\" \"$2\" >> '#{signal_log}'\n")
    File.chmod!(command, 0o755)
    File.chmod!(pgrep_helper, 0o755)
    File.chmod!(kill_helper, 0o755)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    assert_receive {^port, {:data, "ready\n"}}, 5_000
    assert {:os_pid, root_pid} = Port.info(port, :os_pid)
    {:ok, identity_calls} = Agent.start_link(fn -> 0 end)

    identity_reader = fn
      ^root_pid ->
        call = Agent.get_and_update(identity_calls, &{&1, &1 + 1})
        if call == 0, do: {:ok, :original}, else: {:ok, :replacement}

      _other_pid ->
        flunk("replacement children must not be identity-checked")
    end

    assert :ok =
             PortKiller.close(port,
               identity_reader: identity_reader,
               helper_paths: %{"kill" => kill_helper, "pgrep" => pgrep_helper}
             )

    refute File.exists?(signal_log)

    cleanup = %PortKiller.Cleanup{
      phase: :kill,
      root_pid: root_pid,
      targets: [%PortKiller.Target{pid: root_pid, identity: :original}],
      opts: %{
        cleanup_timeout_ms: 100,
        helper_timeout_ms: 50,
        helper_paths: %{"kill" => kill_helper},
        identity_reader: fn ^root_pid -> {:ok, :replacement} end
      },
      port: nil
    }

    assert :ok = PortKiller.retry_cleanup(cleanup)
    refute File.exists?(signal_log)
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
