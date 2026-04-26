defmodule Cympho.Skills.ResolverTest do
  use Cympho.DataCase
  alias Cympho.Skills.{Resolver, Plugin, AgentSkill}
  alias Cympho.{Agents, Companies, Repo}

  describe "resolve/2" do
    setup do
      start_supervised!(Resolver)

      {:ok, company} = Companies.create_company(%{name: "Test", slug: "test-#{System.unique_integer()}"})
      {:ok, agent} = Agents.create_agent(%{name: "Test Agent", role: :engineer, company_id: company.id})

      %{company: company, agent: agent}
    end

    test "returns error for agent with no skills", %{agent: agent, company: company} do
      assert {:error, :no_skills} = Resolver.resolve(agent.id, company.id)
    end

    test "returns error for invalid ID type" do
      assert {:error, :invalid_id} = Resolver.resolve(123, "some-id")
      assert {:error, :invalid_id} = Resolver.resolve(nil, "some-id")
    end

    test "returns single skill with no dependencies", %{company: company, agent: agent} do
      {:ok, plugin} = Repo.insert(%Plugin{
        identifier: "base-skill",
        version: "1.0.0",
        name: "Base Skill",
        author: "test",
        manifest: %{
          "name" => "base-skill",
          "version" => "1.0.0",
          "author" => "test",
          "entrypoint" => "Cympho.Skills.Loader"
        },
        company_id: company.id,
        enabled: true
      })

      Repo.insert(%AgentSkill{agent_id: agent.id, plugin_id: plugin.id})

      assert {:ok, [resolved_plugin]} = Resolver.resolve(agent.id, company.id)
      assert resolved_plugin.id == plugin.id
    end

    test "resolves skills in dependency order", %{company: company, agent: agent} do
      {:ok, base_plugin} = Repo.insert(%Plugin{
        identifier: "base-skill",
        version: "1.0.0",
        name: "Base Skill",
        author: "test",
        manifest: %{
          "name" => "base-skill",
          "version" => "1.0.0",
          "author" => "test",
          "entrypoint" => "Cympho.Skills.Loader",
          "dependencies" => %{}
        },
        company_id: company.id,
        enabled: true
      })

      {:ok, derived_plugin} = Repo.insert(%Plugin{
        identifier: "derived-skill",
        version: "1.0.0",
        name: "Derived Skill",
        author: "test",
        manifest: %{
          "name" => "derived-skill",
          "version" => "1.0.0",
          "author" => "test",
          "entrypoint" => "Cympho.Skills.Loader",
          "dependencies" => %{"base-skill" => "^1.0.0"}
        },
        company_id: company.id,
        enabled: true
      })

      Repo.insert(%AgentSkill{agent_id: agent.id, plugin_id: base_plugin.id})
      Repo.insert(%AgentSkill{agent_id: agent.id, plugin_id: derived_plugin.id})

      assert {:ok, [base, derived]} = Resolver.resolve(agent.id, company.id)
      assert base.identifier == "base-skill"
      assert derived.identifier == "derived-skill"
    end

    test "detects circular dependencies", %{company: company, agent: agent} do
      {:ok, plugin_a} = Repo.insert(%Plugin{
        identifier: "skill-a",
        version: "1.0.0",
        name: "Skill A",
        author: "test",
        manifest: %{
          "name" => "skill-a",
          "version" => "1.0.0",
          "author" => "test",
          "entrypoint" => "Cympho.Skills.Loader",
          "dependencies" => %{"skill-b" => "^1.0.0"}
        },
        company_id: company.id,
        enabled: true
      })

      {:ok, plugin_b} = Repo.insert(%Plugin{
        identifier: "skill-b",
        version: "1.0.0",
        name: "Skill B",
        author: "test",
        manifest: %{
          "name" => "skill-b",
          "version" => "1.0.0",
          "author" => "test",
          "entrypoint" => "Cympho.Skills.Loader",
          "dependencies" => %{"skill-a" => "^1.0.0"}
        },
        company_id: company.id,
        enabled: true
      })

      Repo.insert(%AgentSkill{agent_id: agent.id, plugin_id: plugin_a.id})
      Repo.insert(%AgentSkill{agent_id: agent.id, plugin_id: plugin_b.id})

      assert {:error, :circular_dependency, _path} = Resolver.resolve(agent.id, company.id)
    end

    test "caches resolved skills", %{company: company, agent: agent} do
      {:ok, plugin} = Repo.insert(%Plugin{
        identifier: "base-skill",
        version: "1.0.0",
        name: "Base Skill",
        author: "test",
        manifest: %{
          "name" => "base-skill",
          "version" => "1.0.0",
          "author" => "test",
          "entrypoint" => "Cympho.Skills.Loader"
        },
        company_id: company.id,
        enabled: true
      })

      Repo.insert(%AgentSkill{agent_id: agent.id, plugin_id: plugin.id})

      # First call resolves
      assert {:ok, [_]} = Resolver.resolve(agent.id, company.id)

      # Second call uses cache
      assert {:ok, [_]} = Resolver.resolve(agent.id, company.id)
    end
  end

  describe "invalidate/1" do
    setup do
      start_supervised!(Resolver)
      {:ok, company} = Companies.create_company(%{name: "Test", slug: "test-#{System.unique_integer()}"})
      {:ok, agent} = Agents.create_agent(%{name: "Test Agent", role: :engineer, company_id: company.id})

      {:ok, plugin} = Repo.insert(%Plugin{
        identifier: "base-skill",
        version: "1.0.0",
        name: "Base Skill",
        author: "test",
        manifest: %{
          "name" => "base-skill",
          "version" => "1.0.0",
          "author" => "test",
          "entrypoint" => "Cympho.Skills.Loader"
        },
        company_id: company.id,
        enabled: true
      })

      Repo.insert(%AgentSkill{agent_id: agent.id, plugin_id: plugin.id})

      # Warm the cache
      {:ok, _} = Resolver.resolve(agent.id, company.id)

      %{agent: agent, company: company, plugin: plugin}
    end

    test "invalidates cached resolution", %{agent: agent, company: company} do
      assert :ok = Resolver.invalidate(agent.id)

      # Cache is cleared, but re-resolution should still work
      assert {:ok, [_]} = Resolver.resolve(agent.id, company.id)
    end

    test "returns error for invalid ID type" do
      assert {:error, :invalid_id} = Resolver.invalidate(123)
      assert {:error, :invalid_id} = Resolver.invalidate(nil)
    end
  end

  describe "clear_cache/0" do
    setup do
      start_supervised!(Resolver)
      {:ok, company} = Companies.create_company(%{name: "Test", slug: "test-#{System.unique_integer()}"})
      {:ok, agent} = Agents.create_agent(%{name: "Test Agent", role: :engineer, company_id: company.id})

      {:ok, plugin} = Repo.insert(%Plugin{
        identifier: "base-skill",
        version: "1.0.0",
        name: "Base Skill",
        author: "test",
        manifest: %{
          "name" => "base-skill",
          "version" => "1.0.0",
          "author" => "test",
          "entrypoint" => "Cympho.Skills.Loader"
        },
        company_id: company.id,
        enabled: true
      })

      Repo.insert(%AgentSkill{agent_id: agent.id, plugin_id: plugin.id})

      # Warm the cache
      {:ok, _} = Resolver.resolve(agent.id, company.id)

      :ok
    end

    test "clears all cached resolutions" do
      assert :ok = Resolver.clear_cache()
      assert :ok = Resolver.clear_cache()
    end
  end

  describe "semver compatibility" do
    setup do
      start_supervised!(Resolver)
      {:ok, company} = Companies.create_company(%{name: "Test", slug: "test-#{System.unique_integer()}"})
      {:ok, agent} = Agents.create_agent(%{name: "Test Agent", role: :engineer, company_id: company.id})

      %{company: company, agent: agent}
    end

    test "resolves exact version match", %{company: company, agent: agent} do
      {:ok, dep} = Repo.insert(%Plugin{
        identifier: "dep",
        version: "1.0.0",
        name: "Dep",
        author: "test",
        manifest: %{
          "name" => "dep",
          "version" => "1.0.0",
          "author" => "test",
          "entrypoint" => "Cympho.Skills.Loader"
        },
        company_id: company.id,
        enabled: true
      })

      {:ok, plugin} = Repo.insert(%Plugin{
        identifier: "plugin",
        version: "1.0.0",
        name: "Plugin",
        author: "test",
        manifest: %{
          "name" => "plugin",
          "version" => "1.0.0",
          "author" => "test",
          "entrypoint" => "Cympho.Skills.Loader",
          "dependencies" => %{"dep" => "1.0.0"}
        },
        company_id: company.id,
        enabled: true
      })

      Repo.insert(%AgentSkill{agent_id: agent.id, plugin_id: plugin.id})
      Repo.insert(%AgentSkill{agent_id: agent.id, plugin_id: dep.id})

      assert {:ok, [^dep, ^plugin]} = Resolver.resolve(agent.id, company.id)
    end

    test "resolves caret version requirement", %{company: company, agent: agent} do
      {:ok, dep} = Repo.insert(%Plugin{
        identifier: "dep",
        version: "1.2.3",
        name: "Dep",
        author: "test",
        manifest: %{
          "name" => "dep",
          "version" => "1.2.3",
          "author" => "test",
          "entrypoint" => "Cympho.Skills.Loader"
        },
        company_id: company.id,
        enabled: true
      })

      {:ok, plugin} = Repo.insert(%Plugin{
        identifier: "plugin",
        version: "1.0.0",
        name: "Plugin",
        author: "test",
        manifest: %{
          "name" => "plugin",
          "version" => "1.0.0",
          "author" => "test",
          "entrypoint" => "Cympho.Skills.Loader",
          "dependencies" => %{"dep" => "^1.0.0"}
        },
        company_id: company.id,
        enabled: true
      })

      Repo.insert(%AgentSkill{agent_id: agent.id, plugin_id: plugin.id})
      Repo.insert(%AgentSkill{agent_id: agent.id, plugin_id: dep.id})

      assert {:ok, [^dep, ^plugin]} = Resolver.resolve(agent.id, company.id)
    end

    test "resolves tilde version requirement", %{company: company, agent: agent} do
      {:ok, dep} = Repo.insert(%Plugin{
        identifier: "dep",
        version: "1.2.5",
        name: "Dep",
        author: "test",
        manifest: %{
          "name" => "dep",
          "version" => "1.2.5",
          "author" => "test",
          "entrypoint" => "Cympho.Skills.Loader"
        },
        company_id: company.id,
        enabled: true
      })

      {:ok, plugin} = Repo.insert(%Plugin{
        identifier: "plugin",
        version: "1.0.0",
        name: "Plugin",
        author: "test",
        manifest: %{
          "name" => "plugin",
          "version" => "1.0.0",
          "author" => "test",
          "entrypoint" => "Cympho.Skills.Loader",
          "dependencies" => %{"dep" => "~1.2.3"}
        },
        company_id: company.id,
        enabled: true
      })

      Repo.insert(%AgentSkill{agent_id: agent.id, plugin_id: plugin.id})
      Repo.insert(%AgentSkill{agent_id: agent.id, plugin_id: dep.id})

      assert {:ok, [^dep, ^plugin]} = Resolver.resolve(agent.id, company.id)
    end
  end

  describe "multi-tenant isolation (resolve/2)" do
    setup do
      start_supervised!(Resolver)

      {:ok, company_a} = Companies.create_company(%{name: "Company A", slug: "company-a-#{System.unique_integer()}"})
      {:ok, company_b} = Companies.create_company(%{name: "Company B", slug: "company-b-#{System.unique_integer()}"})

      {:ok, agent_a} = Agents.create_agent(%{name: "Agent A", role: :engineer, company_id: company_a.id})
      {:ok, agent_b} = Agents.create_agent(%{name: "Agent B", role: :engineer, company_id: company_b.id})

      %{company_a: company_a, company_b: company_b, agent_a: agent_a, agent_b: agent_b}
    end

    test "returns error when agent does not belong to provided company", %{agent_a: agent_a, company_b: company_b} do
      assert {:error, :no_skills} = Resolver.resolve(agent_a.id, company_b.id)
    end

    test "excludes plugins from other companies", %{company_a: company_a, company_b: company_b, agent_a: agent_a} do
      {:ok, plugin_a} = Repo.insert(%Plugin{
        identifier: "skill-a",
        version: "1.0.0",
        name: "Skill A",
        author: "test",
        manifest: %{"name" => "skill-a", "version" => "1.0.0", "author" => "test"},
        company_id: company_a.id,
        enabled: true
      })

      {:ok, _plugin_b} = Repo.insert(%Plugin{
        identifier: "skill-a",
        version: "1.0.0",
        name: "Skill A (B)",
        author: "test",
        manifest: %{"name" => "skill-a", "version" => "1.0.0", "author" => "test"},
        company_id: company_b.id,
        enabled: true
      })

      Repo.insert(%AgentSkill{agent_id: agent_a.id, plugin_id: plugin_a.id})

      assert {:ok, [resolved]} = Resolver.resolve(agent_a.id, company_a.id)
      assert resolved.id == plugin_a.id
      assert resolved.company_id == company_a.id
    end

    test "returns no_skills when agent has only cross-company skill assignments", %{company_a: company_a, company_b: company_b, agent_a: agent_a} do
      {:ok, plugin_b} = Repo.insert(%Plugin{
        identifier: "skill-b",
        version: "1.0.0",
        name: "Skill B",
        author: "test",
        manifest: %{"name" => "skill-b", "version" => "1.0.0", "author" => "test"},
        company_id: company_b.id,
        enabled: true
      })

      Repo.insert(%AgentSkill{agent_id: agent_a.id, plugin_id: plugin_b.id})

      assert {:error, :no_skills} = Resolver.resolve(agent_a.id, company_a.id)
    end

    test "returns error for invalid company_id", %{agent_a: agent_a} do
      assert {:error, :invalid_id} = Resolver.resolve(agent_a.id, 123)
    end
  end
end
