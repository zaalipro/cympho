defmodule Cympho.Adapters.HealthCheckerTest do
  use Cympho.DataCase, async: false

  alias Cympho.Agents
  alias Cympho.Adapters.HealthChecker
  alias Cympho.Companies
  alias Cympho.Repo
  alias Cympho.Secrets

  setup do
    case start_supervised({HealthChecker, [interval: 60_000]}) do
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
      pid = Process.whereis(HealthChecker)

      # Trigger the periodic tick directly instead of waiting for the timer;
      # :sys.get_state blocks until the :check_all message has been handled.
      send(pid, :check_all)
      :sys.get_state(pid)

      assert Process.alive?(pid)
    end
  end

  test "deleted agent keeps map state and get_health_status still works" do
    {:ok, company} =
      Companies.create_company(%{
        name: "Health Delete Corp",
        slug: "health-delete-#{System.unique_integer([:positive])}"
      })

    {:ok, kept} =
      Agents.create_agent(%{
        name: "Kept Agent",
        role: :engineer,
        status: :idle,
        company_id: company.id
      })

    {:ok, deleted} =
      Agents.create_agent(%{
        name: "Deleted Agent",
        role: :engineer,
        status: :idle,
        company_id: company.id
      })

    pid = Process.whereis(HealthChecker)
    send(pid, :check_all)
    state = :sys.get_state(pid)
    assert is_map(state)

    {:ok, _} = Agents.delete_agent(deleted)

    assert :ok = HealthChecker.check_agent_now(deleted.id)
    state = :sys.get_state(pid)
    assert is_map(state)
    refute Map.has_key?(state.consecutive_failures, deleted.id)
    refute Map.has_key?(state.last_health_status, deleted.id)
    assert {:ok, _status} = HealthChecker.get_health_status(kept.id)
    assert Process.alive?(pid)
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

  describe "adapter failure normalisation" do
    setup do
      {:ok, company} =
        Companies.create_company(%{
          name: "Health Unhealthy Corp",
          slug: "health-unhealthy-#{System.unique_integer([:positive])}"
        })

      # The http adapter rejects a disallowed host before making any network
      # call, so this reports :unhealthy deterministically and offline. Every
      # adapter in the tree uses :unhealthy for failures.
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Unhealthy HTTP Agent",
          role: :engineer,
          adapter: :http,
          status: :idle,
          company_id: company.id,
          config: %{"url" => "http://127.0.0.1:1/"}
        })

      %{agent: agent}
    end

    test "an adapter reporting :unhealthy is recorded as a failure", %{agent: agent} do
      agent_id = agent.id
      pid = Process.whereis(HealthChecker)

      try do
        HealthChecker.subscribe()

        assert :ok = HealthChecker.check_agent_now(agent_id)
        :sys.get_state(pid)

        assert {:ok, :unavailable} = HealthChecker.get_health_status(agent_id)

        assert_receive {:health_status_changed,
                        %{agent_id: ^agent_id, old_status: :healthy, new_status: :unavailable}},
                       1_000
      after
        HealthChecker.unsubscribe()
      end
    end

    test "consecutive :unhealthy checks trip the agent to :error", %{agent: agent} do
      pid = Process.whereis(HealthChecker)

      for _ <- 1..3 do
        assert :ok = HealthChecker.check_agent_now(agent.id)
        :sys.get_state(pid)
      end

      reloaded = Repo.reload!(agent)
      assert reloaded.status == :error
      assert reloaded.health_status == :unavailable
    end

    test "recovery from :unhealthy returns the agent to :idle", %{agent: agent} do
      pid = Process.whereis(HealthChecker)

      for _ <- 1..3 do
        assert :ok = HealthChecker.check_agent_now(agent.id)
        :sys.get_state(pid)
      end

      assert Repo.reload!(agent).status == :error

      {:ok, agent} =
        Agents.update_agent(Repo.reload!(agent), %{
          adapter: :process,
          config: %{"command" => "echo"}
        })

      assert :ok = HealthChecker.check_agent_now(agent.id)
      :sys.get_state(pid)

      reloaded = Repo.reload!(agent)
      assert reloaded.status == :idle
      assert reloaded.health_status == :healthy
    end
  end

  test "manual checks retain health status and use secret-backed runtime config" do
    {:ok, company} =
      Companies.create_company(%{
        name: "Health Secret Corp",
        slug: "health-secret-#{System.unique_integer([:positive])}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Secret Backed CEO",
        role: :ceo,
        adapter: :openai_chat,
        status: :idle,
        company_id: company.id,
        config: %{
          "endpoint" => "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
          "model" => "qwen3.7-plus"
        }
      })

    try do
      HealthChecker.subscribe()
      assert :ok = HealthChecker.check_agent_now(agent.id)

      assert_receive {:health_status_changed,
                      %{agent_id: agent_id, old_status: :healthy, new_status: :degraded}},
                     1_000

      assert agent_id == agent.id
      assert {:ok, :degraded} = HealthChecker.get_health_status(agent.id)
      assert Repo.reload!(agent).health_status == :degraded

      {:ok, _secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "DASHSCOPE_API_KEY",
          value: "test-secret-key",
          description: "OpenAI-compatible health check credential"
        })

      assert :ok = HealthChecker.check_agent_now(agent.id)

      assert_receive {:health_status_changed,
                      %{agent_id: agent_id, old_status: :degraded, new_status: :healthy}},
                     1_000

      assert agent_id == agent.id
      assert {:ok, :healthy} = HealthChecker.get_health_status(agent.id)
      assert Repo.reload!(agent).health_status == :healthy

      refute inspect(HealthChecker.get_all_health_statuses()) =~ "test-secret-key"
    after
      HealthChecker.unsubscribe()
    end
  end
end
