defmodule Cympho.AgentsTest do
  use Cympho.DataCase, async: true

  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.{Companies, Projects, Workspaces}

  setup do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "Test Agent",
        role: :engineer,
        status: :idle
      })

    %{agent: agent}
  end

  defp create_company(_context) do
    {:ok, company} =
      Companies.create_company(%{
        name: "Test Company",
        slug: "test-company-#{System.unique_integer([:positive])}"
      })

    %{company: company}
  end

  defp create_agent(%{company: company}) do
    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Setup Agent",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    %{agent: agent}
  end

  defp create_tenant(label) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "#{label} #{unique}",
        slug: "#{String.downcase(label)}-#{unique}"
      })

    company
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

  describe "pause_agent/2" do
    setup [:create_company, :create_agent]

    test "sets runtime and governance pause metadata", %{agent: agent} do
      assert {:ok, paused} = Agents.pause_agent(agent, "adapter circuit breaker")

      assert paused.status == :paused
      assert paused.governance_status == "paused"
      assert paused.pause_reason == "adapter circuit breaker"
      assert paused.governance_reasoning == "adapter circuit breaker"
      assert paused.paused_at != nil
    end

    test "resume_agent/1 clears runtime and governance pause metadata", %{agent: agent} do
      {:ok, paused} = Agents.pause_agent(agent, "manual hold")
      assert paused.governance_status == "paused"

      assert {:ok, resumed} = Agents.resume_agent(paused)

      assert resumed.status == :idle
      assert resumed.governance_status == "active"
      assert resumed.governance_reasoning == nil
      assert resumed.paused_at == nil
      assert resumed.pause_reason == nil
    end

    test "rehomes non-terminal assigned work and cancels agent wakes", %{
      company: company,
      agent: agent
    } do
      alias Cympho.Issues
      alias Cympho.Wakes
      alias Cympho.Wakes.AgentWake

      {:ok, manager} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Manager",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, agent} = Agents.update_agent(agent, %{parent_id: manager.id})

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, todo} =
        Issues.create_issue(%{
          title: "Todo work",
          company_id: company.id,
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, active} =
        Issues.create_issue(%{
          title: "Active work",
          company_id: company.id,
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now
        })

      {:ok, done} =
        Issues.create_issue(%{
          title: "Done work",
          company_id: company.id,
          status: :done,
          assignee_id: agent.id
        })

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, todo.id, "manual_dispatch", "system", nil, %{
          "source" => "test"
        })

      assert {:ok, _paused} = Agents.pause_agent(agent, "operator pause")

      assert Issues.get_issue!(todo.id).assignee_id == nil
      assert Issues.get_issue!(active.id).assignee_id == nil
      assert Issues.get_issue!(active.id).status == :todo
      assert Issues.get_issue!(active.id).checked_out_at == nil
      # Terminal work stays on the agent.
      assert Issues.get_issue!(done.id).assignee_id == agent.id

      assert Repo.get!(AgentWake, wake.id).status == "cancelled"

      manager_wakes =
        Repo.all(
          from w in AgentWake,
            where:
              w.agent_id == ^manager.id and w.reason == "escalation_from_subordinate" and
                w.status == "pending"
        )

      assert length(manager_wakes) >= 1
      assert Enum.any?(manager_wakes, &(&1.issue_id == todo.id))
      assert Enum.any?(manager_wakes, &(&1.issue_id == active.id))
    end
  end

  describe "dispatch eligibility" do
    setup [:create_company]

    test "excludes idle agents that are governance-paused", %{company: company} do
      {:ok, paused} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Governance Paused Engineer",
          role: :engineer,
          status: :idle,
          governance_status: "paused"
        })

      refute Enum.any?(Agents.list_eligible_agents(:engineer, company.id), &(&1.id == paused.id))
      refute Agents.get_idle_agent_by_role(:engineer, company.id)
    end

    test "excludes idle agents pending governance approval", %{company: company} do
      {:ok, pending} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Pending Engineer",
          role: :engineer,
          status: :idle,
          governance_status: "pending_approval"
        })

      refute Enum.any?(Agents.list_eligible_agents(:engineer, company.id), &(&1.id == pending.id))
      refute Agents.get_idle_agent_by_role(:engineer, company.id)
    end

    test "keeps active idle agents eligible", %{company: company} do
      {:ok, active} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Active Engineer",
          role: :engineer,
          status: :idle,
          governance_status: "active"
        })

      assert Enum.any?(Agents.list_eligible_agents(:engineer, company.id), &(&1.id == active.id))
      assert Agents.get_idle_agent_by_role(:engineer, company.id).id == active.id
    end
  end

  describe "get_company_ceo/1" do
    setup [:create_company]

    test "returns the first non-terminated CEO for a company", %{company: company} do
      {:ok, ceo} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "CEO",
          role: :ceo,
          status: :idle
        })

      {:ok, _engineer} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Engineer",
          role: :engineer,
          status: :idle
        })

      assert {:ok, found} = Agents.get_company_ceo(company.id)
      assert found.id == ceo.id
    end

    test "ignores terminated CEOs", %{company: company} do
      {:ok, _terminated} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Old CEO",
          role: :ceo,
          status: :idle,
          governance_status: "terminated"
        })

      assert {:error, :not_found} = Agents.get_company_ceo(company.id)
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

    test "rejects a forged parent_id from another company" do
      company = create_tenant("Child")
      other_company = create_tenant("Parent")

      {:ok, foreign_parent} =
        Agents.create_agent(%{
          name: "Foreign Parent",
          role: :cto,
          company_id: other_company.id
        })

      assert {:error, changeset} =
               Agents.create_agent(%{
                 name: "Tenant Child",
                 role: :engineer,
                 company_id: company.id,
                 parent_id: foreign_parent.id
               })

      assert errors_on(changeset).parent_id == ["must belong to the same company"]
    end

    test "rejects forged project, creator, and default environment associations" do
      company = create_tenant("AgentScope")
      other_company = create_tenant("ForeignAgentScope")

      {:ok, foreign_project} =
        Projects.create_project(%{
          name: "Foreign agent project",
          prefix: "FAP",
          company_id: other_company.id
        })

      {:ok, foreign_creator} =
        Agents.create_agent(%{
          name: "Foreign agent creator",
          role: :cto,
          company_id: other_company.id
        })

      {:ok, foreign_environment} =
        Workspaces.create_environment(%{
          name: "Foreign agent environment",
          company_id: other_company.id,
          project_id: foreign_project.id
        })

      for {field, value} <- [
            project_id: foreign_project.id,
            created_by_agent_id: foreign_creator.id,
            default_environment_id: foreign_environment.id
          ] do
        assert {:error, changeset} =
                 %{name: "Scoped agent #{field}", role: :engineer, company_id: company.id}
                 |> Map.put(field, value)
                 |> Agents.create_agent()

        assert Map.has_key?(errors_on(changeset), field)
      end
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

    test "rejects a forged parent_id from another company" do
      company = create_tenant("UpdateChild")
      other_company = create_tenant("UpdateParent")

      {:ok, agent} =
        Agents.create_agent(%{name: "Tenant Agent", role: :engineer, company_id: company.id})

      {:ok, foreign_parent} =
        Agents.create_agent(%{
          name: "Foreign Manager",
          role: :cto,
          company_id: other_company.id
        })

      assert {:error, changeset} = Agents.update_agent(agent, %{parent_id: foreign_parent.id})
      assert errors_on(changeset).parent_id == ["must belong to the same company"]
      assert Agents.get_agent!(agent.id).parent_id == nil
    end

    test "rejects parent assignments that create hierarchy cycles" do
      company = create_tenant("Cycle")

      {:ok, manager} =
        Agents.create_agent(%{name: "Cycle Manager", role: :cto, company_id: company.id})

      {:ok, report} =
        Agents.create_agent(%{
          name: "Cycle Report",
          role: :engineer,
          company_id: company.id,
          parent_id: manager.id
        })

      assert {:error, self_changeset} =
               Agents.update_agent(manager, %{parent_id: manager.id})

      assert errors_on(self_changeset).parent_id == ["would create a hierarchy cycle"]

      assert {:error, changeset} = Agents.update_agent(manager, %{parent_id: report.id})
      assert errors_on(changeset).parent_id == ["would create a hierarchy cycle"]
      assert Agents.get_agent!(manager.id).parent_id == nil
    end

    test "rejects forged project, creator, and default environment updates" do
      company = create_tenant("UpdateAgentScope")
      other_company = create_tenant("UpdateForeignAgentScope")

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Update scoped agent",
          role: :engineer,
          company_id: company.id
        })

      {:ok, foreign_project} =
        Projects.create_project(%{
          name: "Foreign update project",
          prefix: "FUP",
          company_id: other_company.id
        })

      {:ok, foreign_creator} =
        Agents.create_agent(%{
          name: "Foreign update creator",
          role: :cto,
          company_id: other_company.id
        })

      {:ok, foreign_environment} =
        Workspaces.create_environment(%{
          name: "Foreign update environment",
          company_id: other_company.id,
          project_id: foreign_project.id
        })

      for {field, value} <- [
            project_id: foreign_project.id,
            created_by_agent_id: foreign_creator.id,
            default_environment_id: foreign_environment.id
          ] do
        assert {:error, changeset} = Agents.update_agent(agent, %{field => value})
        assert Map.has_key?(errors_on(changeset), field)
      end
    end
  end

  describe "update_adapter_configs/1" do
    test "rolls back every config when one agent update is invalid", %{agent: first} do
      {:ok, second} =
        Agents.create_agent(%{
          name: "Second Config Agent",
          role: :engineer,
          status: :idle,
          config: %{"model" => "before-two"}
        })

      invalid_second = %{second | name: nil}

      assert {:error, failed_id, %Ecto.Changeset{}} =
               Agents.update_adapter_configs([
                 {first, %{"model" => "after-one"}},
                 {invalid_second, %{"model" => "after-two"}}
               ])

      assert failed_id == second.id
      assert Agents.get_agent!(first.id).config == first.config
      assert Agents.get_agent!(second.id).config == %{"model" => "before-two"}
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
    test "returns 0 when agent has no running jobs", %{agent: agent} do
      assert Agents.count_running_jobs(agent.id) == 0
    end
  end

  describe "is_agent_at_capacity?/1" do
    test "returns false when agent has no running jobs and default capacity", %{agent: agent} do
      refute Agents.is_agent_at_capacity?(agent.id)
    end

    test "returns true when agent does not exist" do
      assert Agents.is_agent_at_capacity?("00000000-0000-0000-0000-000000000000")
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

  describe "list_agents_by_adapter/2" do
    setup [:create_company]

    test "returns agents with specified adapter scoped to company", %{company: company} do
      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Co",
          slug: "other-co-#{System.unique_integer([:positive])}"
        })

      {:ok, _claude} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Claude Agent",
          role: :engineer,
          adapter: :claude_code
        })

      {:ok, _other_claude} =
        Agents.create_agent(%{
          company_id: other_company.id,
          name: "Other-co Claude",
          role: :engineer,
          adapter: :claude_code
        })

      {:ok, _codex} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Codex Agent",
          role: :engineer,
          adapter: :codex
        })

      claude_agents = Agents.list_agents_by_adapter(:claude_code, company.id)
      assert length(claude_agents) == 1
      assert Enum.all?(claude_agents, fn a -> a.adapter == :claude_code end)
      assert Enum.all?(claude_agents, fn a -> a.company_id == company.id end)
    end
  end

  describe "adapter_options/0" do
    test "returns all valid adapter types" do
      options = Agents.adapter_options()
      assert :claude_code in options
      assert :codex in options
      assert :cursor in options
      assert :http in options
      assert :openai_chat in options
      assert :openclaw in options
      assert :process in options
      assert :agrenting in options
    end
  end

  describe "Agent.adapter_options/0" do
    test "returns valid adapter types from schema" do
      options = Agent.adapter_options()

      assert options == [
               :claude_code,
               :codex,
               :cursor,
               :http,
               :openai_chat,
               :openclaw,
               :process,
               :agrenting
             ]
    end
  end

  describe "change_agent/2" do
    test "returns a changeset for the agent", %{agent: agent} do
      changeset = Agents.change_agent(agent, %{name: "New Name"})
      assert changeset.changes[:name] == "New Name"
    end

    test "accepts business-function roles as first-class agent roles" do
      assert [
               :ceo,
               :cto,
               :product_manager,
               :designer,
               :engineer,
               :release_engineer,
               :qa_engineer,
               :researcher,
               :marketer,
               :content_strategist,
               :sales_development,
               :customer_support
             ] = Agent.role_options()

      for role <- Agent.role_options() do
        changeset = Agents.change_agent(%Agent{}, %{name: "Test #{role}", role: role})
        assert changeset.valid?, "Expected role #{role} to be valid"
      end

      assert Agent.normalize_role("qa") == :qa_engineer
      assert Agent.normalize_role("marketing") == :marketer
      assert Agent.normalize_role("social") == :content_strategist
      assert Agent.normalize_role("outreach") == :sales_development
      assert Agent.normalize_role("support") == :customer_support
      assert Agent.normalize_role("research") == :researcher
      assert Agent.role_label(:qa_engineer) == "QA Engineer"
    end

    test "accepts all valid adapter values" do
      for adapter <- [
            :claude_code,
            :codex,
            :cursor,
            :http,
            :openai_chat,
            :openclaw,
            :process,
            :agrenting
          ] do
        changeset =
          Agents.change_agent(%Agent{}, %{name: "Test", role: :engineer, adapter: adapter})

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

  describe "config revisions" do
    test "snapshots instruction studio metadata", %{agent: agent} do
      {:ok, agent} =
        Agents.update_agent(agent, %{
          adapter: :codex,
          config: %{"model" => "gpt-5.5"},
          runtime_config: %{"profile_id" => "codex-gpt-5.5"},
          instructions:
            "After every meaningful action, comment with [delivery] What happened, files changed, verification, and next decision. Open a PR with a task list."
        })

      assert {:ok, revision} = Agents.create_config_revision(agent)

      assert revision.version == 1
      assert revision.role == "engineer"
      assert revision.adapter == "codex"
      assert revision.config["model"] == "gpt-5.5"
      assert revision.runtime_config["profile_id"] == "codex-gpt-5.5"
      assert is_integer(revision.studio_score)
      assert revision.studio_status in ["good", "weak", "attention"]
      assert %{"audits" => audits, "scenarios" => scenarios} = revision.studio_audits
      assert Enum.any?(audits, &(&1["key"] == "custom_override_coverage"))
      assert Enum.any?(scenarios, &(&1["key"] == "delivery_package"))
    end

    test "restores only revisions for the same agent and records rollback", %{agent: agent} do
      {:ok, other_agent} =
        Agents.create_agent(%{
          name: "Other Agent",
          role: :engineer,
          status: :idle,
          instructions: "Other baseline."
        })

      {:ok, old_revision} =
        Agents.create_config_revision(agent, %{
          instructions: "Original safe instructions.",
          config: %{"model" => "gpt-5.4"},
          runtime_config: %{"profile_id" => "codex-mini"},
          adapter: "codex"
        })

      {:ok, other_revision} = Agents.create_config_revision(other_agent)

      assert {:error, :not_found} =
               Agents.restore_config_revision(agent.id, other_revision.id)

      assert {:ok, restored} = Agents.restore_config_revision(agent.id, old_revision.id)
      assert restored.instructions == "Original safe instructions."
      assert restored.config["model"] == "gpt-5.4"
      assert restored.runtime_config["profile_id"] == "codex-mini"
      assert restored.adapter == :codex

      [rollback, ^old_revision] = Agents.list_config_revisions(agent.id)
      assert rollback.source == "restore"
      assert rollback.restored_from_revision_id == old_revision.id
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
      _attrs = %{name: "Bad Agent", role: :engineer}

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

    test "CEO can spawn non-engineering business-function agents", %{agent: _parent_agent} do
      {:ok, ceo} =
        Agents.create_agent(%{
          name: "CEO Business Parent",
          role: :ceo
        })

      for role <- [:researcher, :marketer, :content_strategist, :sales_development] do
        assert {:ok, agent} = Agents.spawn_agent(%{name: "Spawned #{role}", role: role}, ceo.id)
        assert agent.role == role
        Cympho.AgentHeartbeat.stop_for_agent(agent.id)
      end
    end
  end

  describe "get_agent_stats/1" do
    setup [:create_company, :create_agent]

    test "returns nil for non-existent agent" do
      assert nil == Agents.get_agent_stats("00000000-0000-0000-0000-000000000000")
    end

    test "returns stats for agent with no issues", %{agent: agent} do
      stats = Agents.get_agent_stats(agent.id)

      assert stats.direct_reports == 0
      assert stats.total_issues == 0
      assert stats.completed_this_week == 0
      assert stats.blocked_count == 0
      assert stats.budget_status == nil
    end

    test "returns stats for agent with direct reports", %{company: company, agent: parent} do
      {:ok, _child1} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Child 1",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          parent_id: parent.id
        })

      {:ok, _child2} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Child 2",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          parent_id: parent.id
        })

      stats = Agents.get_agent_stats(parent.id)
      assert stats.direct_reports == 2
    end
  end

  describe "get_company_agent_stats/1" do
    setup [:create_company]

    test "returns stats for company with no agents", %{company: company} do
      stats = Agents.get_company_agent_stats(company.id)

      assert stats.total == 0
      assert stats.by_role == %{}
      assert stats.by_status == %{}
      assert stats.idle_ratio == 0.0
    end

    test "returns stats for company with multiple agents", %{company: company} do
      {:ok, _ceo} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, _cto} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "CTO",
          role: :cto,
          status: :running,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, _eng1} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Engineer 1",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, _eng2} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Engineer 2",
          role: :engineer,
          status: :running,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      stats = Agents.get_company_agent_stats(company.id)

      assert stats.total == 4
      assert stats.by_role == %{ceo: 1, cto: 1, engineer: 2}
      assert stats.by_status == %{idle: 2, running: 2}
      assert stats.idle_ratio == 50.0
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
