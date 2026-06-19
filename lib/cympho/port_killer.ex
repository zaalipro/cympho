defmodule Cympho.PortKiller do
  @moduledoc """
  Best-effort shutdown for OS processes owned by Erlang ports.

  `Port.close/1` is enough for cooperative commands, but local AI harnesses can
  hang, ignore closed stdio, or leave a CLI process behind. Capture the OS pid
  before closing the port and send explicit signals as a final cleanup pass.
  """

  require Logger

  @default_grace_ms 100

  @spec close(port(), keyword()) :: :ok
  def close(port, opts \\ [])

  def close(port, opts) when is_port(port) do
    os_pid = os_pid(port)

    close_port(port)
    kill_os_process(os_pid, opts)
  end

  def close(_port, _opts), do: :ok

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
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

  defp kill_os_process(nil, _opts), do: :ok

  defp kill_os_process(pid, opts) do
    grace_ms = Keyword.get(opts, :grace_ms, @default_grace_ms)

    signal(pid, "TERM")

    if grace_ms > 0 do
      Process.sleep(grace_ms)
    end

    if alive?(pid) do
      signal(pid, "KILL")
    end

    :ok
  end

  defp signal(pid, signal) do
    with executable when is_binary(executable) <- System.find_executable("kill") do
      # Try the process group first for harnesses that start their own session;
      # fall back to the process pid for ordinary Port.open children.
      _ = run_kill(executable, signal, "-#{pid}")
      _ = run_kill(executable, signal, "#{pid}")
      :ok
    else
      _ -> :ok
    end
  end

  defp run_kill(executable, signal, target) do
    System.cmd(executable, ["-#{signal}", target], stderr_to_stdout: true)
  rescue
    exception ->
      Logger.debug("PortKiller failed to send #{signal} to #{target}: #{inspect(exception)}")
      {"", 1}
  end

  defp alive?(pid) do
    with executable when is_binary(executable) <- System.find_executable("kill"),
         {_output, 0} <- System.cmd(executable, ["-0", "#{pid}"], stderr_to_stdout: true) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end
end
