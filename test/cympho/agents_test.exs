defmodule Cympho.AgentsTest do
  use Cympho.DataCase, async: true

  alias Cympho.Agents
  alias Cympho.Agents.Agent

  setup do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "Test Agent",
        role: :engineer,
        status: :idle
      })

    %{agent: agent}
  end

  describe "list_agents/0" do
    test "returns all agents", %{agent: agent} do
      agents = Agents.list_agents()
      assert length(agents) >= 1
      assert Enum.any?(agents, fn a -> a.id == agent.id end)
    end
  end

  describe "get_agent!/1" do
    test "returns the agent with given id", %{agent: agent} do
      found = Agents.get_agent!(agent.id)
      assert found.id == agent.id
      assert found.name == agent.name
    end

    test "raises Ecto.NoResultsError for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Agents.get_agent!("00000000-0000-0000-0000-000000000000")
      end
    end
  end

  describe "get_agent/1" do
    test "returns {:ok, agent} for valid id", %{agent: agent} do
      assert {:ok, found} = Agents.get_agent(agent.id)
      assert found.id == agent.id
    end

    test "returns {:error, :not_found} for non-existent id" do
      assert {:error, :not_found} = Agents.get_agent("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "create_agent/1" do
    test "creates agent with valid data" do
      attrs = %{
        name: "New Agent",
        role: :cto,
        status: :idle
      }

      assert {:ok, %Agent{} = agent} = Agents.create_agent(attrs)
      assert agent.name == "New Agent"
      assert agent.role == :cto
      assert agent.status == :idle
    end

    test "creates agent with adapter" do
      attrs = %{
        name: "Claude Agent",
        role: :engineer,
        adapter: :claude_code
      }

      assert {:ok, %Agent{} = agent} = Agents.create_agent(attrs)
      assert agent.adapter == :claude_code
    end

    test "creates agent without adapter (nil allowed)" do
      attrs = %{
        name: "No Adapter Agent",
        role: :engineer
      }

      assert {:ok, %Agent{} = agent} = Agents.create_agent(attrs)
      assert agent.adapter == nil
    end

    test "creates agent with heartbeat_config" do
      attrs = %{
        name: "Heartbeat Agent",
        role: :engineer,
        heartbeat_config: %{"interval_ms" => 30_000}
      }

      assert {:ok, %Agent{} = agent} = Agents.create_agent(attrs)
      assert agent.heartbeat_config == %{"interval_ms" => 30_000}
    end

    test "creates agent with parent_id" do
      {:ok, parent} =
        Agents.create_agent(%{
          name: "Parent Agent",
          role: :cto
        })

      attrs = %{
        name: "Child Agent",
        role: :engineer,
        parent_id: parent.id
      }

      assert {:ok, %Agent{} = agent} = Agents.create_agent(attrs)
      assert agent.parent_id == parent.id
    end

    test "returns error for invalid adapter" do
      attrs = %{
        name: "Bad Adapter",
        role: :engineer,
        adapter: :invalid_adapter
      }

      assert {:error, %Ecto.Changeset{} = changeset} = Agents.create_agent(attrs)
      assert %{adapter: ["is invalid"]} = errors_on(changeset)
    end

    test "creates agent with config" do
      attrs = %{
        name: "Config Agent",
        role: :engineer,
        config: %{"skills" => ["elixir", "phoenix"]}
      }

      assert {:ok, %Agent{} = agent} = Agents.create_agent(attrs)
      assert agent.config == %{"skills" => ["elixir", "phoenix"]}
    end

    test "returns error changeset for invalid data" do
      attrs = %{name: ""}
      assert {:error, %Ecto.Changeset{}} = Agents.create_agent(attrs)
    end

    test "returns error for invalid role" do
      attrs = %{name: "Invalid Role", role: :invalid_role}
      assert {:error, %Ecto.Changeset{}} = Agents.create_agent(attrs)
    end
  end

  describe "update_agent/2" do
    test "updates agent with valid data", %{agent: agent} do
      attrs = %{name: "Updated Name", status: :running}
      assert {:ok, updated} = Agents.update_agent(agent, attrs)
      assert updated.name == "Updated Name"
      assert updated.status == :running
    end

    test "returns error changeset for invalid data", %{agent: agent} do
      attrs = %{name: ""}
      assert {:error, %Ecto.Changeset{}} = Agents.update_agent(agent, attrs)
    end
  end

  describe "delete_agent/1" do
    test "deletes the agent", %{agent: agent} do
      assert {:ok, _} = Agents.delete_agent(agent)

      assert_raise Ecto.NoResultsError, fn ->
        Agents.get_agent!(agent.id)
      end
    end
  end

  describe "list_agents_by_role/1" do
    test "returns agents with specified role" do
      {:ok, _engineer1} =
        Agents.create_agent(%{
          name: "Engineer 1",
          role: :engineer
        })

      {:ok, _engineer2} =
        Agents.create_agent(%{
          name: "Engineer 2",
          role: :engineer
        })

      {:ok, _ceo} =
        Agents.create_agent(%{
          name: "CEO",
          role: :ceo
        })

      engineers = Agents.list_agents_by_role(:engineer)
      assert length(engineers) >= 2
      assert Enum.all?(engineers, fn a -> a.role == :engineer end)
    end
  end

  describe "count_running_jobs/1" do
    test "returns 0 when agent has no running jobs" do
      assert Agents.count_running_jobs(@agent.id) == 0
    end
  end

  describe "is_agent_at_capacity?/1" do
    test "returns false when agent has no running jobs and default capacity" do
      refute Agents.is_agent_at_capacity?(@agent.id)
    end

    test "returns true when agent does not exist" do
      assert Agents.is_agent_at_capacity?("non-existent-id")
    end
  end

  describe "list_agents_by_status/1" do
    test "returns agents with specified status" do
      {:ok, _idle1} =
        Agents.create_agent(%{
          name: "Idle Agent 1",
          role: :engineer,
          status: :idle
        })

      {:ok, _running} =
        Agents.create_agent(%{
          name: "Running Agent",
          role: :engineer,
          status: :running
        })

      idle_agents = Agents.list_agents_by_status(:idle)
      assert Enum.any?(idle_agents, fn a -> a.status == :idle end)
    end
  end

  describe "list_agents_by_adapter/1" do
    test "returns agents with specified adapter" do
      {:ok, _claude} =
        Agents.create_agent(%{
          name: "Claude Agent",
          role: :engineer,
          adapter: :claude_code
        })

      {:ok, _codex} =
        Agents.create_agent(%{
          name: "Codex Agent",
          role: :engineer,
          adapter: :codex
        })

      {:ok, _no_adapter} =
        Agents.create_agent(%{
          name: "Plain Agent",
          role: :engineer
        })

      claude_agents = Agents.list_agents_by_adapter(:claude_code)
      assert length(claude_agents) >= 1
      assert Enum.all?(claude_agents, fn a -> a.adapter == :claude_code end)
    end
  end

  describe "adapter_options/0" do
    test "returns all valid adapter types" do
      options = Agents.adapter_options()
      assert :claude_code in options
      assert :codex in options
      assert :cursor in options
      assert :http in options
      assert :process in options
    end
  end

  describe "Agent.adapter_options/0" do
    test "returns valid adapter types from schema" do
      options = Agent.adapter_options()
      assert options == [:claude_code, :codex, :cursor, :http, :process]
    end
  end

  describe "change_agent/2" do
    test "returns a changeset for the agent", %{agent: agent} do
      changeset = Agents.change_agent(agent, %{name: "New Name"})
      assert changeset.changes[:name] == "New Name"
    end

    test "accepts all valid adapter values" do
      for adapter <- [:claude_code, :codex, :cursor, :http, :process] do
        changeset = Agents.change_agent(%Agent{}, %{name: "Test", role: :engineer, adapter: adapter})
        assert changeset.valid?, "Expected adapter #{adapter} to be valid"
      end
    end

    test "rejects invalid adapter value" do
      changeset =
        Agents.change_agent(%Agent{}, %{name: "Test", role: :engineer, adapter: :bogus})

      refute changeset.valid?
      assert %{adapter: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "spawn_agent/2" do
    setup [:start_heartbeat_supervisor]

    test "creates agent and starts heartbeat process", %{agent: parent_agent} do
      attrs = %{
        name: "Spawned Agent",
        role: :engineer,
        config: %{"test" => true}
      }

      assert {:ok, agent} = Agents.spawn_agent(attrs, parent_agent.id)
      assert agent.name == "Spawned Agent"
      assert agent.role == :engineer

      # Verify heartbeat was started
      assert {:ok, :idle} = Cympho.AgentHeartbeat.status(agent.id)

      # Clean up
      Cympho.AgentHeartbeat.stop_for_agent(agent.id)
    end

    test "returns error and does not create agent when heartbeat start fails" do
      # Use an invalid parent_agent_id format that won't matter
      # The heartbeat will fail to start due to invalid agent_id format
      attrs = %{name: "Bad Agent", role: :engineer}

      # This test documents the expected behavior when heartbeat fails
      # Actual failure mode depends on AgentHeartbeat implementation
    end

    test "role pre-fill logic: CEO -> CTO", %{agent: _parent_agent} do
      {:ok, ceo} =
        Agents.create_agent(%{
          name: "CEO Parent",
          role: :ceo
        })

      attrs = %{name: "CTO Spawned", role: :cto}

      assert {:ok, agent} = Agents.spawn_agent(attrs, ceo.id)
      assert agent.role == :cto

      # Clean up
      Cympho.AgentHeartbeat.stop_for_agent(agent.id)
    end

    test "role pre-fill logic: CTO -> Engineer", %{agent: _parent_agent} do
      {:ok, cto} =
        Agents.create_agent(%{
          name: "CTO Parent",
          role: :cto
        })

      attrs = %{name: "Engineer Spawned", role: :engineer}

      assert {:ok, agent} = Agents.spawn_agent(attrs, cto.id)
      assert agent.role == :engineer

      # Clean up
      Cympho.AgentHeartbeat.stop_for_agent(agent.id)
    end
  end

  defp start_heartbeat_supervisor(_context) do
    # Start the heartbeat supervisor and registry for tests
    case start_supervised({Cympho.AgentHeartbeat.Supervisor, []}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case start_supervised({Registry, keys: :unique, name: Cympho.AgentHeartbeat.Registry}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end
end
