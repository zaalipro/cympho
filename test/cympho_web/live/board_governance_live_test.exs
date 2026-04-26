defmodule CymphoWeb.Live.BoardGovernanceLiveTest do
  @moduledoc """
  E2E tests for LiveView board governance.

  Tests the BoardAuth on_mount hook in the context of the board_governed
  live_session (/agents/new, /agents/:id/edit). LiveView HTML rendering
  is not available in this test environment, so we test on_mount directly
  and verify the full board approval lifecycle through the API and context layers.
  """
  use Cympho.DataCase, async: true

  alias Cympho.{Companies, BoardApprovals, Agents}
  alias Cympho.Users.User
  alias Cympho.BoardApprovals.BoardApproval

  defp create_user(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    %User{}
    |> User.registration_changeset(Map.merge(%{
      email: "board-lv-e2e-#{unique}@example.com",
      name: "Board LV E2E #{unique}",
      password: "password123"
    }, attrs))
    |> Cympho.Repo.insert!()
  end

  defp create_company(governance_config \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Board LV E2E Company #{unique}",
        slug: "board-lv-e2e-company-#{unique}",
        governance_config: governance_config
      })

    company
  end

  defp create_membership(user, company, role \\ "member", is_board_member \\ false) do
    {:ok, _} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: role,
        is_board_member: is_board_member
      })
  end

  defp build_socket(user, company) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: nil,
        current_user: user,
        current_company: company,
        flash: %{}
      },
      endpoint: CymphoWeb.Endpoint
    }
  end

  describe "/agents/new — board_governed LiveView on_mount" do
    test "halts non-board member with redirect when board members exist" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      user = create_user()
      board_user = create_user()
      create_membership(user, company, "member", false)
      create_membership(board_user, company, "member", true)
      socket = build_socket(user, company)

      assert {:halt, _socket} = CymphoWeb.Live.BoardAuth.on_mount(:default, %{}, %{}, socket)
    end

    test "halts any user when no board members are configured" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      user = create_user()
      create_membership(user, company, "owner", false)
      socket = build_socket(user, company)

      assert {:halt, _socket} = CymphoWeb.Live.BoardAuth.on_mount(:default, %{}, %{}, socket)
    end

    test "allows board member through with is_board_member: true" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      user = create_user()
      create_membership(user, company, "member", true)
      socket = build_socket(user, company)

      assert {:cont, updated_socket} = CymphoWeb.Live.BoardAuth.on_mount(:default, %{}, %{}, socket)
      assert updated_socket.assigns[:is_board_member] == true
    end

    test "allows through with is_board_member: false when user is nil" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      socket = build_socket(nil, company)

      assert {:cont, updated_socket} = CymphoWeb.Live.BoardAuth.on_mount(:default, %{}, %{}, socket)
      assert updated_socket.assigns[:is_board_member] == false
    end
  end

  describe "full board approval E2E flow: propose → vote → execute" do
    test "agent hire: board member proposes, votes, agent appears in company" do
      company = create_company(%{
        "required_approvals" => ["agent_hire"],
        "threshold_type" => "any"
      })

      board_user = create_user()
      create_membership(board_user, company, "member", true)

      # Step 1: Propose agent hire (via context — simulates what LiveView/API would trigger)
      assert {:ok, %BoardApproval{} = approval} =
               BoardApprovals.propose_agent_hire(company.id, %{
                 "name" => "E2E Hire Agent",
                 "role" => "engineer",
                 "company_id" => company.id
               })

      assert approval.category == "agent_hire"
      assert approval.status == "pending"

      # Step 2: Board member votes approve
      {:ok, vote} = BoardApprovals.cast_vote(approval.id, board_user.id, "approve", "Good hire")
      assert vote.vote == "approve"

      # Step 3: Auto-approve kicks in with "any" threshold
      updated_approval = BoardApprovals.get_board_approval!(approval.id)
      assert updated_approval.status == "approved"

      # Step 4: Execute the approved action
      assert {:ok, agent} = BoardApprovals.execute_approved_action(updated_approval)
      assert agent.name == "E2E Hire Agent"
      assert agent.role == :engineer

      # Step 5: Agent appears in company's agent list
      agents = Agents.list_agents_by_company(company.id)
      found = Enum.find(agents, &(&1.name == "E2E Hire Agent"))
      assert found != nil
    end

    test "role change: board member proposes, votes, role is updated" do
      company = create_company(%{
        "required_approvals" => ["agent_promotion"],
        "threshold_type" => "any"
      })

      board_user = create_user()
      create_membership(board_user, company, "member", true)

      # Create an agent first
      {:ok, agent} = Agents.do_create_agent(%{name: "Promo Target", role: :engineer, company_id: company.id})

      # Step 1: Propose role change
      assert {:ok, %BoardApproval{} = approval} =
               BoardApprovals.propose_role_change(company.id, agent.id, :cto)

      assert approval.category == "agent_promotion"
      assert approval.status == "pending"

      # Step 2: Board member votes approve
      {:ok, _vote} = BoardApprovals.cast_vote(approval.id, board_user.id, "approve")

      # Step 3: Auto-approve
      updated_approval = BoardApprovals.get_board_approval!(approval.id)
      assert updated_approval.status == "approved"

      # Step 4: Execute
      assert {:ok, updated_agent} = BoardApprovals.execute_approved_action(updated_approval)
      assert updated_agent.role == :cto

      # Step 5: Verify in DB
      {:ok, refreshed} = Agents.get_agent(agent.id)
      assert refreshed.role == :cto
    end

    test "budget increase: board member proposes, votes, budget limit updated" do
      company = create_company(%{
        "categories" => ["budget_increase"],
        "threshold_type" => "any",
        "budget_limit_threshold" => 500
      })

      board_user = create_user()
      create_membership(board_user, company, "member", true)

      # Create a budget
      {:ok, budget} =
        Cympho.Budgets.execute_budget_creation(%{
          name: "E2E Budget",
          scope_type: "company",
          scope_id: company.id,
          company_id: company.id,
          limit_amount: Decimal.new("400"),
          currency: "USD"
        })

      # Step 1: Propose budget increase
      assert {:pending_approval, %BoardApproval{} = approval} =
               Cympho.Budgets.update_budget(budget, %{limit_amount: Decimal.new("5000")})

      assert approval.category == "budget_increase"

      # Step 2: Board member votes approve
      {:ok, _vote} = BoardApprovals.cast_vote(approval.id, board_user.id, "approve")

      # Step 3: Auto-approve
      updated_approval = BoardApprovals.get_board_approval!(approval.id)
      assert updated_approval.status == "approved"

      # Step 4: Execute
      assert {:ok, updated_budget} = BoardApprovals.execute_approved_action(updated_approval)
      assert Decimal.eq?(updated_budget.limit_amount, Decimal.new("5000"))

      # Step 5: Verify in DB
      refreshed = Cympho.Budgets.get_budget!(budget.id)
      assert Decimal.eq?(refreshed.limit_amount, Decimal.new("5000"))
    end
  end
end
