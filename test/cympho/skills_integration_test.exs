defmodule Cympho.SkillsIntegrationTest do
  use Cympho.DataCase
  alias Cympho.{Skills, Skills.AgentSkill, Skills.Plugin}
  alias Cympho.Repo

  describe "available_for_agent/1" do
    test "returns empty list when agent has no skills" do
      agent = insert_agent()

      assert Skills.available_for_agent(agent.id) == []
    end

    test "returns list of skill maps when agent has skills" do
      agent = insert_agent()

      # Create a test plugin/skill
      plugin =
        %Plugin{}
        |> Plugin.changeset(%{
          identifier: "test_skill",
          name: "Test Skill",
          version: "1.0.0",
          capabilities: ["file_io", "web_search"],
          description: "A test skill",
          entrypoint: "test.sh",
          enabled: true,
          company_id: agent.company_id,
          status: "active",
          manifest: %{"name" => "Test Skill", "version" => "1.0.0"}
        })
        |> Repo.insert!()

      # Assign skill to agent
      %AgentSkill{}
      |> AgentSkill.changeset(%{
        agent_id: agent.id,
        plugin_id: plugin.id
      })
      |> Repo.insert!()

      skills = Skills.available_for_agent(agent.id)

      assert length(skills) == 1
      skill = List.first(skills)

      assert skill.identifier == "test_skill"
      assert skill.name == "Test Skill"
      assert skill.version == "1.0.0"
      assert skill.capabilities == ["file_io", "web_search"]
      assert skill.description == "A test skill"
    end

    test "returns only enabled skills" do
      agent = insert_agent()

      # Create enabled plugin
      enabled_plugin =
        %Plugin{}
        |> Plugin.changeset(%{
          identifier: "enabled_skill",
          name: "Enabled Skill",
          version: "1.0.0",
          capabilities: ["file_io"],
          enabled: true,
          company_id: agent.company_id,
          status: "active",
          manifest: %{"name" => "Enabled Skill", "version" => "1.0.0"}
        })
        |> Repo.insert!()

      # Create disabled plugin
      disabled_plugin =
        %Plugin{}
        |> Plugin.changeset(%{
          identifier: "disabled_skill",
          name: "Disabled Skill",
          version: "1.0.0",
          capabilities: ["web_search"],
          enabled: false,
          company_id: agent.company_id,
          status: "disabled",
          manifest: %{"name" => "Disabled Skill", "version" => "1.0.0"}
        })
        |> Repo.insert!()

      # Assign both to agent
      %AgentSkill{}
      |> AgentSkill.changeset(%{
        agent_id: agent.id,
        plugin_id: enabled_plugin.id
      })
      |> Repo.insert!()

      %AgentSkill{}
      |> AgentSkill.changeset(%{
        agent_id: agent.id,
        plugin_id: disabled_plugin.id
      })
      |> Repo.insert!()

      skills = Skills.available_for_agent(agent.id)

      assert length(skills) == 1
      assert List.first(skills).identifier == "enabled_skill"
    end

    test "gracefully degrades on error" do
      # This test verifies that errors during skill loading are caught
      # and an empty list is returned instead of crashing

      # Use a non-existent agent ID - this will fail the DB query
      # but should be caught by the try/rescue
      skills = Skills.available_for_agent("non-existent-agent-id")

      assert skills == []
    end
  end

  defp insert_agent do
    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Test Company #{System.unique_integer()}",
        slug: "test-company-#{System.unique_integer()}"
      })

    {:ok, agent} =
      Cympho.Agents.create_agent(%{
        name: "Test Agent #{System.unique_integer()}",
        role: :engineer,
        company_id: company.id
      })

    agent
  end
end
