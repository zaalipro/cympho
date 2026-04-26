defmodule Cympho.AgentAdapters.HealthCheckerTest do
  use ExUnit.Case, async: false

  alias Cympho.AgentAdapters.HealthChecker

  setup do
    # Start PubSub if not already started
    case Process.whereis(Cympho.PubSub) do
      nil ->
        {:ok, _} = start_supervised({Phoenix.PubSub, name: Cympho.PubSub})

      _ ->
        :ok
    end

    # Start HealthChecker
    case start_supervised({HealthChecker, [interval: 100]}) do
      {:ok, pid} ->
        %{health_checker_pid: pid}

      {:error, {:already_started, pid}} ->
        %{health_checker_pid: pid}
    end
  end

  describe "start_link/1" do
    test "starts the HealthChecker GenServer", %{health_checker_pid: pid} do
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "get_health_status/1" do
    test "returns :healthy for agents that haven't been checked yet", %{health_checker_pid: _pid} do
      agent_id = "agent-#{:rand.uniform(10_000)}"

      assert {:ok, :healthy} = HealthChecker.get_health_status(agent_id)
    end
  end

  describe "get_all_health_statuses/0" do
    test "returns a map of health statuses", %{health_checker_pid: _pid} do
      statuses = HealthChecker.get_all_health_statuses()
      assert is_map(statuses)
    end
  end

  describe "check_agent_now/1" do
    test "does not crash when agent does not exist" do
      # This should not crash
      assert :ok = HealthChecker.check_agent_now("nonexistent-agent-id")
    end
  end

  describe "subscribe/0 and unsubscribe/0" do
    test "subscribe and unsubscribe work correctly" do
      assert :ok = HealthChecker.subscribe()
      assert :ok = HealthChecker.unsubscribe()
    end

    test "multiple subscriptions are handled correctly" do
      assert :ok = HealthChecker.subscribe()
      assert :ok = HealthChecker.subscribe()  # Subscribe again
      assert :ok = HealthChecker.unsubscribe()
    end
  end

  describe "PubSub broadcasts" do
    test "PubSub topic is accessible" do
      # Subscribe to the agents topic
      Phoenix.PubSub.subscribe(Cympho.PubSub, "agents")
      :ok = Phoenix.PubSub.unsubscribe(Cympho.PubSub, "agents")
    end
  end

  describe "health check polling" do
    test "health checker does not crash on periodic checks" do
      # Wait for a few health check cycles
      Process.sleep(300)

      # Health checker should still be alive
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
  end
end
