defmodule Cympho.Orchestrator.Dispatcher.RouterTest do
  use Cympho.DataCase, async: true

  alias Cympho.Orchestrator.Dispatcher.Router
  alias Cympho.Agents
  alias Cympho.Agents.Agent

  describe "infer_role/1" do
    test "returns :ceo for strategic keywords in title" do
      issue = %{title: "Strategic roadmap planning", description: "Look at market trends"}
      assert Router.infer_role(issue) == :ceo
    end

    test "returns :ceo for funding keywords" do
      issue = %{title: "Funding round", description: "Series B investment"}
      assert Router.infer_role(issue) == :ceo
    end

    test "returns :cto for technical keywords" do
      issue = %{title: "Architecture review", description: "System design patterns"}
      assert Router.infer_role(issue) == :cto
    end

    test "returns :cto for infrastructure keywords" do
      issue = %{title: "Infrastructure setup", description: "Deploy to AWS"}
      assert Router.infer_role(issue) == :cto
    end

    test "returns :engineer for implementation keywords" do
      issue = %{title: "Build user authentication", description: "Implement login flow"}
      assert Router.infer_role(issue) == :engineer
    end

    test "returns :engineer for bug fix keywords" do
      issue = %{title: "Fix memory leak", description: "Debug and fix"}
      assert Router.infer_role(issue) == :engineer
    end

    test "returns :engineer when no keywords match" do
      issue = %{title: "Do something", description: "Something else"}
      assert Router.infer_role(issue) == :engineer
    end

    test "returns :engineer when description is nil" do
      issue = %{title: "Implement feature", description: nil}
      assert Router.infer_role(issue) == :engineer
    end

    test "case insensitive matching" do
      issue = %{title: "STRATEGIC VISION", description: "CEOs"}
      assert Router.infer_role(issue) == :ceo
    end
  end

  describe "fallback_chain/1" do
    test ":ceo returns empty list" do
      assert Router.fallback_chain(:ceo) == []
    end

    test ":cto returns [:ceo]" do
      assert Router.fallback_chain(:cto) == [:ceo]
    end

    test ":engineer returns [:cto, :ceo]" do
      assert Router.fallback_chain(:engineer) == [:cto, :ceo]
    end
  end

  describe "select_agent/2" do
    setup do
      {:ok, ceo} =
        Agents.create_agent(%{
          name: "CEO Agent",
          role: :ceo,
          status: :idle,
          max_concurrent_jobs: 3
        })

      {:ok, cto} =
        Agents.create_agent(%{
          name: "CTO Agent",
          role: :cto,
          status: :idle,
          max_concurrent_jobs: 3
        })

      {:ok, engineer1} =
        Agents.create_agent(%{
          name: "Engineer A",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 3
        })

      {:ok, engineer2} =
        Agents.create_agent(%{
          name: "Engineer B",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 3
        })

      {:ok, error_agent} =
        Agents.create_agent(%{
          name: "Error Agent",
          role: :engineer,
          status: :error,
          max_concurrent_jobs: 3
        })

      %{
        ceo: ceo,
        cto: cto,
        engineer1: engineer1,
        engineer2: engineer2,
        error_agent: error_agent
      }
    end

    test "returns agent when one matches role", %{engineer1: agent} do
      assert Router.select_agent(:engineer, [agent]) == {:ok, agent}
    end

    test "filters out error status agents", %{engineer1: _, error_agent: error_agent} do
      assert Router.select_agent(:engineer, [error_agent]) == {:error, :no_agent_available}
    end

    test "returns error when no agents match" do
      assert Router.select_agent(:engineer, []) == {:error, :no_agent_available}
    end

    test "selects least-loaded agent by load count", %{
      engineer1: engineer1,
      engineer2: engineer2
    } do
      # Both agents are idle with 0 assignments, should pick by name alphabetically
      agents = [engineer2, engineer1]
      assert {:ok, selected} = Router.select_agent(:engineer, agents)
      assert selected.name == "Engineer A"
    end
  end

  describe "routing integration" do
    setup do
      {:ok, ceo} =
        Agents.create_agent(%{
          name: "CEO",
          role: :cto,
          status: :idle,
          max_concurrent_jobs: 3
        })

      {:ok, cto} =
        Agents.create_agent(%{
          name: "CTO",
          role: :cto,
          status: :idle,
          max_concurrent_jobs: 3
        })

      {:ok, engineer} =
        Agents.create_agent(%{
          name: "Engineer",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 3
        })

      %{cto: cto, engineer: engineer}
    end

    test "strategic issue routes to ceo role (first fallback)" do
      issue = %{title: "Strategic planning", description: "Roadmap for Q4"}
      role = Router.infer_role(issue)
      assert role == :ceo
    end

    test "technical issue routes to cto role" do
      issue = %{title: "System architecture", description: "Refactor the backend"}
      role = Router.infer_role(issue)
      assert role == :cto
    end

    test "implementation issue routes to engineer role" do
      issue = %{title: "Build login feature", description: "Implement OAuth"}
      role = Router.infer_role(issue)
      assert role == :engineer
    end
  end
end