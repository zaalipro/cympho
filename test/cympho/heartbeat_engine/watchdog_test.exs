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

  describe "stranded wake recovery" do
    test "re-triggers heartbeats for agents with old pending wakes" do
      case start_supervised({Registry, keys: :unique, name: Cympho.AgentHeartbeat.Registry}) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Stranded Wake Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Stranded wake issue",
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, wake} =
        Cympho.HeartbeatEngine.WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: "issue_commented"
        })

      # Age the wake past the stale threshold — the enqueue broadcast went
      # nowhere because no heartbeat process exists.
      old_time =
        DateTime.utc_now()
        |> DateTime.add(-60 * 60, :second)
        |> DateTime.truncate(:second)

      wake
      |> Ecto.Changeset.change(%{inserted_at: old_time})
      |> Repo.update!()

      # Register self() as the agent's heartbeat process so the watchdog's
      # re-trigger lands here.
      {:ok, _} = Registry.register(Cympho.AgentHeartbeat.Registry, agent.id, nil)

      assert :ok = Watchdog.check_now()

      assert_receive :heartbeat, 2_000
    end

    test "skips paused agents when sweeping stranded wakes" do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Paused Stranded Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Paused stranded issue",
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, wake} =
        Cympho.HeartbeatEngine.WakeupQueue.enqueue(%{
          agent_id: agent.id,
          issue_id: issue.id,
          reason: "issue_commented"
        })

      old_time =
        DateTime.utc_now()
        |> DateTime.add(-60 * 60, :second)
        |> DateTime.truncate(:second)

      wake
      |> Ecto.Changeset.change(%{inserted_at: old_time})
      |> Repo.update!()

      {:ok, _paused} = Agents.pause_agent(agent.id, "operator pause")

      assert Cympho.HeartbeatEngine.WakeupQueue.agent_ids_with_stale_pending(15) == []
    end
  end

  describe "crash resilience" do
    test "a check that raises does not kill the watchdog" do
      pid = Process.whereis(Cympho.HeartbeatEngine.Watchdog)
      assert is_pid(pid)

      # Revoke the watchdog's sandbox access so its DB queries raise, then
      # trigger a check — the rescue in do_check must keep it alive.
      Ecto.Adapters.SQL.Sandbox.mode(Cympho.Repo, :manual)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Watchdog.check_now()
          # Sync through the GenServer to ensure the cast was processed.
          _ = :sys.get_state(pid)
        end)

      Ecto.Adapters.SQL.Sandbox.mode(Cympho.Repo, {:shared, self()})

      assert Process.alive?(pid)
      assert log =~ "check failed"
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
