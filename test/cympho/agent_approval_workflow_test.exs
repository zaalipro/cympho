defmodule Cympho.AgentApprovalWorkflowTest do
  use Cympho.DataCase, async: false

  alias Cympho.{Agents, BoardApprovals, Companies, GovernanceAuditLogs}
  alias Cympho.Agents.Agent
  alias Cympho.BoardApprovals.BoardApproval
  alias Cympho.Users.User

  # --- Helpers ---

  defp create_company(governance_config \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Test Company #{unique}",
        slug: "test-company-#{unique}",
        governance_config: governance_config
      })

    company
  end

  defp create_user(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    %User{}
    |> User.registration_changeset(
      Map.merge(
        %{
          email: "agent-approval-#{unique}@example.com",
          name: "Approval Test #{unique}",
          password: "password123"
        },
        attrs
      )
    )
    |> Cympho.Repo.insert!()
  end

  defp create_board_member(company) do
    user = create_user()

    {:ok, _} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: "member",
        is_board_member: true
      })

    user
  end

  defp create_agent_in_company(company, attrs \\ %{}) do
    merged = Map.merge(%{name: "Test Agent", role: :engineer, company_id: company.id}, attrs)

    case Agents.create_agent(merged) do
      {:ok, agent} ->
        agent

      {:error, :pending_board_approval, _} ->
        %Agent{}
        |> Agent.changeset(merged)
        |> Cympho.Repo.insert!()
    end
  end

  defp start_heartbeat_supervisor(_context) do
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

  defp start_executor(_context) do
    case start_supervised(Cympho.BoardApprovals.BoardApprovalActionExecutor) do
      {:ok, pid} ->
        # Allow the executor GenServer to access the test's sandbox connection
        Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
        :ok

      {:error, {:already_started, pid}} ->
        # Allow the already-started executor to access the test's sandbox connection
        Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
        :ok
    end
  end

  # --- Agent Hire Gate ---

  describe "create_agent/1 with governance" do
    test "creates agent directly when governance does not require agent_hire approval" do
      company = create_company(%{"required_approvals" => []})

      attrs = %{name: "Direct Agent", role: :engineer, company_id: company.id}
      assert {:ok, %Agent{}} = Agents.create_agent(attrs)
    end

    test "creates agent directly when no governance config set" do
      company = create_company()

      attrs = %{name: "Direct Agent", role: :engineer, company_id: company.id}
      assert {:ok, %Agent{}} = Agents.create_agent(attrs)
    end

    test "returns pending board approval when agent_hire governance required" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})

      attrs = %{name: "Governed Agent", role: :engineer, company_id: company.id}

      assert {:error, :pending_board_approval, approval_id} = Agents.create_agent(attrs)
      assert is_binary(approval_id)

      # Verify the board approval was created
      {:ok, approval} = BoardApprovals.get_board_approval(approval_id)
      assert approval.category == "agent_hire"
      assert approval.status == "pending"
      assert approval.company_id == company.id
    end

    test "stores original attrs in proposal_data for later execution" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})

      attrs = %{
        name: "Stored Agent",
        role: :cto,
        company_id: company.id,
        config: %{"key" => "val"}
      }

      assert {:error, :pending_board_approval, approval_id} = Agents.create_agent(attrs)

      {:ok, approval} = BoardApprovals.get_board_approval(approval_id)
      assert approval.proposal_data["attrs"]["name"] == "Stored Agent"
      assert approval.proposal_data["attrs"]["role"] == "cto"
      assert approval.proposal_data["attrs"]["company_id"] == company.id
    end

    test "does not create agent when approval is pending" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})

      attrs = %{name: "Blocked Agent", role: :engineer, company_id: company.id}

      assert {:error, :pending_board_approval, _} = Agents.create_agent(attrs)

      agents = Agents.list_agents_by_company(company.id)
      assert Enum.empty?(agents)
    end

    test "skips governance when no company_id in attrs" do
      attrs = %{name: "No Company Agent", role: :engineer}
      assert {:ok, %Agent{}} = Agents.create_agent(attrs)
    end
  end

  describe "spawn_agent/2 with governance" do
    setup [:start_heartbeat_supervisor]

    test "spawns agent directly when governance not required" do
      company = create_company(%{"required_approvals" => []})
      parent = create_agent_in_company(company, %{role: :cto})

      attrs = %{name: "Spawned Agent", role: :engineer, company_id: company.id}

      assert {:ok, %Agent{} = agent} = Agents.spawn_agent(attrs, parent.id)
      assert agent.name == "Spawned Agent"

      Cympho.AgentHeartbeat.stop_for_agent(agent.id)
    end

    test "returns pending board approval when agent_hire governance required" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      parent = create_agent_in_company(company, %{role: :cto})

      attrs = %{name: "Governed Spawn", role: :engineer, company_id: company.id}

      assert {:error, :pending_board_approval, approval_id} = Agents.spawn_agent(attrs, parent.id)

      {:ok, approval} = BoardApprovals.get_board_approval(approval_id)
      assert approval.category == "agent_hire"
      assert approval.requested_by_agent_id == parent.id
      assert approval.proposal_data["parent_agent_id"] == parent.id
    end

    test "does not spawn agent when approval is pending" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      parent = create_agent_in_company(company, %{role: :cto})

      attrs = %{name: "Blocked Spawn", role: :engineer, company_id: company.id}

      assert {:error, :pending_board_approval, _} = Agents.spawn_agent(attrs, parent.id)

      agents = Agents.list_agents_by_company(company.id)
      # Only parent should exist
      assert length(agents) == 1
    end
  end

  # --- Role Change Gate ---

  describe "update_agent/2 with role change governance" do
    test "updates agent directly when role is not changing" do
      company = create_company(%{"required_approvals" => ["agent_promotion"]})
      agent = create_agent_in_company(company, %{role: :engineer})

      assert {:ok, updated} = Agents.update_agent(agent, %{name: "Renamed Agent"})
      assert updated.name == "Renamed Agent"
      assert updated.role == :engineer
    end

    test "updates agent directly when agent_promotion governance not required" do
      company = create_company(%{"required_approvals" => []})
      agent = create_agent_in_company(company, %{role: :engineer})

      assert {:ok, updated} = Agents.update_agent(agent, %{role: :cto})
      assert updated.role == :cto
    end

    test "returns pending board approval when agent_promotion governance required" do
      company = create_company(%{"required_approvals" => ["agent_promotion"]})
      agent = create_agent_in_company(company, %{role: :engineer})

      assert {:error, :pending_board_approval, approval_id} =
               Agents.update_agent(agent, %{role: :cto})

      {:ok, approval} = BoardApprovals.get_board_approval(approval_id)
      assert approval.category == "agent_promotion"
      assert approval.status == "pending"
      assert approval.proposal_data["agent_id"] == agent.id
      assert approval.proposal_data["current_role"] == "engineer"
      assert approval.proposal_data["new_role"] == "cto"
    end

    test "does not change role when approval is pending" do
      company = create_company(%{"required_approvals" => ["agent_promotion"]})
      agent = create_agent_in_company(company, %{role: :engineer})

      assert {:error, :pending_board_approval, _} =
               Agents.update_agent(agent, %{role: :cto})

      # Agent role should be unchanged
      {:ok, refreshed} = Agents.get_agent(agent.id)
      assert refreshed.role == :engineer
    end

    test "allows role change when no company_id" do
      {:ok, agent} = Agents.create_agent(%{name: "No Company", role: :engineer})

      assert {:ok, updated} = Agents.update_agent(agent, %{role: :cto})
      assert updated.role == :cto
    end

    test "handles string-keyed role in attrs" do
      company = create_company(%{"required_approvals" => ["agent_promotion"]})
      agent = create_agent_in_company(company, %{role: :engineer})

      assert {:error, :pending_board_approval, approval_id} =
               Agents.update_agent(agent, %{"role" => "cto"})

      {:ok, approval} = BoardApprovals.get_board_approval(approval_id)
      assert approval.proposal_data["new_role"] == "cto"
    end
  end

  # --- Executor ---

  describe "execute_approved_hire/2" do
    test "creates agent from stored proposal data" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      board_approval_id = "00000000-0000-0000-0000-000000000001"

      proposal_data = %{
        "attrs" => %{
          "name" => "Executed Agent",
          "role" => "engineer",
          "company_id" => company.id
        },
        "parent_agent_id" => nil
      }

      assert {:ok, %Agent{} = agent} =
               Agents.execute_approved_hire(board_approval_id, proposal_data)

      assert agent.name == "Executed Agent"
      assert agent.role == :engineer
      assert agent.board_approval_id == board_approval_id
    end

    test "returns :already_executed when agent already exists for approval" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      board_approval_id = "00000000-0000-0000-0000-000000000002"

      proposal_data = %{
        "attrs" => %{
          "name" => "Idempotent Agent",
          "role" => "engineer",
          "company_id" => company.id
        },
        "parent_agent_id" => nil
      }

      # First call creates the agent
      assert {:ok, %Agent{} = agent} =
               Agents.execute_approved_hire(board_approval_id, proposal_data)

      # Second call returns :already_executed
      assert {:error, :already_executed} =
               Agents.execute_approved_hire(board_approval_id, proposal_data)
    end
  end

  describe "apply_role_change/2" do
    test "applies role change directly bypassing governance" do
      company = create_company(%{"required_approvals" => ["agent_promotion"]})
      agent = create_agent_in_company(company, %{role: :engineer})

      assert {:ok, updated} = Agents.apply_role_change(agent.id, :cto)
      assert updated.role == :cto
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} =
               Agents.apply_role_change("00000000-0000-0000-0000-000000000000", :cto)
    end
  end

  describe "BoardApprovalActionExecutor" do
    setup [:start_heartbeat_supervisor, :start_executor]

    test "executes agent hire on approval" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      board_member = create_board_member(company)

      {:error, :pending_board_approval, approval_id} =
        Agents.create_agent(%{name: "Executor Test", role: :engineer, company_id: company.id})

      # Approve the board approval
      BoardApprovals.resolve_board_approval(
        approval_id,
        "approved",
        %{decision_reasoning: "Approved for testing"},
        {"user", board_member.id}
      )

      # Give the executor time to process
      Process.sleep(100)

      # Verify agent was created
      agents = Agents.list_agents_by_company(company.id)
      created = Enum.find(agents, &(&1.name == "Executor Test"))
      assert created != nil
      assert created.role == :engineer
    end

    test "executes agent promotion on approval" do
      company = create_company(%{"required_approvals" => ["agent_promotion"]})
      agent = create_agent_in_company(company, %{role: :engineer})
      board_member = create_board_member(company)

      {:error, :pending_board_approval, approval_id} =
        Agents.update_agent(agent, %{role: :cto})

      # Approve the board approval
      BoardApprovals.resolve_board_approval(
        approval_id,
        "approved",
        %{decision_reasoning: "Promotion approved"},
        {"user", board_member.id}
      )

      Process.sleep(100)

      # Verify role was changed
      {:ok, updated} = Agents.get_agent(agent.id)
      assert updated.role == :cto
    end

    test "does not execute denied approval" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      board_member = create_board_member(company)

      {:error, :pending_board_approval, approval_id} =
        Agents.create_agent(%{name: "Denied Agent", role: :engineer, company_id: company.id})

      # Deny the board approval
      BoardApprovals.resolve_board_approval(
        approval_id,
        "denied",
        %{decision_reasoning: "Denied for testing"},
        {"user", board_member.id}
      )

      Process.sleep(100)

      # Verify agent was NOT created
      agents = Agents.list_agents_by_company(company.id)
      assert Enum.empty?(agents)
    end

    test "audits approved and executed actions" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      board_member = create_board_member(company)

      {:error, :pending_board_approval, approval_id} =
        Agents.create_agent(%{name: "Audit Agent", role: :engineer, company_id: company.id})

      BoardApprovals.resolve_board_approval(
        approval_id,
        "approved",
        %{decision_reasoning: "Audit test"},
        {"user", board_member.id}
      )

      Process.sleep(100)

      logs =
        GovernanceAuditLogs.list_governance_audit_logs(action_type: "agent_hired")

      assert length(logs) >= 1
    end

    test "audits denied actions" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      board_member = create_board_member(company)

      {:error, :pending_board_approval, approval_id} =
        Agents.create_agent(%{name: "Denied Audit", role: :engineer, company_id: company.id})

      BoardApprovals.resolve_board_approval(
        approval_id,
        "denied",
        %{decision_reasoning: "Denied audit test"},
        {"user", board_member.id}
      )

      Process.sleep(100)

      logs =
        GovernanceAuditLogs.list_governance_audit_logs(action_type: "board_decision")

      assert length(logs) >= 1
    end

    test "handles role change when current role has changed since approval" do
      company = create_company(%{"required_approvals" => ["agent_promotion"]})
      agent = create_agent_in_company(company, %{role: :engineer})
      board_member = create_board_member(company)

      {:error, :pending_board_approval, approval_id} =
        Agents.update_agent(agent, %{role: :cto})

      # Manually change the agent's role before approval is processed
      # (simulating a race condition)
      {_, _, _} =
        Cympho.Repo.query(
          "UPDATE agents SET role = 'product_manager' WHERE id = $1",
          [agent.id]
        )

      # Approve the original role change
      BoardApprovals.resolve_board_approval(
        approval_id,
        "approved",
        %{decision_reasoning: "Should be skipped"},
        {"user", board_member.id}
      )

      Process.sleep(100)

      # Role should NOT be cto since current role at execution time was product_manager
      {:ok, updated} = Agents.get_agent(agent.id)
      assert updated.role == :product_manager
    end

    test "idempotent: duplicate hire events do not create duplicate agents" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      board_member = create_board_member(company)

      {:error, :pending_board_approval, approval_id} =
        Agents.create_agent(%{name: "Duplicate Test", role: :engineer, company_id: company.id})

      # Approve
      BoardApprovals.resolve_board_approval(
        approval_id,
        "approved",
        %{decision_reasoning: "First approval"},
        {"user", board_member.id}
      )

      Process.sleep(100)

      agents_before = Agents.list_agents_by_company(company.id)
      assert length(agents_before) == 1

      # Simulate duplicate event by resolving again (shouldn't happen in practice but tests idempotency)
      BoardApprovals.resolve_board_approval(
        approval_id,
        "approved",
        %{decision_reasoning: "Duplicate approval"},
        {"user", board_member.id}
      )

      Process.sleep(100)

      agents_after = Agents.list_agents_by_company(company.id)
      assert length(agents_after) == 1
    end
  end
end
