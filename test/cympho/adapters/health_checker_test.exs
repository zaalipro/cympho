defmodule Cympho.Adapters.HealthCheckerTest do
  use Cympho.DataCase, async: false

  alias Cympho.Adapters.HealthChecker

  setup do
    case start_supervised({HealthChecker, [interval: 100]}) do
      {:ok, pid} ->
        Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, self(), pid)
        %{health_checker_pid: pid}

      {:error, {:already_started, pid}} ->
        Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, self(), pid)
        %{health_checker_pid: pid}
    end
  end

  describe "start_link/1" do
    test "starts the HealthChecker GenServer", %{health_checker_pid: pid} do
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "is registered under the module name" do
      assert HealthChecker == HealthChecker
      assert Process.whereis(HealthChecker) |> is_pid()
    end
  end

  describe "get_health_status/1" do
    test "returns :healthy for agents that haven't been checked yet" do
      agent_id = "agent-#{:rand.uniform(10_000)}"
      assert {:ok, :healthy} = HealthChecker.get_health_status(agent_id)
    end

    test "returns :not_found when the HealthChecker is not running" do
      :ok = stop_supervised(HealthChecker)
      assert {:error, :not_found} = HealthChecker.get_health_status("any")
    end
  end

  describe "get_all_health_statuses/0" do
    test "returns a map of health statuses" do
      statuses = HealthChecker.get_all_health_statuses()
      assert is_map(statuses)
    end

    test "returns empty map when the HealthChecker is not running" do
      :ok = stop_supervised(HealthChecker)
      assert %{} = HealthChecker.get_all_health_statuses()
    end
  end

  describe "check_agent_now/1" do
    test "does not crash when agent does not exist" do
      assert :ok = HealthChecker.check_agent_now("nonexistent-agent-id")
    end

    test "returns :ok when the HealthChecker is not running" do
      :ok = stop_supervised(HealthChecker)
      assert :ok = HealthChecker.check_agent_now("any")
    end
  end

  describe "subscribe/0 and unsubscribe/0" do
    test "subscribe and unsubscribe work correctly" do
      assert :ok = HealthChecker.subscribe()
      assert :ok = HealthChecker.unsubscribe()
    end

    test "multiple subscriptions are handled correctly" do
      assert :ok = HealthChecker.subscribe()
      assert :ok = HealthChecker.subscribe()
      assert :ok = HealthChecker.unsubscribe()
    end
  end

  describe "PubSub broadcasts" do
    test "PubSub topic is accessible" do
      Phoenix.PubSub.subscribe(Cympho.PubSub, "agents")
      :ok = Phoenix.PubSub.unsubscribe(Cympho.PubSub, "agents")
    end
  end

  describe "health check polling" do
    test "health checker does not crash on periodic checks" do
      Process.sleep(300)
      assert Process.alive?(Process.whereis(HealthChecker))
    end
  end

  describe "check_all_now/0" do
    test "does not crash when called" do
      assert :ok = HealthChecker.check_all_now()
    end

    test "handles multiple calls gracefully" do
      assert :ok = HealthChecker.check_all_now()
      assert :ok = HealthChecker.check_all_now()
      assert :ok = HealthChecker.check_all_now()
    end

    test "returns :ok when the HealthChecker is not running" do
      :ok = stop_supervised(HealthChecker)
      assert :ok = HealthChecker.check_all_now()
    end
  end
end
