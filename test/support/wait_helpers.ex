defmodule Cympho.WaitHelpers do
  @moduledoc """
  Polling helper for tests that need to wait on asynchronous side effects
  (GenServer casts, PubSub fan-out, background tasks) without relying on a
  fixed `Process.sleep`.
  """

  @doc """
  Repeatedly invokes `fun` until it stops raising, returning its result.

  `fun` should contain assertions (or raise on failure, e.g. a bad match).
  Retries every `interval` ms until `timeout` ms have elapsed, then
  re-raises the last error.

      wait_until(fn -> assert Repo.get!(Agent, id).status == :idle end)
  """
  def wait_until(fun, timeout \\ 2_000, interval \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout
    attempt(fun, deadline, interval)
  end

  defp attempt(fun, deadline, interval) do
    fun.()
  rescue
    error ->
      if System.monotonic_time(:millisecond) >= deadline do
        reraise error, __STACKTRACE__
      else
        Process.sleep(interval)
        attempt(fun, deadline, interval)
      end
  end
end
