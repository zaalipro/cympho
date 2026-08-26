defmodule Cympho.PortKiller do
  @moduledoc """
  Bounded shutdown for OS processes owned by Erlang ports.

  The direct port child and its descendants are snapshotted and frozen to a
  fixed point before the port is closed, then signalled by positive PID only.
  Linux discovery reads `/proc/<pid>/task/<tid>/children`; other supported
  systems require `pgrep` (with `ps` as a fallback). Every helper command and
  cleanup attempt has a hard deadline. Callers that receive `{:error,
  {:cleanup_timeout, cleanup}}` must keep their worker alive and call
  `await_cleanup/2`; it retries bounded attempts until every snapshotted target
  is confirmed gone. An uninterruptible kernel process can therefore retain its
  worker/admission claim indefinitely, which is safer than starting a second
  writer in the same workspace. This module cannot discover a background child
  that was already reparented before `close/2` obtained the port child's PID;
  callers must invoke cleanup while the direct port child is still registered.
  Linux targets are rechecked by `/proc` start time. Other systems use process
  start time from `ps`; platforms whose process listing has coarse start times
  retain a narrow same-second PID-reuse residual. These checks narrow PID reuse
  across discovery and retries, but an external signal is not identity-atomic;
  eliminating the final check-to-signal race requires pidfd or OS containment.
  """

  @default_cleanup_timeout_ms 1_000
  @default_helper_timeout_ms 100
  @default_retry_ms 100
  @max_retry_ms 1_000
  @helper_shutdown_timeout_ms 250
  @emergency_helper_timeout_ms 50
  @max_targets 4_096
  @max_output_bytes 64 * 1024
  @fallback_paths %{
    "kill" => ["/bin/kill", "/usr/bin/kill"],
    "pgrep" => ["/usr/bin/pgrep", "/bin/pgrep"],
    "ps" => ["/bin/ps", "/usr/bin/ps"]
  }

  defmodule Cleanup do
    @moduledoc false
    @enforce_keys [:phase, :root_pid, :targets, :opts]
    defstruct [:phase, :root_pid, :targets, :opts, :port]
  end

  defmodule Target do
    @moduledoc false
    @enforce_keys [:pid, :identity]
    defstruct [:pid, :identity]
  end

  @type cleanup_error :: {:cleanup_timeout, Cleanup.t()}

  @spec close(port(), keyword()) :: :ok | {:error, cleanup_error()}
  def close(port, opts \\ [])

  def close(port, opts) when is_port(port) do
    case os_pid(port) do
      nil ->
        close_port(port)
        :ok

      root_pid ->
        opts = clean_opts(opts)

        case target_identity(root_pid, opts.helper_timeout_ms, opts) do
          {:ok, identity} ->
            target = %Target{pid: root_pid, identity: identity}

            cleanup = %Cleanup{
              phase: :snapshot,
              root_pid: root_pid,
              targets: [target],
              opts: opts,
              port: port
            }

            if os_pid(port) == root_pid do
              attempt(cleanup, port)
            else
              {:error, {:cleanup_timeout, cleanup}}
            end

          :gone ->
            close_port(port)
            :ok

          :unknown ->
            cleanup = %Cleanup{
              phase: :snapshot,
              root_pid: root_pid,
              targets: [%Target{pid: root_pid, identity: :unknown}],
              opts: opts,
              port: port
            }

            {:error, {:cleanup_timeout, cleanup}}
        end
    end
  end

  def close(_port, _opts), do: :ok

  @doc "Closes a port and retains the caller until definitive cleanup succeeds."
  @spec close_and_await(port(), keyword()) :: :ok
  def close_and_await(port, opts \\ []) do
    case close(port, opts) do
      :ok ->
        :ok

      {:error, cleanup_error} ->
        await_cleanup(cleanup_error, opts)
    end
  end

  @doc "Retries one bounded cleanup attempt."
  @spec retry_cleanup(Cleanup.t()) :: :ok | {:error, cleanup_error()}
  def retry_cleanup(%Cleanup{} = cleanup), do: attempt(cleanup, cleanup.port)

  @doc "Retries bounded cleanup attempts until all snapshotted processes are gone."
  @spec await_cleanup(cleanup_error() | Cleanup.t(), keyword()) :: :ok
  def await_cleanup(cleanup_or_error, opts \\ []) do
    cleanup = unwrap_cleanup(cleanup_or_error)
    retry_ms = positive_opt(opts, :retry_ms, @default_retry_ms)
    on_retry = Keyword.get(opts, :on_retry, fn -> :ok end)

    case retry_cleanup(cleanup) do
      :ok ->
        :ok

      {:error, {:cleanup_timeout, next}} ->
        safe_notify(on_retry)

        receive after: (retry_ms ->
                          await_cleanup(next,
                            retry_ms: min(retry_ms * 2, @max_retry_ms),
                            on_retry: on_retry
                          ))
    end
  end

  defp attempt(%Cleanup{phase: :snapshot} = cleanup, port) do
    deadline = monotonic_ms() + cleanup.opts.cleanup_timeout_ms
    retained_targets = targets_by_pid(cleanup.targets)

    case process_tree(
           cleanup.root_pid,
           cleanup.opts,
           deadline,
           Map.get(retained_targets, cleanup.root_pid)
         ) do
      {:ok, targets} ->
        targets = merge_targets(retained_targets, targets)

        case freeze_tree(cleanup.root_pid, targets, cleanup.opts, deadline) do
          {:ok, frozen_targets} ->
            close_port(port)

            # Resuming a TERM-ignoring frozen process would reopen the fork
            # race. Forced cleanup therefore KILLs the fixed-point set while it
            # remains stopped.
            terminate_targets(
              %{
                cleanup
                | phase: :kill,
                  targets: frozen_targets,
                  port: nil
              },
              deadline
            )

          {:error, frozen_targets} ->
            {:error, {:cleanup_timeout, %{cleanup | targets: frozen_targets, port: port}}}
        end

      {:error, :timeout, discovered_targets} ->
        targets =
          merge_targets(retained_targets, discovered_targets)

        # Even failed discovery must not leave already known provider work
        # consuming CPU while the registered worker retains its admission.
        _ = freeze_targets(cleanup.root_pid, targets, deadline, cleanup.opts)

        {:error, {:cleanup_timeout, %{cleanup | targets: targets, port: port}}}
    end
  end

  defp attempt(%Cleanup{} = cleanup, _port), do: terminate_targets(cleanup)

  defp terminate_targets(%Cleanup{} = cleanup) do
    deadline = monotonic_ms() + cleanup.opts.cleanup_timeout_ms
    terminate_targets(cleanup, deadline)
  end

  defp terminate_targets(%Cleanup{targets: []}, _deadline), do: :ok

  defp terminate_targets(%Cleanup{} = cleanup, deadline) do
    signal_targets(cleanup.targets, "KILL", deadline, cleanup.opts)

    case wait_until_gone(cleanup.targets, deadline, cleanup.opts) do
      :ok ->
        :ok

      {:error, survivors} ->
        {:error, {:cleanup_timeout, %{cleanup | phase: :kill, targets: survivors}}}
    end
  end

  defp signal_targets([], _signal, _deadline, _opts), do: :ok

  defp signal_targets([target | rest], signal_name, deadline, opts) do
    remaining = deadline - monotonic_ms()

    if remaining > 0 do
      signal(target, signal_name, min(opts.helper_timeout_ms, remaining), opts)
      signal_targets(rest, signal_name, deadline, opts)
    else
      :timeout
    end
  end

  defp process_tree(root_pid, opts, deadline, nil) do
    collect([root_pid], %{}, deadline, opts)
  end

  defp process_tree(root_pid, opts, deadline, %Target{} = expected_root) do
    case same_target?(
           expected_root,
           min(opts.helper_timeout_ms, max(deadline - monotonic_ms(), 1)),
           opts
         ) do
      true -> collect([root_pid], %{}, deadline, opts)
      false -> {:ok, []}
      :unknown -> {:error, :timeout, []}
    end
  end

  defp collect([], seen, _deadline, _opts), do: {:ok, Map.values(seen)}

  defp collect([pid | rest], seen, deadline, opts) do
    cond do
      map_size(seen) >= @max_targets ->
        {:error, :timeout, Map.values(seen)}

      monotonic_ms() >= deadline ->
        {:error, :timeout, Map.values(seen)}

      Map.has_key?(seen, pid) ->
        collect(rest, seen, deadline, opts)

      true ->
        timeout = min(opts.helper_timeout_ms, max(deadline - monotonic_ms(), 1))

        case target_identity(pid, timeout, opts) do
          {:ok, identity} ->
            seen = Map.put(seen, pid, %Target{pid: pid, identity: identity})

            case child_pids(pid, timeout, opts) do
              {:ok, children} ->
                case target_identity(pid, timeout, opts) do
                  {:ok, ^identity} ->
                    collect(rest ++ children, seen, deadline, opts)

                  {:ok, _replacement_identity} ->
                    collect(rest, Map.delete(seen, pid), deadline, opts)

                  :gone ->
                    collect(rest, Map.delete(seen, pid), deadline, opts)

                  :unknown ->
                    {:error, :timeout, Map.values(seen)}
                end

              {:error, :timeout} ->
                {:error, :timeout, Map.values(seen)}
            end

          :gone ->
            collect(rest, seen, deadline, opts)

          :unknown ->
            target = %Target{pid: pid, identity: :unknown}
            {:error, :timeout, Map.values(Map.put(seen, pid, target))}
        end
    end
  end

  defp child_pids(pid, timeout, opts) do
    if Map.has_key?(opts.helper_paths, "pgrep") do
      pgrep_child_pids(pid, timeout, opts, false)
    else
      default_child_pids(pid, timeout, opts)
    end
  end

  defp default_child_pids(pid, timeout, opts) do
    case proc_child_pids(pid) do
      {:ok, children} -> {:ok, children}
      :unsupported -> pgrep_child_pids(pid, timeout, opts, true)
    end
  end

  defp pgrep_child_pids(pid, timeout, opts, fallback?) do
    case helper("pgrep", ["-P", Integer.to_string(pid)], timeout, opts) do
      {:ok, output, 0} ->
        {:ok, parse_pids(output)}

      {:ok, _output, 1} ->
        {:ok, []}

      _error_or_timeout when fallback? ->
        ps_child_pids(pid, timeout, opts)

      _error_or_timeout ->
        {:error, :timeout}
    end
  end

  defp ps_child_pids(parent_pid, timeout, opts) do
    case helper("ps", ["-axo", "pid=,ppid="], timeout, opts) do
      {:ok, output, 0} ->
        children =
          output
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case line |> String.split(~r/\s+/, trim: true) |> Enum.flat_map(&parse_pid/1) do
              [pid, ^parent_pid] -> [pid]
              _ -> []
            end
          end)

        {:ok, children}

      _error_or_timeout ->
        {:error, :timeout}
    end
  end

  defp proc_child_pids(pid) do
    if linux?() do
      case File.ls("/proc/#{pid}/task") do
        {:ok, thread_ids} -> read_thread_children(pid, thread_ids)
        {:error, :enoent} -> {:ok, []}
        {:error, _reason} -> :unsupported
      end
    else
      :unsupported
    end
  end

  defp read_thread_children(pid, thread_ids) do
    Enum.reduce_while(thread_ids, {:ok, MapSet.new()}, fn thread_id, {:ok, children} ->
      case File.read("/proc/#{pid}/task/#{thread_id}/children") do
        {:ok, output} ->
          {:cont, {:ok, Enum.reduce(parse_pids(output), children, &MapSet.put(&2, &1))}}

        {:error, :enoent} ->
          # Threads may exit while their siblings remain frozen.
          {:cont, {:ok, children}}

        {:error, _reason} ->
          {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, children} -> {:ok, MapSet.to_list(children)}
      :unsupported -> :unsupported
    end
  end

  defp freeze_tree(root_pid, targets, opts, deadline) do
    known = targets_by_pid(targets)
    freeze_round(root_pid, known, known, opts, deadline)
  end

  defp freeze_round(root_pid, known, pending, opts, deadline) do
    cond do
      map_size(known) > @max_targets or monotonic_ms() >= deadline ->
        {:error, Map.values(known)}

      true ->
        case freeze_targets(root_pid, Map.values(pending), deadline, opts) do
          :ok ->
            case process_tree(root_pid, opts, deadline, Map.get(known, root_pid)) do
              {:ok, rescanned} ->
                rescanned_by_pid = targets_by_pid(rescanned)
                new_targets = Map.drop(rescanned_by_pid, Map.keys(known))
                all_targets = merge_target_maps(known, rescanned_by_pid)

                if map_size(new_targets) == 0 do
                  {:ok, ordered_targets(root_pid, all_targets)}
                else
                  freeze_round(root_pid, all_targets, new_targets, opts, deadline)
                end

              {:error, :timeout, rescanned} ->
                all_targets = merge_target_maps(known, targets_by_pid(rescanned))
                _ = freeze_targets(root_pid, rescanned, deadline, opts)
                {:error, Map.values(all_targets)}
            end

          :timeout ->
            {:error, Map.values(known)}
        end
    end
  end

  defp freeze_targets(root_pid, targets, deadline, opts) do
    root_pid
    |> ordered_targets(targets_by_pid(targets))
    |> Enum.reduce_while(:ok, fn target, :ok ->
      if monotonic_ms() >= deadline do
        {:halt, :timeout}
      else
        timeout = min(opts.helper_timeout_ms, deadline - monotonic_ms())

        case signal(target, "STOP", timeout, opts) do
          :ok ->
            case await_stopped(target, deadline, opts) do
              :ok -> {:cont, :ok}
              :timeout -> {:halt, :timeout}
            end

          :gone ->
            {:cont, :ok}

          :unknown ->
            {:halt, :timeout}
        end
      end
    end)
  end

  defp await_stopped(%Target{} = target, deadline, opts) do
    case target_process_state(
           target,
           min(opts.helper_timeout_ms, max(deadline - monotonic_ms(), 1)),
           opts
         ) do
      state when state in [:stopped, :quiescent, :gone] ->
        :ok

      _running_or_unknown ->
        remaining = deadline - monotonic_ms()

        if remaining <= 0 do
          :timeout
        else
          receive after: (min(10, remaining) -> await_stopped(target, deadline, opts))
        end
    end
  end

  defp process_state(pid, timeout, opts) do
    case proc_process_state(pid) do
      state when state in [:stopped, :quiescent, :gone, :running] -> state
      :unsupported -> ps_process_state(pid, timeout, opts)
    end
  end

  defp target_identity(pid, _timeout, %{identity_reader: reader}) when is_function(reader, 1) do
    normalize_identity_result(reader.(pid))
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp target_identity(pid, timeout, _opts) do
    if linux?() do
      case File.read("/proc/#{pid}/stat") do
        {:ok, stat} -> linux_starttime(stat)
        {:error, :enoent} -> :gone
        {:error, _reason} -> :unknown
      end
    else
      portable_identity(pid, timeout)
    end
  end

  defp linux_starttime(stat) do
    case :binary.matches(stat, ") ") |> List.last() do
      {index, 2} ->
        fields = stat |> binary_part(index + 2, byte_size(stat) - index - 2) |> String.split()

        case Enum.at(fields, 19) do
          nil -> :unknown
          starttime -> {:ok, {:linux_starttime, starttime}}
        end

      nil ->
        :unknown
    end
  end

  defp portable_identity(pid, timeout) do
    deadline = monotonic_ms() + max(timeout, 1)

    with ps when is_binary(ps) <- emergency_path("ps"),
         {:ok, output, 0} <-
           emergency_command(
             ps,
             ["-o", "lstart=", "-p", Integer.to_string(pid)],
             deadline
           ),
         identity when identity != "" <- String.trim(output) do
      {:ok, {:portable_ps, identity}}
    else
      {:ok, _output, _status} -> :gone
      _ -> :unknown
    end
  end

  defp normalize_identity_result({:ok, identity}), do: {:ok, identity}
  defp normalize_identity_result(:gone), do: :gone
  defp normalize_identity_result(_other), do: :unknown

  defp same_target?(%Target{identity: :unknown}, _timeout, _opts), do: :unknown

  defp same_target?(%Target{pid: pid, identity: identity}, timeout, opts) do
    case target_identity(pid, timeout, opts) do
      {:ok, ^identity} -> true
      {:ok, _different_identity} -> false
      :gone -> false
      :unknown -> :unknown
    end
  end

  defp targets_by_pid(targets) when is_map(targets), do: targets

  defp targets_by_pid(targets) do
    Map.new(targets, fn %Target{pid: pid} = target -> {pid, target} end)
  end

  defp merge_targets(retained, discovered) do
    retained
    |> merge_target_maps(targets_by_pid(discovered))
    |> Map.values()
  end

  # The earliest identity wins. A rescan of a reused PID must never replace the
  # identity token that authorized the original retained target.
  defp merge_target_maps(retained, discovered), do: Map.merge(discovered, retained)

  defp target_process_state(%Target{} = target, timeout, opts) do
    case same_target?(target, timeout, opts) do
      true -> process_state(target.pid, timeout, opts)
      false -> :gone
      :unknown -> :unknown
    end
  end

  defp proc_process_state(pid) do
    if linux?() do
      case File.read("/proc/#{pid}/stat") do
        {:ok, stat} -> parse_proc_state(stat)
        {:error, :enoent} -> :gone
        {:error, _reason} -> :unsupported
      end
    else
      :unsupported
    end
  end

  defp parse_proc_state(stat) do
    case :binary.matches(stat, ") ") |> List.last() do
      {index, 2} ->
        case binary_part(stat, index + 2, 1) do
          state when state in ["T", "t"] -> :stopped
          state when state in ["Z", "X", "x"] -> :quiescent
          _state -> :running
        end

      nil ->
        :unsupported
    end
  end

  defp ps_process_state(pid, timeout, opts) do
    case helper("ps", ["-o", "state=", "-p", Integer.to_string(pid)], timeout, opts) do
      {:ok, output, 0} ->
        case String.trim(output) do
          <<state, _rest::binary>> when state in [?T, ?t] -> :stopped
          <<state, _rest::binary>> when state in [?Z, ?X, ?x] -> :quiescent
          "" -> :gone
          _state -> :running
        end

      {:ok, _output, _status} ->
        :gone

      {:error, _reason} ->
        :unknown
    end
  end

  defp ordered_targets(root_pid, targets) when is_map(targets) do
    case Map.pop(targets, root_pid) do
      {nil, rest} -> Map.values(rest)
      {root, rest} -> [root | Map.values(rest)]
    end
  end

  defp wait_until_gone(targets, deadline, opts), do: do_wait_until_gone(targets, deadline, opts)

  defp do_wait_until_gone(targets, deadline, opts) do
    {survivors, unknown?} = survivors(targets, deadline, opts, [], false)

    cond do
      survivors == [] ->
        :ok

      monotonic_ms() >= deadline ->
        {:error, Enum.reverse(survivors)}

      true ->
        remaining = max(deadline - monotonic_ms(), 1)
        delay = min(if(unknown?, do: 20, else: 10), remaining)
        receive after: (delay -> do_wait_until_gone(Enum.reverse(survivors), deadline, opts))
    end
  end

  defp survivors([], _deadline, _opts, survivors, unknown?),
    do: {Enum.reverse(survivors), unknown?}

  defp survivors([target | rest] = pending, deadline, opts, survivors, unknown?) do
    remaining = deadline - monotonic_ms()

    if remaining <= 0 do
      {Enum.reverse(survivors) ++ pending, true}
    else
      timeout = min(opts.helper_timeout_ms, remaining)

      case alive?(target, timeout, opts) do
        true -> survivors(rest, deadline, opts, [target | survivors], unknown?)
        false -> survivors(rest, deadline, opts, survivors, unknown?)
        :unknown -> survivors(rest, deadline, opts, [target | survivors], true)
      end
    end
  end

  defp alive?(%Target{} = target, timeout, opts) do
    case target_process_state(target, timeout, opts) do
      state when state in [:gone, :quiescent] ->
        false

      state when state in [:running, :stopped] ->
        true

      :unknown ->
        case helper("kill", ["-0", Integer.to_string(target.pid)], timeout, opts) do
          {:ok, _output, 0} -> true
          {:ok, _output, _status} -> false
          {:error, :timeout} -> :unknown
        end
    end
  end

  defp signal(%Target{pid: pid} = target, signal, timeout, opts) when pid > 1 do
    case same_target?(target, timeout, opts) do
      true ->
        case helper("kill", ["-#{signal}", Integer.to_string(pid)], timeout, opts) do
          {:ok, _output, 0} -> :ok
          {:ok, _output, _status} -> :gone
          {:error, :timeout} -> :unknown
        end

      false ->
        :gone

      :unknown ->
        :unknown
    end
  end

  defp signal(_target, _signal, _timeout, _opts), do: :unknown

  defp helper(name, args, timeout_ms, opts) do
    case executable(name, opts) do
      executable when is_binary(executable) -> run_helper(executable, args, timeout_ms)
      nil -> {:error, :timeout}
    end
  end

  defp run_helper(executable, args, timeout_ms) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, args}
      ])

    monitor = :erlang.monitor(:port, port)
    helper_pid = os_pid(port)
    started = monotonic_ms()
    timeout_ms = max(timeout_ms, 1)
    deadline = started + timeout_ms

    # Helper teardown is part of, rather than additional to, helper_timeout_ms.
    # Reserve enough of that budget to freeze and kill a custom helper subtree.
    teardown_ms = min(@helper_shutdown_timeout_ms, max(div(timeout_ms, 2), 50))
    command_deadline = max(started, deadline - teardown_ms)
    collect_helper(port, monitor, helper_pid, command_deadline, deadline, <<>>)
  rescue
    _ -> {:error, :timeout}
  catch
    _, _ -> {:error, :timeout}
  end

  defp collect_helper(port, monitor, helper_pid, command_deadline, deadline, output) do
    remaining = command_deadline - monotonic_ms()

    if remaining <= 0 do
      close_helper(port, monitor, helper_pid, deadline)
      {:error, :timeout}
    else
      receive do
        {^port, {:data, data}} ->
          retained =
            binary_part(output <> data, 0, min(byte_size(output <> data), @max_output_bytes))

          collect_helper(port, monitor, helper_pid, command_deadline, deadline, retained)

        {^port, {:exit_status, status}} ->
          close_port(port)
          await_helper_down_until(port, monitor, deadline)
          {:ok, output, status}

        {:DOWN, ^monitor, :port, ^port, _reason} ->
          {:ok, output, 1}
      after
        remaining ->
          close_helper(port, monitor, helper_pid, deadline)
          {:error, :timeout}
      end
    end
  end

  defp close_helper(port, monitor, helper_pid, deadline) do
    targets = freeze_helper_tree(helper_pid, deadline)
    close_port(port)
    force_helper_down(targets, port, monitor, deadline)
  end

  defp force_helper_down(targets, port, monitor, deadline) do
    kill = emergency_path("kill")
    force_helpers_until_gone(targets, kill, deadline)
    await_helper_down_until(port, monitor, deadline)
  rescue
    _ -> Process.demonitor(monitor, [:flush])
  end

  defp freeze_helper_tree(pid, deadline) when is_integer(pid) and pid > 1 do
    freeze_helper_round(pid, MapSet.new([pid]), deadline)
  end

  defp freeze_helper_tree(_pid, _deadline), do: []

  defp ordered_pids(root_pid, targets) do
    rest = targets |> MapSet.delete(root_pid) |> MapSet.to_list()
    if MapSet.member?(targets, root_pid), do: [root_pid | rest], else: rest
  end

  defp freeze_helper_round(root_pid, known, deadline) do
    case emergency_process_tree(root_pid, deadline) do
      {:ok, discovered} ->
        all = MapSet.union(known, MapSet.new(discovered))
        _ = emergency_signal("STOP", MapSet.to_list(all), deadline)

        case emergency_process_tree(root_pid, deadline) do
          {:ok, rescanned} ->
            rescanned = MapSet.new(rescanned)
            next = MapSet.union(all, rescanned)

            if MapSet.equal?(all, next) or MapSet.size(next) >= @max_targets or
                 monotonic_ms() >= deadline do
              ordered_pids(root_pid, next)
            else
              freeze_helper_round(root_pid, next, deadline)
            end

          {:error, retained} ->
            all |> MapSet.union(MapSet.new(retained)) |> MapSet.to_list()
        end

      {:error, retained} ->
        known |> MapSet.union(MapSet.new(retained)) |> MapSet.to_list()
    end
  end

  defp emergency_process_tree(root_pid, deadline) do
    if linux?() do
      case emergency_proc_tree([root_pid], MapSet.new(), deadline) do
        {:unsupported, retained} -> emergency_pgrep_tree([root_pid], retained, deadline)
        result -> result
      end
    else
      emergency_pgrep_tree([root_pid], MapSet.new(), deadline)
    end
  end

  defp emergency_proc_tree([], seen, _deadline), do: {:ok, MapSet.to_list(seen)}

  defp emergency_proc_tree([pid | rest], seen, deadline) do
    cond do
      monotonic_ms() >= deadline or MapSet.size(seen) >= @max_targets ->
        {:error, MapSet.to_list(seen)}

      MapSet.member?(seen, pid) ->
        emergency_proc_tree(rest, seen, deadline)

      true ->
        seen = MapSet.put(seen, pid)

        case proc_child_pids(pid) do
          {:ok, children} -> emergency_proc_tree(rest ++ children, seen, deadline)
          :unsupported -> {:unsupported, seen}
        end
    end
  end

  defp emergency_pgrep_tree([], seen, _deadline), do: {:ok, MapSet.to_list(seen)}

  defp emergency_pgrep_tree([pid | rest], seen, deadline) do
    cond do
      monotonic_ms() >= deadline or MapSet.size(seen) >= @max_targets ->
        {:error, MapSet.to_list(seen)}

      MapSet.member?(seen, pid) ->
        emergency_pgrep_tree(rest, seen, deadline)

      true ->
        seen = MapSet.put(seen, pid)

        with pgrep when is_binary(pgrep) <- emergency_path("pgrep"),
             result <- emergency_command(pgrep, ["-P", Integer.to_string(pid)], deadline) do
          case result do
            {:ok, output, 0} -> emergency_pgrep_tree(rest ++ parse_pids(output), seen, deadline)
            {:ok, _output, 1} -> emergency_pgrep_tree(rest, seen, deadline)
            _ -> emergency_ps_tree(pid, seen, deadline)
          end
        else
          _ -> emergency_ps_tree(pid, seen, deadline)
        end
    end
  end

  defp emergency_ps_tree(root_pid, retained, deadline) do
    with ps when is_binary(ps) <- emergency_path("ps"),
         {:ok, output, 0} <-
           emergency_command(ps, ["-axo", "pid=,ppid=,state="], deadline) do
      rows = parse_ps_rows(output)
      children_by_parent = Enum.group_by(rows, &elem(&1, 1), &elem(&1, 0))
      discovered = collect_ps_tree([root_pid], MapSet.new(), children_by_parent)
      {:ok, retained |> MapSet.union(discovered) |> MapSet.to_list()}
    else
      _ -> {:error, MapSet.to_list(retained)}
    end
  end

  defp collect_ps_tree([], seen, _children_by_parent), do: seen

  defp collect_ps_tree([pid | rest], seen, children_by_parent) do
    cond do
      MapSet.member?(seen, pid) or MapSet.size(seen) >= @max_targets ->
        collect_ps_tree(rest, seen, children_by_parent)

      true ->
        collect_ps_tree(
          rest ++ Map.get(children_by_parent, pid, []),
          MapSet.put(seen, pid),
          children_by_parent
        )
    end
  end

  defp parse_ps_rows(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn row ->
      case String.split(row, ~r/\s+/, trim: true) do
        [pid, parent_pid, state | _rest] ->
          with [parsed_pid] <- parse_pid(pid),
               [parsed_parent_pid] <- parse_pid(parent_pid) do
            [{parsed_pid, parsed_parent_pid, state}]
          else
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  defp emergency_signal(_signal, [], _deadline), do: :ok

  defp emergency_signal(signal, targets, deadline) do
    case {emergency_path("kill"), deadline - monotonic_ms()} do
      {_kill, remaining} when remaining <= 0 ->
        :timeout

      {nil, _remaining} ->
        :timeout

      {kill, _remaining} ->
        args = ["-#{signal}" | Enum.map(targets, &Integer.to_string/1)]
        _ = emergency_command(kill, args, deadline)
        :ok
    end
  end

  defp force_helpers_until_gone([], _kill, _deadline), do: :ok
  defp force_helpers_until_gone(_targets, nil, _deadline), do: :timeout

  defp force_helpers_until_gone(targets, kill, deadline) do
    _ = emergency_command(kill, ["-KILL" | Enum.map(targets, &Integer.to_string/1)], deadline)
    wait_for_helpers(targets, deadline)
  end

  defp wait_for_helpers(targets, deadline) do
    survivors = Enum.filter(targets, &emergency_alive?(&1, deadline))

    cond do
      survivors == [] ->
        :ok

      monotonic_ms() >= deadline ->
        :timeout

      true ->
        remaining = deadline - monotonic_ms()
        receive after: (min(10, remaining) -> wait_for_helpers(survivors, deadline))
    end
  end

  defp emergency_alive?(pid, deadline) do
    case proc_process_state(pid) do
      state when state in [:gone, :quiescent] ->
        false

      state when state in [:running, :stopped] ->
        true

      :unsupported ->
        case emergency_path("kill") do
          nil ->
            true

          kill ->
            match?(
              {:ok, _output, 0},
              emergency_command(kill, ["-0", Integer.to_string(pid)], deadline)
            )
        end
    end
  end

  # Emergency helper teardown intentionally ignores configurable helper paths:
  # a configured helper is exactly what may be hung. Absolute system commands
  # get their own Port monitors and never extend the configured deadline.
  defp emergency_command(executable, args, deadline) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, args}
      ])

    monitor = :erlang.monitor(:port, port)
    command_deadline = min(deadline, monotonic_ms() + @emergency_helper_timeout_ms)
    await_emergency_command(port, monitor, command_deadline, <<>>)
  rescue
    _ -> {:error, :timeout}
  catch
    _, _ -> {:error, :timeout}
  end

  defp await_emergency_command(port, monitor, deadline, output) do
    remaining = deadline - monotonic_ms()

    if remaining <= 0 do
      close_emergency_helper(port, monitor, deadline)
      {:error, :timeout}
    else
      receive do
        {^port, {:exit_status, status}} ->
          close_port(port)
          await_helper_down_until(port, monitor, deadline)
          {:ok, output, status}

        {:DOWN, ^monitor, :port, ^port, _reason} ->
          {:error, :timeout}

        {^port, {:data, data}} ->
          retained =
            binary_part(output <> data, 0, min(byte_size(output <> data), @max_output_bytes))

          await_emergency_command(port, monitor, deadline, retained)
      after
        remaining ->
          close_emergency_helper(port, monitor, deadline)
          {:error, :timeout}
      end
    end
  end

  defp close_emergency_helper(port, monitor, deadline) do
    close_port(port)
    await_helper_down_until(port, monitor, deadline)
  end

  defp emergency_path(name) do
    Enum.find(@fallback_paths[name], &File.exists?/1)
  end

  defp await_helper_down_until(port, monitor, deadline) do
    remaining = max(deadline - monotonic_ms(), 0)

    receive do
      {:DOWN, ^monitor, :port, ^port, _reason} -> :ok
    after
      remaining ->
        Process.demonitor(monitor, [:flush])
        :timeout
    end
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 1 -> pid
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp close_port(port) when is_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp close_port(_port), do: :ok

  defp executable(name, opts) do
    case Map.get(opts.helper_paths, name) do
      path when is_binary(path) -> path
      _ -> System.find_executable(name) || Enum.find(@fallback_paths[name] || [], &File.exists?/1)
    end
  end

  defp parse_pid(value) do
    case Integer.parse(value) do
      {pid, ""} when pid > 1 -> [pid]
      _ -> []
    end
  end

  defp parse_pids(output) do
    output
    |> String.split(~r/\s+/, trim: true)
    |> Enum.flat_map(&parse_pid/1)
  end

  defp linux?, do: match?({:unix, :linux}, :os.type())

  defp clean_opts(opts) do
    %{
      cleanup_timeout_ms: positive_opt(opts, :cleanup_timeout_ms, @default_cleanup_timeout_ms),
      helper_timeout_ms: positive_opt(opts, :helper_timeout_ms, @default_helper_timeout_ms),
      helper_paths: Keyword.get(opts, :helper_paths, %{}),
      identity_reader: Keyword.get(opts, :identity_reader)
    }
  end

  defp unwrap_cleanup({:cleanup_timeout, %Cleanup{} = cleanup}), do: cleanup
  defp unwrap_cleanup(%Cleanup{} = cleanup), do: cleanup

  defp positive_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp safe_notify(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp safe_notify(_), do: :ok
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
