defmodule Cympho.HeartbeatEngine.WatchdogTest do
  # async: false so we can grant the global watchdog process access to our
  # sandbox connection without contention with other tests.
  use Cympho.DataCase, async: false

  alias Cympho.Agents
  alias Cympho.HeartbeatEngine
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.HeartbeatEngine.Watchdog
  alias Cympho.Issues

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

    test "cancels never-started orphaned runs instead of failing them" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Watchdog Orphan Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Watchdog orphan run",
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, run} =
        HeartbeatEngine.create_run(%{
          agent_id: agent.id,
          issue_id: issue.id,
          adapter: "process"
        })

      assert :ok = Watchdog.check_now()
      Process.sleep(100)

      reloaded = Repo.get!(Run, run.id)
      assert reloaded.status == "cancelled"
      assert is_nil(reloaded.error_reason)
    end
  end

  describe "unexpected messages" do
    test "catch-all handle_info and handle_cast keep the watchdog alive" do
      pid = Process.whereis(Cympho.HeartbeatEngine.Watchdog)
      assert is_pid(pid)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(pid, :random_garbage_msg)
          GenServer.cast(pid, :random_garbage_cast)
          Process.sleep(50)
        end)

      assert Process.alive?(pid)
      assert log =~ "unexpected message"
      assert log =~ "unexpected cast"
      assert log =~ "random_garbage_msg"
      assert log =~ "random_garbage_cast"
    end
  end
end
