defmodule Cympho.PortKiller do
  @moduledoc """
  Best-effort shutdown for OS processes owned by Erlang ports.

  `Port.close/1` is enough for cooperative commands, but local AI harnesses can
  hang, ignore closed stdio, or leave a CLI process behind. Capture the OS pid
  before closing the port and send explicit signals as a final cleanup pass.

  Signals are only ever sent to *specific* process IDs — the port child and its
  descendants — never to a process **group** (a negative `kill` target). The
  emulator runs port children in the BEAM's own process group unless they are
  isolated, so a group signal can reach the BEAM itself and take down the whole
  node. This bit us in production: a 5-minute agent stall fired
  `kill -TERM -<pid>` and SIGTERM'd the entire release every time an agent run
  outlasted the stall timeout. We reap the subtree by walking parent → child
  links instead, which is both safe and more thorough.
  """

  require Logger

  @default_grace_ms 100

  @spec close(port(), keyword()) :: :ok
  def close(port, opts \\ [])

  def close(port, opts) when is_port(port) do
    os_pid = os_pid(port)

    # Snapshot the subtree *before* closing the port. Closing it can end the
    # parent, and once that happens its children reparent to init and can no
    # longer be discovered from it — which is the very thing kill_tree/2
    # documents that it must avoid.
    targets = if os_pid, do: process_tree(os_pid), else: []

    close_port(port)
    kill_targets(targets, opts)
  end

  def close(_port, _opts), do: :ok

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 1 -> pid
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp kill_targets([], _opts), do: :ok

  defp kill_targets(targets, opts) do
    grace_ms = Keyword.get(opts, :grace_ms, @default_grace_ms)

    Enum.each(targets, &signal(&1, "TERM"))

    if grace_ms > 0 do
      Process.sleep(grace_ms)
    end

    targets
    |> Enum.filter(&alive?/1)
    |> Enum.each(&signal(&1, "KILL"))

    :ok
  end

  # `pid` plus every descendant, discovered via `pgrep -P`. Returns positive
  # PIDs only; the MapSet guard keeps the walk cycle-safe.
  defp process_tree(pid) do
    pid |> collect(MapSet.new()) |> MapSet.to_list()
  end

  defp collect(pid, seen) do
    if MapSet.member?(seen, pid) do
      seen
    else
      Enum.reduce(child_pids(pid), MapSet.put(seen, pid), &collect/2)
    end
  end

  defp child_pids(pid) do
    with executable when is_binary(executable) <- executable("pgrep"),
         {out, 0} <-
           System.cmd(executable, ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
      out
      |> String.split(~r/\s+/, trim: true)
      |> Enum.flat_map(&parse_pid/1)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  # Reaping a runaway agent process is a safety mechanism, so it must not depend
  # on PATH. Releases, cron contexts, and sandboxed runs can all start with a
  # PATH that omits these, and a silent no-op here leaves a CLI burning CPU and
  # provider spend with nothing tracking it.
  @fallback_paths %{
    "kill" => ["/bin/kill", "/usr/bin/kill"],
    "pgrep" => ["/usr/bin/pgrep", "/bin/pgrep"]
  }

  defp executable(name) do
    case System.find_executable(name) do
      path when is_binary(path) -> path
      _ -> @fallback_paths |> Map.get(name, []) |> Enum.find(&File.exists?/1)
    end
  end

  defp parse_pid(str) do
    case Integer.parse(str) do
      {n, _rest} when n > 1 -> [n]
      _ -> []
    end
  end

  # Positive PID only — never a negative (process-group) target, which could
  # reach the BEAM's own group and kill the node.
  defp signal(pid, signal) when is_integer(pid) and pid > 1 do
    with executable when is_binary(executable) <- executable("kill") do
      _ = run_kill(executable, signal, Integer.to_string(pid))
      :ok
    else
      _ -> :ok
    end
  end

  defp signal(_pid, _signal), do: :ok

  defp run_kill(executable, signal, target) do
    System.cmd(executable, ["-#{signal}", target], stderr_to_stdout: true)
  rescue
    exception ->
      Logger.debug("PortKiller failed to send #{signal} to #{target}: #{inspect(exception)}")
      {"", 1}
  end

  defp alive?(pid) do
    with executable when is_binary(executable) <- executable("kill"),
         {_output, 0} <-
           System.cmd(executable, ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end
end
