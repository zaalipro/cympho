defmodule Cympho.PortKillerTest do
  use ExUnit.Case, async: false

  import Cympho.WaitHelpers

  alias Cympho.PortKiller

  test "close and await terminate a stubborn port OS process" do
    tmp_dir = Path.join(System.tmp_dir!(), "cympho-port-killer-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

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

    assert {:os_pid, os_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, os_pid)

    # 5s (not 1s): under full-suite parallelism the OS spawn + first write can
    # lag well past a second, which flaked this assertion in CI.
    assert_receive {^port, {:data, "ready\n"}}, 5_000

    assert process_alive?(os_pid)

    # A bounded attempt may time out under load; retain its owned tree and await
    # definitive cleanup rather than requiring first-attempt snapshot success.
    result = track_close(tracker, PortKiller.close(port))

    case result do
      :ok -> :ok
      {:error, {:cleanup_timeout, cleanup}} -> assert :ok = PortKiller.await_cleanup(cleanup)
    end

    assert :confirmed_absence = process_liveness(os_pid)
  end

  test "close reaps the descendant tree without signalling the caller's group" do
    # Parent spawns a lingering grandchild. The port child shares the BEAM's process group, so a
    # negative (process-group) signal would also hit this test's node. Reaching
    # the assertions at all proves PortKiller only signalled specific PIDs.
    tmp_dir = Path.join(System.tmp_dir!(), "cympho-port-killer-tree-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

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

    assert {:os_pid, parent_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, parent_pid)

    assert_receive {^port, {:data, data}}, 5_000
    grandchild_pid = data |> String.trim() |> String.to_integer()
    register_target(tracker, grandchild_pid)

    assert process_alive?(parent_pid)
    assert process_alive?(grandchild_pid)

    assert :ok =
             track_close(
               tracker,
               PortKiller.close(port, cleanup_timeout_ms: 2_500, helper_timeout_ms: 500)
             )

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
    tracker = init_fixture(tmp_dir)

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

    assert {:os_pid, parent_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, parent_pid)

    assert_receive {^port, {:data, data}}, 5_000
    grandchild_pid = data |> String.split("\n", trim: true) |> hd() |> String.to_integer()
    register_target(tracker, grandchild_pid)

    assert process_alive?(grandchild_pid)

    # A bounded attempt may retain the captured tree for another attempt;
    # definitive cleanup, not a single-attempt deadline, is the invariant here.
    assert :ok = track_close(tracker, PortKiller.close_and_await(port))
    refute process_alive?(parent_pid)
    refute process_alive?(grandchild_pid)
  end

  test "freeze barrier captures a descendant forked after the initial scan" do
    tmp_dir = Path.join(System.tmp_dir!(), "cympho-port-killer-freeze-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

    command = Path.join(tmp_dir, "late-forker.py")
    kill_helper = Path.join(tmp_dir, "freeze-kill")
    child_pid_file = Path.join(tmp_dir, "late-child.pid")
    fork_requested = Path.join(tmp_dir, "fork-requested")
    real_kill = System.find_executable("kill")
    real_pgrep = System.find_executable("pgrep")

    register_pid_file(tracker, child_pid_file)

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

    assert {:os_pid, os_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, os_pid)

    assert_receive {^port, {:data, "ready\n"}}, 5_000

    # This exercises the fixed-point barrier, not its latency. On a loaded
    # macOS host each identity/state check spawns `ps`, and the first custom
    # STOP helper also waits for Python to service USR1 before it can return.
    # Leave enough end-to-end and per-helper budget for those scheduled OS
    # processes while retaining hard bounds on a real failure.
    assert :ok =
             track_close(
               tracker,
               PortKiller.close(port,
                 cleanup_timeout_ms: 5_000,
                 helper_timeout_ms: 2_000,
                 helper_paths: %{"kill" => kill_helper, "pgrep" => real_pgrep}
               )
             )

    assert File.exists?(fork_requested)
    assert File.exists?(child_pid_file)
    child_pid = child_pid_file |> File.read!() |> String.trim() |> String.to_integer()
    register_target(tracker, child_pid)
    refute process_alive?(child_pid)
  end

  test "a hung discovery helper times out without closing the owned port" do
    tmp_dir = Path.join(System.tmp_dir!(), "cympho-port-killer-helper-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

    command = Path.join(tmp_dir, "stubborn")
    helper = Path.join(tmp_dir, "hung-pgrep")
    helper_pid_file = Path.join(tmp_dir, "helper.pid")
    register_pid_file(tracker, helper_pid_file)

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

    assert {:os_pid, os_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, os_pid)

    assert_receive {^port, {:data, "ready\n"}}, 5_000

    started = System.monotonic_time(:millisecond)

    assert {:error, {:cleanup_timeout, %PortKiller.Cleanup{phase: :snapshot} = cleanup}} =
             PortKiller.close(port,
               helper_timeout_ms: 1_000,
               cleanup_timeout_ms: 1_200,
               helper_paths: %{"pgrep" => helper}
             )

    track_cleanup(tracker, cleanup)

    assert System.monotonic_time(:millisecond) - started < 1_450
    assert Port.info(port)
    assert process_alive?(os_pid)
    # On a heavily loaded host the helper Port can hit its deadline before the
    # shell reaches its first instruction. If it did publish a PID, it must be
    # gone; absence means no helper body (and therefore no descendant) started.
    case File.read(helper_pid_file) do
      {:ok, contents} ->
        helper_pid = contents |> String.trim() |> String.to_integer()
        register_target(tracker, helper_pid)
        refute process_alive?(helper_pid)

      {:error, :enoent} ->
        :ok
    end

    assert :ok = track_close(tracker, PortKiller.close(port))
    refute process_alive?(os_pid)
  end

  test "close_and_await preserves success after a delayed helper recovers" do
    tmp_dir = Path.join(System.tmp_dir!(), "cympho-port-killer-retry-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

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

    assert {:os_pid, os_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, os_pid)

    assert_receive {^port, {:data, "ready\n"}}, 5_000

    task =
      Task.async(fn ->
        :ok =
          track_close(
            tracker,
            PortKiller.close_and_await(
              port,
              helper_timeout_ms: 250,
              cleanup_timeout_ms: 1_000,
              retry_ms: 20,
              helper_paths: %{"pgrep" => helper}
            )
          )

        {:error, :original_terminal_reason}
      end)

    wait_until(fn -> assert File.exists?(helper_started) end, 10_000)
    assert process_alive?(os_pid)
    File.write!(gate, "ready")

    assert {:error, :original_terminal_reason} = Task.await(task, 10_000)
    refute process_alive?(os_pid)
  end

  test "snapshot retries retain descendants after the original parent disappears" do
    tmp_dir = Path.join(System.tmp_dir!(), "cympho-port-killer-retain-#{System.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

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

    assert {:os_pid, root_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, root_pid)

    assert_receive {^port, {:data, data}}, 5_000
    child_pid = data |> String.trim() |> String.to_integer()
    register_target(tracker, child_pid)

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

    track_cleanup(tracker, cleanup)

    assert Enum.any?(retained, &(&1.pid == root_pid))

    assert Enum.any?(retained, &(&1.pid == child_pid)),
           "helper calls: #{inspect(File.read(helper_calls))}"

    System.cmd("kill", ["-KILL", Integer.to_string(root_pid)], stderr_to_stdout: true)
    wait_until(fn -> refute process_alive?(root_pid) end)
    assert process_alive?(child_pid)
    File.write!(retry_gate, "ready")

    # Fresh discovery can no longer reach the reparented child. It must still
    # be killed from the retained union rather than being silently forgotten.
    assert :ok = track_close(tracker, PortKiller.retry_cleanup(cleanup))
    refute process_alive?(child_pid)
  end

  test "a timed-out custom helper does not orphan its background descendant" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-helper-tree-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

    command = Path.join(tmp_dir, "stubborn")
    helper = Path.join(tmp_dir, "hung-tree-pgrep")
    helper_child_pid_file = Path.join(tmp_dir, "helper-child.pid")
    register_pid_file(tracker, helper_child_pid_file)

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

    assert {:os_pid, os_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, os_pid)

    # Under full-suite load the fixture shell may take several seconds to
    # publish readiness; this bound does not alter the cleanup deadline.
    assert_receive {^port, {:data, "ready\n"}}, 10_000

    started = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        PortKiller.close(port,
          cleanup_timeout_ms: 1_200,
          helper_timeout_ms: 1_000,
          helper_paths: %{"pgrep" => helper},
          # This test targets timed-out helper-tree cleanup, not portable PID
          # identity. Avoid spending its short deadline on macOS `ps` helpers
          # before the deliberately hung helper can publish its child PID.
          identity_reader: fn _pid -> {:ok, :stable} end
        )
      end)

    wait_until(fn -> assert File.exists?(helper_child_pid_file) end, 10_000)

    assert {:error, {:cleanup_timeout, %PortKiller.Cleanup{phase: :snapshot} = cleanup}} =
             Task.await(task, 2_000)

    track_cleanup(tracker, cleanup)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 1_350

    helper_child_pid =
      helper_child_pid_file |> File.read!() |> String.trim() |> String.to_integer()

    register_target(tracker, helper_child_pid)
    refute process_alive?(helper_child_pid)

    assert :ok =
             track_close(
               tracker,
               PortKiller.close_and_await(port,
                 cleanup_timeout_ms: 2_500,
                 helper_timeout_ms: 500
               )
             )
  end

  test "initial kill shares the snapshot attempt deadline" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-deadline-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

    command = Path.join(tmp_dir, "single-process.py")
    pgrep_helper = Path.join(tmp_dir, "no-children-pgrep")
    kill_helper = Path.join(tmp_dir, "slow-stop-hung-kill")
    real_kill = System.find_executable("kill")

    File.write!(command, """
    #!#{System.find_executable("python3")}
    import time
    print("ready", flush=True)
    while True:
        time.sleep(1)
    """)

    File.write!(pgrep_helper, "#!/bin/sh\nexit 1\n")

    # Spend half the attempt on initial discovery, then make the KILL helper
    # hang. Before the deadline was threaded through, the kill phase got a
    # second full cleanup_timeout_ms and this call would take roughly 5 seconds.
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

    assert {:os_pid, os_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, os_pid)

    assert_receive {^port, {:data, "ready\n"}}, 5_000

    identity_calls = :atomics.new(1, [])

    identity_reader = fn _pid ->
      # The third read is `collect/4` validating the root inside the snapshot
      # attempt. Delay there instead of sleeping in an OS helper: process
      # launch latency must not decide whether the test reaches the KILL phase.
      if :atomics.add_get(identity_calls, 1, 1) == 3, do: Process.sleep(1_200)
      {:ok, :stable}
    end

    started = System.monotonic_time(:millisecond)

    assert {:error, {:cleanup_timeout, %PortKiller.Cleanup{phase: :kill} = cleanup}} =
             PortKiller.close(port,
               cleanup_timeout_ms: 4_000,
               helper_timeout_ms: 5_000,
               helper_paths: %{"kill" => kill_helper, "pgrep" => pgrep_helper},
               identity_reader: identity_reader
             )

    track_cleanup(tracker, cleanup)

    assert System.monotonic_time(:millisecond) - started < 4_500

    # The custom KILL was deliberately broken; use the trusted helper on the
    # retained cleanup so this test does not leak the stopped target.
    cleanup = put_in(cleanup.opts.helper_paths, %{})
    assert :ok = track_close(tracker, PortKiller.retry_cleanup(cleanup))
  end

  test "identity changes never signal a reused PID or discover its children" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-identity-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

    command = Path.join(tmp_dir, "stubborn")
    pgrep_helper = Path.join(tmp_dir, "replacement-pgrep")
    kill_helper = Path.join(tmp_dir, "record-kill")
    signal_log = Path.join(tmp_dir, "signals")

    # Keep the fixture single-process so fail-safe cleanup only needs the
    # captured PID and cannot leave a reparented `sleep` child behind.
    File.write!(command, """
    #!#{System.find_executable("python3")}
    import time
    print("ready", flush=True)
    while True:
        time.sleep(1)
    """)

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

    assert {:os_pid, root_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, root_pid)

    assert_receive {^port, {:data, "ready\n"}}, 5_000

    {:ok, identity_calls} = Agent.start_link(fn -> 0 end)

    identity_reader = fn
      ^root_pid ->
        call = Agent.get_and_update(identity_calls, &{&1, &1 + 1})
        if call == 0, do: {:ok, :original}, else: {:ok, :replacement}

      _other_pid ->
        flunk("replacement children must not be identity-checked")
    end

    assert :ok =
             track_close(
               tracker,
               PortKiller.close(port,
                 identity_reader: identity_reader,
                 helper_paths: %{"kill" => kill_helper, "pgrep" => pgrep_helper}
               )
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

    assert :ok = track_close(tracker, PortKiller.retry_cleanup(cleanup))
    refute File.exists?(signal_log)
  end

  test "transient initial unknown identity is retried and completes cleanup after identity recovery" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-transient-id-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

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

    assert {:os_pid, os_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, os_pid)

    assert_receive {^port, {:data, "ready\n"}}, 5_000

    calls = :atomics.new(1, [])

    reader = fn
      pid when pid == os_pid ->
        if :atomics.add_get(calls, 1, 1) == 1 do
          :unknown
        else
          {:ok, :recovered}
        end

      _other_pid ->
        {:ok, :descendant_recovered}
    end

    # Initial close returns snapshot timeout because first read returned :unknown
    assert {:error,
            {:cleanup_timeout, %PortKiller.Cleanup{phase: :snapshot, targets: [target]} = cleanup}} =
             PortKiller.close(port, identity_reader: reader)

    track_cleanup(tracker, cleanup)

    assert target.pid == os_pid
    assert target.identity == :unknown
    assert :atomics.get(calls, 1) == 1
    assert process_alive?(os_pid)

    # Retrying cleanup retries identity while the port confirms the root PID,
    # recovers the identity, and completes cleanup.
    assert :ok = track_close(tracker, PortKiller.retry_cleanup(cleanup))
    refute process_alive?(os_pid)
    assert :atomics.get(calls, 1) > 1
  end

  test "confirmed child exit while identity is pending completes cleanup without retaining indefinitely" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-pending-exit-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

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

    assert {:os_pid, os_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, os_pid)

    assert_receive {^port, {:data, "ready\n"}}, 5_000

    reader = fn ^os_pid -> :unknown end

    assert {:error,
            {:cleanup_timeout, %PortKiller.Cleanup{phase: :snapshot, targets: [target]} = cleanup}} =
             PortKiller.close(port, identity_reader: reader)

    track_cleanup(tracker, cleanup)

    assert target.pid == os_pid
    assert target.identity == :unknown
    assert process_alive?(os_pid)

    # Kill the child so child exit is confirmed
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    wait_until(fn -> refute process_alive?(os_pid) end)

    # Confirmed child exit while identity is pending does not retain cleanup forever
    assert :ok = track_close(tracker, PortKiller.retry_cleanup(cleanup))
  end

  test "confirmed child exit while root identity is pending retains and cleans up descendants" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-descendants-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

    command = Path.join(tmp_dir, "parent")

    File.write!(
      command,
      """
      #!/bin/sh
      sh -c "trap '' TERM; while true; do sleep 1; done" &
      printf '%s\\n' "$!"
      trap '' TERM
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

    assert {:os_pid, root_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, root_pid)

    assert_receive {^port, {:data, data}}, 5_000
    child_pid = data |> String.trim() |> String.to_integer()
    register_target(tracker, child_pid)

    cleanup = %PortKiller.Cleanup{
      phase: :snapshot,
      root_pid: root_pid,
      targets: [
        %PortKiller.Target{pid: root_pid, identity: :unknown},
        %PortKiller.Target{pid: child_pid, identity: {:portable_ps, "child_known"}}
      ],
      opts: %{
        cleanup_timeout_ms: 2_000,
        helper_timeout_ms: 500,
        helper_paths: %{},
        identity_reader: fn
          ^root_pid -> :gone
          ^child_pid -> {:ok, {:portable_ps, "child_known"}}
          _ -> :unknown
        end
      },
      port: port
    }

    track_cleanup(tracker, cleanup)

    # Kill root PID so root exit is confirmed while child is still alive
    System.cmd("kill", ["-KILL", Integer.to_string(root_pid)], stderr_to_stdout: true)
    wait_until(fn -> refute process_alive?(root_pid) end)
    assert process_alive?(child_pid)

    # Retrying cleanup cleans up the retained descendant without hanging
    assert :ok = track_close(tracker, PortKiller.retry_cleanup(cleanup))
    refute process_alive?(child_pid)
  end

  test "unknown identity is not retried when port no longer confirms root PID" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-no-port-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

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

    assert {:os_pid, os_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, os_pid)

    assert_receive {^port, {:data, "ready\n"}}, 5_000

    cleanup = %PortKiller.Cleanup{
      phase: :snapshot,
      root_pid: os_pid,
      targets: [%PortKiller.Target{pid: os_pid, identity: :unknown}],
      opts: %{
        cleanup_timeout_ms: 200,
        helper_timeout_ms: 100,
        helper_paths: %{},
        identity_reader: fn _pid -> {:ok, :attacker_replaced} end
      },
      # port is nil: port does NOT confirm the root PID
      port: nil
    }

    track_cleanup(tracker, cleanup)

    # Must fail closed with cleanup_timeout, never accepting the replacement identity
    # and never signalling the unverified PID
    assert {:error, {:cleanup_timeout, %PortKiller.Cleanup{targets: [retained]}}} =
             track_close(tracker, PortKiller.retry_cleanup(cleanup))

    assert retained.identity == :unknown
    assert process_alive?(os_pid)
  end

  test "earliest known identity is never replaced by a later observation" do
    target_early = %PortKiller.Target{pid: 50_001, identity: :early_known}
    target_late = %PortKiller.Target{pid: 50_001, identity: :late_replacement}
    target_unknown = %PortKiller.Target{pid: 50_002, identity: :unknown}
    target_recovered = %PortKiller.Target{pid: 50_002, identity: :recovered_known}

    # Known identity is never replaced by later observation
    retained_known = %{50_001 => target_early}
    discovered_changed = %{50_001 => target_late}
    merged1 = PortKiller.merge_target_maps(retained_known, discovered_changed)
    assert Map.get(merged1, 50_001).identity == :early_known

    # Unknown identity is resolved by authoritative discovered identity
    retained_unknown = %{50_002 => target_unknown}
    discovered_known = %{50_002 => target_recovered}
    merged2 = PortKiller.merge_target_maps(retained_unknown, discovered_known)
    assert Map.get(merged2, 50_002).identity == :recovered_known

    # Discovered unknown never replaces retained known
    discovered_unknown = %{50_001 => target_unknown}
    merged3 = PortKiller.merge_target_maps(retained_known, discovered_unknown)
    assert Map.get(merged3, 50_001).identity == :early_known
  end

  test "fallback reaper requires original-port ownership or captured identity and refuses bare alive reused PID" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-reap-id-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

    command = Path.join(tmp_dir, "stubborn")
    File.write!(command, "#!/bin/sh\ntrap '' TERM\nwhile true; do sleep 1; done\n")
    File.chmod!(command, 0o755)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    assert {:os_pid, os_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, os_pid)

    # 1. Original port ownership authorizes signalling
    assert authorized_to_signal?(os_pid, :unknown, port)

    # 2. Matching captured identity authorizes signalling even without port
    {:ok, captured_id} = capture_identity(os_pid)
    assert authorized_to_signal?(os_pid, captured_id, nil)

    # 3. Bare PID without captured identity or port ownership is REFUSED
    refute authorized_to_signal?(os_pid, nil, nil)
    refute authorized_to_signal?(os_pid, :unknown, nil)

    # 4. Mismatched/reused identity is REFUSED
    refute authorized_to_signal?(os_pid, {:portable_ps, "reused_at_2020"}, nil)
    refute authorized_to_signal?(os_pid, {:linux_starttime, "99999999"}, nil)

    # 5. reap_pid with bare PID does NOT kill the process even though process_alive? is true
    assert process_alive?(os_pid)
    assert :ok = reap_pid(os_pid)
    assert process_alive?(os_pid)
  end

  test "startup failure before readiness assertion cleans up allocated port and OS child" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-early-fail-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

    command = Path.join(tmp_dir, "unready")
    File.write!(command, "#!/bin/sh\ntrap '' TERM\nwhile true; do sleep 1; done\n")
    File.chmod!(command, 0o755)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    assert {:os_pid, os_pid} = Port.info(port, :os_pid)
    # Registration happens immediately before any fallible readiness assertion
    register_port(tracker, port, os_pid)
    assert process_alive?(os_pid)

    # Simulate teardown triggered before readiness completes
    reap_fixture(tracker)

    refute process_alive?(os_pid)
    refute File.exists?(tmp_dir)
  end

  test "snapshot-timeout fallback retains and reaps owned descendant tree on assertion failure" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-tree-fallback-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

    command = Path.join(tmp_dir, "parent-with-child")

    File.write!(command, """
    #!/bin/sh
    trap '' TERM
    sh -c "trap '' TERM; while true; do sleep 1; done" &
    printf '%s\\n' "$!"
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

    assert {:os_pid, root_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, root_pid)

    assert_receive {^port, {:data, data}}, 5_000
    child_pid = data |> String.trim() |> String.to_integer()
    register_target(tracker, child_pid)

    assert process_alive?(root_pid)
    assert process_alive?(child_pid)

    # Simulate snapshot timeout that freezes targets and returns cleanup with both root and child
    {:ok, root_id} = capture_identity(root_pid)
    {:ok, child_id} = capture_identity(child_pid)

    simulated_cleanup = %PortKiller.Cleanup{
      phase: :snapshot,
      root_pid: root_pid,
      targets: [
        %PortKiller.Target{pid: root_pid, identity: root_id},
        %PortKiller.Target{pid: child_pid, identity: child_id}
      ],
      opts: %{cleanup_timeout_ms: 100, helper_timeout_ms: 50, helper_paths: %{}},
      port: port
    }

    # Simulate that PortKiller.close returned a snapshot timeout and was tracked
    track_cleanup(tracker, simulated_cleanup)

    # Teardown must reap BOTH root and child, without leaving stopped child reparented
    reap_fixture(tracker)

    refute process_alive?(root_pid)
    refute process_alive?(child_pid)
    refute File.exists?(tmp_dir)
  end

  test "duplicate target merging retains earliest known identity over unknown token" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-dup-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

    command = Path.join(tmp_dir, "sleeper")
    File.write!(command, "#!/bin/sh\nwhile true; do sleep 1; done\n")
    File.chmod!(command, 0o755)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    assert {:os_pid, pid} = Port.info(port, :os_pid)
    # Register port immediately before any fallible readiness or identity assertions
    register_port(tracker, port, pid)
    assert {:ok, known_id} = capture_identity(pid)

    # Register target with known identity
    register_target(tracker, pid)

    # Simulate a Cleanup struct that contains the same PID with identity :unknown
    simulated_cleanup = %PortKiller.Cleanup{
      phase: :snapshot,
      root_pid: pid,
      targets: [
        %PortKiller.Target{pid: pid, identity: :unknown}
      ],
      opts: %{cleanup_timeout_ms: 100, helper_timeout_ms: 50, helper_paths: %{}},
      port: port
    }

    track_cleanup(tracker, simulated_cleanup)

    # Verify merge_duplicate_targets retained known_id rather than :unknown
    state = Agent.get(tracker, & &1)
    {targets, errors} = collect_reap_targets(state)
    assert errors == []
    assert {^pid, ^known_id, _port} = Enum.find(targets, fn {p, _, _} -> p == pid end)

    # Teardown can now successfully reap because known identity was preserved
    reap_fixture(tracker)
    refute process_alive?(pid)
    refute File.exists?(tmp_dir)
  end

  test "live unknown ownership is an explicit teardown failure rather than absence" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-live-unknown-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

    command = Path.join(tmp_dir, "unreapable")
    File.write!(command, "#!/bin/sh\nwhile true; do sleep 1; done\n")
    File.chmod!(command, 0o755)

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    assert {:os_pid, pid} = Port.info(port, :os_pid)
    # Register real allocated port and root immediately before any fallible assertions
    register_port(tracker, port, pid)

    # Exercise intentionally unknown ownership on a simulation tracker
    # where the target has unknown identity and no port ownership
    {:ok, sim_tracker} =
      Agent.start(fn ->
        %{
          tmp_dir: tmp_dir,
          port: nil,
          root_pid: nil,
          root_identity: nil,
          cleanup: nil,
          extra_targets: %{},
          pid_files: []
        }
      end)

    simulated_cleanup = %PortKiller.Cleanup{
      phase: :reap,
      root_pid: pid,
      targets: [
        %PortKiller.Target{pid: pid, identity: :unknown}
      ],
      opts: %{cleanup_timeout_ms: 100, helper_timeout_ms: 50, helper_paths: %{}},
      port: nil
    }

    track_cleanup(sim_tracker, simulated_cleanup)

    # reap_fixture on sim_tracker must refuse to signal unauthorized target and raise,
    # leaving the process alive and the fixture directory intact.
    assert_raise RuntimeError,
                 ~r/PortKiller fixture teardown failed: owned processes still alive/,
                 fn ->
                   reap_fixture(sim_tracker)
                 end

    assert File.exists?(tmp_dir)
    assert process_alive?(pid)

    Agent.stop(sim_tracker, :normal)

    # Real tracker safely reaps the registered port and root on normal teardown
    reap_fixture(tracker)
    refute process_alive?(pid)
    refute File.exists?(tmp_dir)
  end

  test "process_liveness distinguishes confirmed absence from alive/permission and helper errors" do
    beam_pid = System.pid() |> String.to_integer()

    # Live BEAM process is alive
    assert :alive = process_liveness(beam_pid)
    assert process_alive?(beam_pid)
    refute wait_until_os_process_dead(beam_pid, 1)

    # PID 1 is alive with permission denied, not absence!
    assert {:alive, :permission_denied} = process_liveness(1)
    assert process_alive?(1)
    refute wait_until_os_process_dead(1, 1)

    # Nonexistent process is confirmed absence
    assert :confirmed_absence = process_liveness(999_999)
    refute process_alive?(999_999)
    assert wait_until_os_process_dead(999_999, 1)

    # Invalid PID is error
    assert {:error, :invalid_pid} = process_liveness(-1)
    assert {:error, :invalid_pid} = process_liveness(nil)
    refute process_alive?(-1)
    refute wait_until_os_process_dead(-1, 1)
  end

  test "reap_fixture retains collected child targets in tracker before root destruction and on retry" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-retain-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

    command = Path.join(tmp_dir, "spawner")

    File.write!(command, """
    #!/bin/sh
    sh -c 'while true; do sleep 1; done' &
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

    assert {:os_pid, root_pid} = Port.info(port, :os_pid)
    register_port(tracker, port, root_pid)

    # Wait until child is spawned
    wait_until(fn ->
      assert {:ok, [_ | _]} = discover_child_pids(root_pid)
    end)

    {:ok, [child_pid | _]} = discover_child_pids(root_pid)
    assert process_alive?(child_pid)

    # Simulate failed ps identity lookup for discovered child so it cannot be authorized to signal
    Agent.update(tracker, fn state ->
      %{state | identity_overrides: Map.put(state.identity_overrides, child_pid, :unknown)}
    end)

    # reap_fixture will reap the authorized root (via port), but refuse to reap the unauthorized child.
    # It must raise and retain the tracker and tmp_dir.
    assert_raise RuntimeError,
                 ~r/PortKiller fixture teardown failed: owned processes still alive/,
                 fn ->
                   reap_fixture(tracker)
                 end

    # Root is dead
    refute process_alive?(root_pid)
    # Child is still alive (reparented)
    assert process_alive?(child_pid)
    assert File.exists?(tmp_dir)

    # The tracker in-memory state MUST have retained child_pid in extra_targets before root was killed!
    state = Agent.get(tracker, & &1)
    assert Map.has_key?(state.extra_targets, child_pid)

    # Root is now dead, so discover_child_pids(root_pid) returns no children
    assert {:ok, []} = discover_child_pids(root_pid)

    # But on a retry of reap_fixture(tracker), the reparented child is STILL tracked from extra_targets
    # and teardown fails again rather than reporting false clean success!
    assert_raise RuntimeError,
                 ~r/PortKiller fixture teardown failed: owned processes still alive/,
                 fn ->
                   reap_fixture(tracker)
                 end

    assert File.exists?(tmp_dir)

    # Clean up child manually and verify final reap completes
    System.cmd("kill", ["-KILL", Integer.to_string(child_pid)], stderr_to_stdout: true)
    wait_until_os_process_dead(child_pid, 20)
    reap_fixture(tracker)
    refute File.exists?(tmp_dir)
  end

  test "child discovery distinguishes exit 1 no-match from helper failure" do
    # A non-existent PID has no children -> pgrep exits 1 -> returns {:ok, []}
    assert {:ok, []} = discover_child_pids(999_999)

    # Invalid PID returns {:ok, []}
    assert {:ok, []} = discover_child_pids(nil)
    assert {:ok, []} = discover_child_pids(-1)
  end

  test "reap_fixture retains tracker and directory when target collection fails" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-coll-fail-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

    # Create an invalid PID file so that collect_reap_targets returns a collection error
    bad_pid_file = Path.join(tmp_dir, "bad.pid")
    File.write!(bad_pid_file, "not-a-pid\n")
    register_pid_file(tracker, bad_pid_file)

    # reap_fixture should raise with path and targets, without stopping tracker or removing tmp_dir
    assert_raise RuntimeError,
                 ~r/PortKiller fixture teardown failed: target collection failed/,
                 fn ->
                   reap_fixture(tracker)
                 end

    assert File.exists?(tmp_dir)
    assert Process.alive?(tracker)

    # A subsequent get on the tracker still returns the state with tmp_dir and pid_files
    state = Agent.get(tracker, & &1)
    assert state.tmp_dir == tmp_dir
    assert state.pid_files == [bad_pid_file]

    # Clean up
    Agent.stop(tracker, :normal)
    File.rm_rf!(tmp_dir)
  end

  test "child discovery is refused when root pid identity is not validated" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cympho-port-killer-unauth-root-#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    tracker = init_fixture(tmp_dir)

    # Use the BEAM process as a live root PID, but with mismatched identity and no port
    beam_pid = System.pid() |> String.to_integer()

    Agent.update(tracker, fn state ->
      %{state | root_pid: beam_pid, root_identity: {:portable_ps, "wrong-identity"}, port: nil}
    end)

    state = Agent.get(tracker, & &1)
    {targets, errors} = collect_reap_targets(state)

    assert errors == [{:unauthorized_root_pid_for_child_discovery, beam_pid}]
    # No children of BEAM should be discovered
    refute Enum.any?(targets, fn {pid, _, _} -> pid != beam_pid end)

    # reap_fixture must raise without killing BEAM or its children, and without stopping the tracker
    assert_raise RuntimeError,
                 ~r/PortKiller fixture teardown failed: target collection failed/,
                 fn ->
                   reap_fixture(tracker)
                 end

    assert File.exists?(tmp_dir)
    assert Process.alive?(tracker)

    # Clean up tracker and tmp_dir safely
    Agent.update(tracker, fn s -> %{s | root_pid: nil} end)
    Agent.stop(tracker, :normal)
    File.rm_rf!(tmp_dir)
  end

  defp init_fixture(tmp_dir) do
    {:ok, tracker} =
      Agent.start(fn ->
        %{
          tmp_dir: tmp_dir,
          port: nil,
          root_pid: nil,
          root_identity: nil,
          cleanup: nil,
          extra_targets: %{},
          pid_files: [],
          identity_overrides: %{}
        }
      end)

    on_exit(fn ->
      reap_fixture(tracker)
    end)

    tracker
  end

  defp register_port(tracker, port, root_pid)
       when is_port(port) and is_integer(root_pid) and root_pid > 1 do
    identity =
      case capture_identity(root_pid) do
        {:ok, id} -> id
        _ -> :unknown
      end

    Agent.update(tracker, fn state ->
      %{state | port: port, root_pid: root_pid, root_identity: identity}
    end)
  end

  defp register_target(tracker, pid) when is_integer(pid) and pid > 1 do
    identity =
      case capture_identity(pid) do
        {:ok, id} -> id
        _ -> :unknown
      end

    Agent.update(tracker, fn state ->
      %{state | extra_targets: Map.put(state.extra_targets, pid, identity)}
    end)
  end

  defp register_pid_file(tracker, pid_file) when is_binary(pid_file) do
    Agent.update(tracker, fn state ->
      %{state | pid_files: [pid_file | state.pid_files]}
    end)
  end

  defp track_cleanup(tracker, %PortKiller.Cleanup{} = cleanup) do
    Agent.update(tracker, fn state ->
      %{state | cleanup: cleanup}
    end)
  end

  defp track_close(tracker, result) do
    case result do
      {:error, {:cleanup_timeout, %PortKiller.Cleanup{} = cleanup}} ->
        track_cleanup(tracker, cleanup)
        result

      other ->
        other
    end
  end

  defp reap_fixture(tracker) do
    state =
      try do
        Agent.get(tracker, & &1)
      catch
        :exit, _ -> nil
      end

    if state do
      {targets, collection_errors} = collect_reap_targets(state)

      # Merge newly collected targets into tracker state before any destructive reaping!
      try do
        Agent.update(tracker, fn current_state ->
          updated_extra =
            Enum.reduce(targets, current_state.extra_targets, fn {pid, identity, _port}, acc ->
              case Map.get(acc, pid) do
                nil ->
                  Map.put(acc, pid, identity)

                existing_id
                when existing_id in [nil, :unknown] and identity not in [nil, :unknown] ->
                  Map.put(acc, pid, identity)

                _ ->
                  acc
              end
            end)

          %{current_state | extra_targets: updated_extra}
        end)
      catch
        :exit, _ -> :ok
      end

      cond do
        collection_errors != [] ->
          # Do NOT reap known targets (which would destroy root needed for child discovery)
          # and do NOT stop the tracker or delete the directory.
          # Preserve ownership state in the tracker for diagnosis or subsequent retry.
          raise "PortKiller fixture teardown failed: target collection failed: #{inspect(collection_errors)}, path: #{inspect(state.tmp_dir)}, targets: #{inspect(targets)}"

        true ->
          Enum.each(targets, fn {pid, identity, port} ->
            reap_target(pid, identity, port)
          end)

          # Check for any remaining living processes among tracked targets.
          # Live unknown ownership or helper error is an explicit cleanup failure, not absence!
          survivors =
            Enum.filter(targets, fn {pid, _identity, _port} ->
              case process_liveness(pid) do
                :confirmed_absence -> false
                _ -> true
              end
            end)

          if survivors != [] do
            survivor_details =
              Enum.map(survivors, fn {pid, identity, port} ->
                case process_liveness(pid) do
                  {:error, reason} ->
                    {:liveness_helper_error, pid, reason}

                  _ ->
                    if authorized_to_signal?(pid, identity, port) do
                      {:authorized_survivor, pid, identity}
                    else
                      {:unauthorized_live_target, pid, identity}
                    end
                end
              end)

            raise "PortKiller fixture teardown failed: owned processes still alive: #{inspect(survivor_details)}, path: #{inspect(state.tmp_dir)}, targets: #{inspect(targets)}"
          else
            try do
              Agent.stop(tracker, :normal)
            catch
              _, _ -> :ok
            end

            File.rm_rf!(state.tmp_dir)
          end
      end
    end
  end

  defp collect_reap_targets(state) do
    cleanup_targets =
      case state.cleanup do
        %PortKiller.Cleanup{targets: targets} ->
          Enum.map(targets, fn %PortKiller.Target{pid: t_pid, identity: t_id} ->
            identity =
              if t_pid == state.root_pid and state.root_identity not in [nil, :unknown] do
                state.root_identity
              else
                t_id
              end

            {t_pid, identity, state.port}
          end)

        _ ->
          []
      end

    {discovered_children, discovery_errors} =
      cond do
        state.root_pid &&
          authorized_to_signal?(state.root_pid, state.root_identity, state.port) &&
            process_alive?(state.root_pid) ->
          case discover_child_pids(state.root_pid) do
            {:ok, child_pids} ->
              children =
                Enum.map(child_pids, fn c_pid ->
                  id_result =
                    case Map.get(Map.get(state, :identity_overrides, %{}), c_pid) do
                      override when override in [:unknown, :gone] -> override
                      _ -> capture_identity(c_pid)
                    end

                  case id_result do
                    {:ok, id} -> {c_pid, id, nil}
                    _ -> {c_pid, :unknown, nil}
                  end
                end)

              {children, []}

            {:error, reason} ->
              {[], [reason]}
          end

        state.root_pid && process_liveness(state.root_pid) != :confirmed_absence ->
          case process_liveness(state.root_pid) do
            {:error, reason} ->
              {[], [{:root_pid_liveness_error, state.root_pid, reason}]}

            _ ->
              {[], [{:unauthorized_root_pid_for_child_discovery, state.root_pid}]}
          end

        true ->
          {[], []}
      end

    {pid_file_targets, pid_file_errors} =
      Enum.reduce(state.pid_files, {[], []}, fn pid_file, {targets_acc, errors_acc} ->
        if File.exists?(pid_file) do
          case File.read(pid_file) do
            {:ok, contents} ->
              case Integer.parse(String.trim(contents)) do
                {pid, ""} when pid > 1 ->
                  case capture_identity(pid) do
                    {:ok, id} -> {[{pid, id, nil} | targets_acc], errors_acc}
                    _ -> {[{pid, :unknown, nil} | targets_acc], errors_acc}
                  end

                _ ->
                  {targets_acc, [{:invalid_pid_file_content, pid_file, contents} | errors_acc]}
              end

            {:error, reason} ->
              {targets_acc, [{:read_pid_file_failed, pid_file, reason} | errors_acc]}
          end
        else
          {targets_acc, errors_acc}
        end
      end)

    root_target =
      if state.root_pid do
        [{state.root_pid, state.root_identity, state.port}]
      else
        []
      end

    extra_targets =
      Enum.map(state.extra_targets, fn {pid, identity} ->
        current_identity =
          cond do
            Map.get(Map.get(state, :identity_overrides, %{}), pid) == :unknown ->
              :unknown

            identity in [nil, :unknown] ->
              case capture_identity(pid) do
                {:ok, id} -> id
                _ -> identity
              end

            true ->
              identity
          end

        {pid, current_identity, nil}
      end)

    all_targets =
      extra_targets ++ cleanup_targets ++ discovered_children ++ pid_file_targets ++ root_target

    merged_targets = merge_duplicate_targets(all_targets)
    all_errors = discovery_errors ++ pid_file_errors

    {merged_targets, all_errors}
  end

  defp merge_duplicate_targets(targets) do
    targets
    |> Enum.group_by(fn {pid, _id, _port} -> pid end)
    |> Enum.map(fn {pid, entries} ->
      known_entry =
        Enum.find(entries, fn {_p, id, _port} ->
          id not in [nil, :unknown]
        end)

      identity =
        case known_entry do
          {_p, known_id, _port} -> known_id
          nil -> :unknown
        end

      port =
        case Enum.find(entries, fn {_p, _id, port} -> is_port(port) end) do
          {_p, _id, valid_port} -> valid_port
          nil -> nil
        end

      {pid, identity, port}
    end)
  end

  defp reap_target(pid, identity, port) when is_integer(pid) and pid > 1 do
    if authorized_to_signal?(pid, identity, port) do
      System.cmd("kill", ["-CONT", Integer.to_string(pid)], stderr_to_stdout: true)
      System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      wait_until_os_process_dead(pid, 20)
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp authorized_to_signal?(pid, identity, port) when is_integer(pid) and pid > 1 do
    cond do
      is_port(port) and Port.info(port, :os_pid) == {:os_pid, pid} ->
        true

      identity != nil and identity != :unknown ->
        case capture_identity(pid) do
          {:ok, ^identity} -> true
          _ -> false
        end

      true ->
        false
    end
  end

  defp authorized_to_signal?(_pid, _identity, _port), do: false

  defp capture_identity(pid) when is_integer(pid) and pid > 1 do
    case process_liveness(pid) do
      :confirmed_absence ->
        :gone

      :alive ->
        if File.exists?("/proc/#{pid}/stat") do
          case File.read("/proc/#{pid}/stat") do
            {:ok, stat} ->
              case :binary.matches(stat, ") ") |> List.last() do
                {index, 2} ->
                  fields =
                    stat |> binary_part(index + 2, byte_size(stat) - index - 2) |> String.split()

                  case Enum.at(fields, 19) do
                    nil -> :unknown
                    starttime -> {:ok, {:linux_starttime, starttime}}
                  end

                _ ->
                  :unknown
              end

            {:error, :enoent} ->
              if process_liveness(pid) == :confirmed_absence, do: :gone, else: :unknown

            _ ->
              :unknown
          end
        else
          case System.cmd("ps", ["-o", "lstart=", "-p", Integer.to_string(pid)],
                 stderr_to_stdout: true
               ) do
            {output, 0} ->
              case String.trim(output) do
                "" ->
                  if process_liveness(pid) == :confirmed_absence, do: :gone, else: :unknown

                val ->
                  {:ok, {:portable_ps, val}}
              end

            {_output, _status} ->
              if process_liveness(pid) == :confirmed_absence do
                :gone
              else
                :unknown
              end
          end
        end

      _other ->
        :unknown
    end
  rescue
    _ ->
      if is_integer(pid) and pid > 1 and process_liveness(pid) == :confirmed_absence do
        :gone
      else
        :unknown
      end
  end

  defp capture_identity(_), do: :unknown

  defp discover_child_pids(parent_pid) when is_integer(parent_pid) and parent_pid > 1 do
    case System.cmd("pgrep", ["-P", Integer.to_string(parent_pid)], stderr_to_stdout: true) do
      {output, 0} ->
        pids =
          output
          |> String.split()
          |> Enum.flat_map(fn str ->
            case Integer.parse(str) do
              {pid, ""} when pid > 1 -> [pid]
              _ -> []
            end
          end)

        {:ok, pids}

      {_output, 1} ->
        # Exit status 1 means no matching children (standard pgrep convention)
        {:ok, []}

      {output, exit_status} ->
        {:error, {:pgrep_failed, exit_status, output}}
    end
  rescue
    e ->
      {:error, {:pgrep_error, e}}
  end

  defp discover_child_pids(_), do: {:ok, []}

  defp reap_pid(nil), do: :ok

  defp reap_pid(pid) when is_integer(pid) and pid > 1 do
    reap_pid(pid, nil, nil)
  end

  defp reap_pid(_), do: :ok

  defp reap_pid(pid, identity, port) when is_integer(pid) and pid > 1 do
    reap_target(pid, identity, port)
  end

  defp reap_pid(_, _identity, _port), do: :ok

  defp process_liveness(os_pid) when is_integer(os_pid) and os_pid > 0 do
    kill_cmd = System.find_executable("kill") || "/bin/kill"

    case System.cmd(kill_cmd, ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} ->
        :alive

      {output, _status} ->
        lower = String.downcase(output)

        cond do
          String.contains?(lower, "no such process") or
            String.contains?(lower, "esrch") or
              String.contains?(lower, "cannot find process") ->
            :confirmed_absence

          String.contains?(lower, "operation not permitted") or
            String.contains?(lower, "not permitted") or
              String.contains?(lower, "eperm") ->
            {:alive, :permission_denied}

          true ->
            {:error, {:unexpected_kill_output, output}}
        end
    end
  rescue
    e ->
      {:error, e}
  end

  defp process_liveness(_), do: {:error, :invalid_pid}

  defp process_alive?(os_pid) when is_integer(os_pid) and os_pid > 0 do
    case process_liveness(os_pid) do
      :alive -> true
      {:alive, _} -> true
      _ -> false
    end
  end

  defp process_alive?(_), do: false

  defp wait_until_os_process_dead(os_pid, attempts) when attempts > 0 do
    case process_liveness(os_pid) do
      :confirmed_absence ->
        true

      _ ->
        Process.sleep(25)
        wait_until_os_process_dead(os_pid, attempts - 1)
    end
  end

  defp wait_until_os_process_dead(_os_pid, 0), do: false
end
