defmodule CymphoWeb.BoardGovernanceE2ETest do
  use CymphoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cympho.{Agents, BoardApprovals, Companies}
  alias Cympho.Users.User

  # --- Helpers ---

  defp create_user(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    %User{}
    |> User.registration_changeset(
      Map.merge(
        %{
          email: "e2e-#{unique}@example.com",
          name: "E2E User #{unique}",
          password: "password123"
        },
        attrs
      )
    )
    |> Cympho.Repo.insert!()
  end

  defp create_company(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{name: "E2E Company #{unique}", slug: "e2e-company-#{unique}"}

    {:ok, company} = Companies.create_company(Map.merge(defaults, attrs))
    company
  end

  defp create_membership(user, company, role \\ "member", is_board_member \\ false) do
    {:ok, membership} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: role,
        is_board_member: is_board_member
      })

    membership
  end

  defp start_executor(_context) do
    case start_supervised(Cympho.BoardApprovals.BoardApprovalActionExecutor) do
      {:ok, pid} ->
        Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
        :ok

      {:error, {:already_started, pid}} ->
        Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
        :ok
    end
  end

  # --- E2E: API agent creation through board pipeline ---

  describe "POST /api/agents through board pipeline" do
    test "returns 403 for non-board user" do
      user = create_user()
      board_user = create_user()
      company = create_company()
      create_membership(user, company, "member", false)
      create_membership(board_user, company, "member", true)

      conn =
        build_conn()
        |> Plug.Conn.assign(:current_user, user)
        |> Plug.Conn.assign(:current_company_id, company.id)
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> post("/api/agents", %{"agent" => %{"name" => "Blocked", "role" => "engineer"}})

      assert json_response(conn, 403)
    end

    test "returns 403 for agent-authenticated request (no current_user)" do
      user = create_user()
      company = create_company()
      create_membership(user, company, "member", true)

      conn =
        build_conn()
        |> Plug.Conn.assign(:current_agent, %{id: "agent-456"})
        |> Plug.Conn.assign(:current_company_id, company.id)
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> post("/api/agents", %{"agent" => %{"name" => "Agent Auth", "role" => "engineer"}})

      assert json_response(conn, 403)
    end

    test "returns 403 when no user is present" do
      conn =
        build_conn()
        |> Plug.Conn.assign(:current_company_id, "some-id")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> post("/api/agents", %{"agent" => %{"name" => "No Auth", "role" => "engineer"}})

      assert json_response(conn, 403)
    end

    test "board member passes board auth plug" do
      user = create_user()
      company = create_company()
      create_membership(user, company, "member", true)

      conn =
        build_conn()
        |> Plug.Conn.assign(:current_user, user)
        |> Plug.Conn.assign(:current_company_id, company.id)
        |> CymphoWeb.Plugs.BoardAuth.call([])

      refute conn.halted
    end
  end

  # --- E2E: LiveView agent creation by non-board user ---

  describe "LiveView /agents/new (board_governed session)" do
    test "redirects non-board member away" do
      user = create_user()
      board_user = create_user()
      company = create_company()
      create_membership(user, company, "member", false)
      create_membership(board_user, company, "member", true)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: nil,
          current_user: user,
          current_company: company,
          flash: %{}
        },
        endpoint: CymphoWeb.Endpoint
      }

      assert {:halt, _socket} = CymphoWeb.Live.BoardAuth.on_mount(:default, %{}, %{}, socket)
    end

    test "allows board member to mount" do
      user = create_user()
      company = create_company()
      create_membership(user, company, "member", true)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: nil,
          current_user: user,
          current_company: company,
          flash: %{}
        },
        endpoint: CymphoWeb.Endpoint
      }

      assert {:cont, updated} = CymphoWeb.Live.BoardAuth.on_mount(:default, %{}, %{}, socket)
      assert updated.assigns[:is_board_member] == true
    end
  end

  # --- E2E: Full approval lifecycle ---

  describe "board approval lifecycle: create agent, vote, agent appears" do
    setup [:start_executor]

    test "board member votes on agent hire and agent is created" do
      company =
        create_company(%{
          governance_config: %{
            "required_approvals" => ["agent_hire"],
            "threshold_type" => "any",
            "threshold_value" => 1
          }
        })

      board_user = create_user()
      create_membership(board_user, company, "member", true)

      # Step 1: Agent hire requires approval
      assert {:error, :pending_board_approval, approval_id} =
               Agents.create_agent(%{
                 name: "Lifecycle Agent",
                 role: :engineer,
                 company_id: company.id
               })

      # Step 2: No agent exists yet
      agents = Agents.list_agents_by_company(company.id)
      assert Enum.empty?(agents)

      # Step 3: Board member casts approve vote, triggering auto-approve
      {:ok, _vote} = BoardApprovals.cast_vote(approval_id, board_user.id, "approve", "LGTM")

      # Step 4: Wait for auto-approve + executor
      Process.sleep(150)

      # Step 5: Agent should now exist
      agents = Agents.list_agents_by_company(company.id)
      agent = Enum.find(agents, &(&1.name == "Lifecycle Agent"))
      assert agent != nil
      assert agent.role == :engineer

      # Step 6: Approval should be resolved
      {:ok, approval} = BoardApprovals.get_board_approval(approval_id)
      assert approval.status == "approved"
    end

    test "denied vote does not create agent" do
      company =
        create_company(%{
          governance_config: %{
            "required_approvals" => ["agent_hire"],
            "threshold_type" => "count",
            "threshold_value" => 2
          }
        })

      board_user1 = create_user()
      board_user2 = create_user()
      create_membership(board_user1, company, "member", true)
      create_membership(board_user2, company, "member", true)

      assert {:error, :pending_board_approval, approval_id} =
               Agents.create_agent(%{
                 name: "Denied Lifecycle Agent",
                 role: :engineer,
                 company_id: company.id
               })

      # One approve, one deny — count threshold (2 approves required) not met
      {:ok, _} = BoardApprovals.cast_vote(approval_id, board_user1.id, "approve")
      {:ok, _} = BoardApprovals.cast_vote(approval_id, board_user2.id, "deny")

      Process.sleep(100)

      # Agent should NOT exist (threshold not met, not auto-approved)
      agents = Agents.list_agents_by_company(company.id)
      refute Enum.any?(agents, &(&1.name == "Denied Lifecycle Agent"))
    end

    test "budget increase through approval lifecycle" do
      company =
        create_company(%{
          governance_config: %{
            "categories" => ["budget_increase"],
            "threshold_type" => "any",
            "threshold_value" => 1,
            "budget_limit_threshold" => 500
          }
        })

      board_user = create_user()
      create_membership(board_user, company, "member", true)

      {:ok, budget} =
        Cympho.Budgets.create_budget(%{
          name: "E2E Budget",
          scope_type: "company",
          scope_id: company.id,
          company_id: company.id,
          limit_amount: Decimal.new("400")
        })

      # Update above threshold → pending approval
      assert {:pending_approval, approval} =
               Cympho.Budgets.update_budget(budget, %{limit_amount: Decimal.new("5000")})

      # Board member approves
      {:ok, _} = BoardApprovals.cast_vote(approval.id, board_user.id, "approve")

      Process.sleep(150)

      # Budget should be updated
      updated_budget = Cympho.Budgets.get_budget!(budget.id)
      assert Decimal.eq?(updated_budget.limit_amount, Decimal.new("5000"))
    end
  end
end
