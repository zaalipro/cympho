defmodule Cympho.Adapters.HealthCheckerTest do
  use Cympho.DataCase, async: false

  import Mock

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

  describe "unavailable adapters" do
    test "report the missing prerequisite instead of checking a substitute adapter" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Health Unavailable Corp",
          slug: "health-unavailable-#{System.unique_integer([:positive])}"
        })

      # OpenClaw has no endpoint, so it is unavailable. The default Claude Code
      # adapter must not be health-checked on its behalf.
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Gateway Agent Without Endpoint",
          role: :engineer,
          adapter: :openclaw,
          status: :idle,
          company_id: company.id,
          config: %{}
        })

      pid = Process.whereis(HealthChecker)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = HealthChecker.check_agent_now(agent.id)
          :sys.get_state(pid)
        end)

      assert log =~ "Adapter unavailable: endpoint is required"
      assert {:ok, :unavailable} = HealthChecker.get_health_status(agent.id)
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

  test "scheduled checks log Agrenting failures without the resolved API key" do
    {:ok, company} =
      Companies.create_company(%{
        name: "Health Agrenting Corp",
        slug: "health-agrenting-#{System.unique_integer([:positive])}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Agrenting Health Agent",
        role: :engineer,
        adapter: :agrenting,
        status: :idle,
        company_id: company.id,
        config: %{
          "agent_did" => "did:agrenting:example",
          "capability" => "code",
          "max_price" => "10"
        }
      })

    api_key = "agrenting-sentinel-key-0123"

    {:ok, _secret} =
      Secrets.create_secret(%{
        company_id: company.id,
        scope: "company",
        key: "AGRENTING_API_KEY",
        value: api_key,
        description: "Agrenting health check credential"
      })

    pid = Process.whereis(HealthChecker)

    with_mock Cympho.Agrenting.Client, [:passthrough],
      list_agents: fn config, _params ->
        {:error, {:http_error, 401, "invalid key #{config["api_key"]}"}}
      end do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = HealthChecker.check_agent_now(agent.id)
          :sys.get_state(pid)
        end)

      assert log =~ "Agrenting check failed"
      assert log =~ "[REDACTED]"
      refute log =~ api_key
    end
  end

  test "scheduled checks log HTTP transport failures without the sent header value" do
    {:ok, company} =
      Companies.create_company(%{
        name: "Health HTTP Corp",
        slug: "health-http-#{System.unique_integer([:positive])}"
      })

    header_value = "http-header-sentinel-0123\n"

    {:ok, agent} =
      Agents.create_agent(%{
        name: "HTTP Health Agent",
        role: :engineer,
        adapter: :http,
        status: :idle,
        company_id: company.id,
        config: %{"url" => "https://example.com", "headers" => %{"x-api-key" => header_value}}
      })

    error = invalid_header_error("x-api-key", header_value)
    pid = Process.whereis(HealthChecker)

    with_mock Finch, [:passthrough],
      stream_while: fn _request, _name, acc, _fun, _opts -> {:error, error, acc} end do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = HealthChecker.check_agent_now(agent.id)
          :sys.get_state(pid)
        end)

      assert log =~ "Request failed"
      assert log =~ "[REDACTED]"
      refute log =~ "http-header-sentinel"
    end
  end

  # A real Mint error for a header value with a newline. It carries the value.
  defp invalid_header_error(name, value) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listen)

    {:error, error, _acc} =
      Finch.build(:get, "http://127.0.0.1:#{port}/", [{name, value}])
      |> Finch.stream_while(Cympho.Finch, nil, fn _event, acc -> {:cont, acc} end)

    :gen_tcp.close(listen)
    assert inspect(error) =~ value |> String.trim() |> String.slice(0, 10)
    error
  end
end
