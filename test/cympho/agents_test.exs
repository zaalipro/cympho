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

  describe "change_agent/2" do
    test "returns a changeset for the agent", %{agent: agent} do
      changeset = Agents.change_agent(agent, %{name: "New Name"})
      assert changeset.changes[:name] == "New Name"
    end
  end
end