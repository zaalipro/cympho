defmodule Cympho.HeartbeatEngine.WatchdogTest do
  # async: false so we can grant the global watchdog process access to our
  # sandbox connection without contention with other tests.
  use Cympho.DataCase, async: false

  alias Cympho.HeartbeatEngine.Watchdog

  setup do
    pid =
      case start_supervised(Cympho.HeartbeatEngine.Watchdog) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, self(), pid)
    :ok
  end

  describe "start_link/1" do
    test "starts the watchdog process" do
      assert Process.whereis(Cympho.HeartbeatEngine.Watchdog)
    end
  end

  describe "last_results/0" do
    test "returns initial empty results" do
      results = Watchdog.last_results()
      assert is_map(results)
    end
  end

  describe "check_now/0" do
    test "triggers a check without error" do
      assert :ok = Watchdog.check_now()
      Process.sleep(50)
    end
  end
end
