defmodule CymphoWeb.BoardGovernanceApiTest do
  use CymphoWeb.ConnCase, async: false

  alias Cympho.{Companies, BoardApprovals, Agents}
  alias Cympho.Users.User

  setup do
    # Allow BoardApprovalActionExecutor GenServer to access test sandbox
    case Process.whereis(Cympho.BoardApprovals.BoardApprovalActionExecutor) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Cympho.Repo, pid, self())
    end

    :ok
  end

  defp create_user(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    %User{}
    |> User.registration_changeset(
      Map.merge(
        %{
          email: "board-api-#{unique}@example.com",
          name: "Board API Test #{unique}",
          password: "password123"
        },
        attrs
      )
    )
    |> Cympho.Repo.insert!()
  end

  defp create_company(governance_config \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Board API Company #{unique}",
        slug: "board-api-company-#{unique}",
        governance_config: governance_config
      })

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

  defp authed_conn(conn, user, company_id) do
    conn
    |> Plug.Conn.assign(:current_user, user)
    |> Plug.Conn.assign(:current_company_id, company_id)
  end

  describe "POST /api/agents — board governance gate" do
    test "returns 403 when no user is present" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})

      conn =
        build_conn()
        |> Plug.Conn.assign(:current_company_id, company.id)
        |> post("/api/agents", %{"agent" => %{"name" => "Agent", "role" => "engineer"}})

      assert %{"errors" => [%{"detail" => "Authentication required"}]} = json_response(conn, 403)
    end

    test "returns 403 when no company context is present" do
      user = create_user()

      conn =
        build_conn()
        |> Plug.Conn.assign(:current_user, user)
        |> post("/api/agents", %{"agent" => %{"name" => "Agent", "role" => "engineer"}})

      assert %{"errors" => [%{"detail" => "Company context required"}]} = json_response(conn, 403)
    end

    test "returns 403 for non-board user when board members exist" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      user = create_user()
      board_user = create_user()
      create_membership(user, company, "member", false)
      create_membership(board_user, company, "member", true)

      conn =
        authed_conn(build_conn(), user, company.id)
        |> post("/api/agents", %{
          "agent" => %{
            "name" => "Blocked Agent",
            "role" => "engineer",
            "company_id" => company.id
          }
        })

      assert %{"errors" => [%{"detail" => "Board membership required"}]} =
               json_response(conn, 403)
    end

    test "returns 403 for any user when no board members are configured" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      user = create_user()
      create_membership(user, company, "member", false)

      conn =
        authed_conn(build_conn(), user, company.id)
        |> post("/api/agents", %{
          "agent" => %{
            "name" => "No Board Agent",
            "role" => "engineer",
            "company_id" => company.id
          }
        })

      assert %{"errors" => [%{"detail" => "No board members configured for this company"}]} =
               json_response(conn, 403)
    end

    test "board member request triggers governance when agent_hire required" do
      company = create_company(%{"required_approvals" => ["agent_hire"]})
      user = create_user()
      create_membership(user, company, "member", true)

      conn =
        authed_conn(build_conn(), user, company.id)
        |> post("/api/agents", %{
          "agent" => %{
            "name" => "Governed Agent",
            "role" => "engineer",
            "company_id" => company.id
          }
        })

      assert %{"data" => %{"status" => "pending_board_approval", "approval_id" => approval_id}} =
               json_response(conn, 202)

      assert is_binary(approval_id)

      {:ok, approval} = BoardApprovals.get_board_approval(approval_id)
      assert approval.status == "pending"
      assert approval.category == "agent_hire"
    end
  end

  describe "Board member approval flow — agent hire via vote" do
    test "board member votes approve, action is executed" do
      company =
        create_company(%{
          "required_approvals" => ["agent_hire"],
          "threshold_type" => "any"
        })

      board_user = create_user()
      create_membership(board_user, company, "member", true)

      {:ok, approval} =
        BoardApprovals.create_board_approval(%{
          title: "Agent Hire: Vote Test",
          category: "agent_hire",
          company_id: company.id,
          proposal_data: %{
            "attrs" => %{
              "name" => "Voted Agent",
              "role" => "engineer",
              "company_id" => company.id
            }
          }
        })

      {:ok, _vote} = BoardApprovals.cast_vote(approval.id, board_user.id, "approve", "Looks good")

      updated = BoardApprovals.get_board_approval!(approval.id)
      assert updated.status == "approved"

      {:ok, agent} = BoardApprovals.execute_approved_action(updated)
      assert agent.name == "Voted Agent"
      assert agent.role == :engineer
    end

    test "deny vote with 'all' threshold cast first prevents auto-approve" do
      company =
        create_company(%{
          "required_approvals" => ["agent_hire"],
          "threshold_type" => "all"
        })

      board_user1 = create_user()
      board_user2 = create_user()
      create_membership(board_user1, company, "member", true)
      create_membership(board_user2, company, "member", true)

      {:ok, approval} =
        BoardApprovals.create_board_approval(%{
          title: "Agent Hire: Deny First",
          category: "agent_hire",
          company_id: company.id,
          proposal_data: %{
            "attrs" => %{
              "name" => "Denied Agent",
              "role" => "engineer",
              "company_id" => company.id
            }
          }
        })

      # Deny first — with "all" threshold, deny_count > 0 prevents auto-approve
      {:ok, _} = BoardApprovals.cast_vote(approval.id, board_user1.id, "deny")

      updated = BoardApprovals.get_board_approval!(approval.id)
      assert updated.status == "pending"

      # Second approve vote still doesn't auto-approve (deny exists)
      {:ok, _} = BoardApprovals.cast_vote(approval.id, board_user2.id, "approve")

      updated = BoardApprovals.get_board_approval!(approval.id)
      assert updated.status == "pending"

      # Manually resolve as denied
      {:ok, denied} =
        BoardApprovals.resolve_board_approval(
          approval.id,
          "denied",
          %{
            decision_reasoning: "Denied by vote"
          },
          {"user", board_user1.id}
        )

      assert denied.status == "denied"

      # Agent should NOT exist
      agents = Agents.list_agents_by_company(company.id)
      assert Enum.empty?(agents)
    end

    test "no votes means no auto-approve regardless of threshold" do
      company =
        create_company(%{
          "required_approvals" => ["agent_hire"],
          "threshold_type" => "any"
        })

      {:ok, approval} =
        BoardApprovals.create_board_approval(%{
          title: "Agent Hire: No Votes",
          category: "agent_hire",
          company_id: company.id,
          proposal_data: %{
            "attrs" => %{
              "name" => "No Vote Agent",
              "role" => "engineer",
              "company_id" => company.id
            }
          }
        })

      updated = BoardApprovals.get_board_approval!(approval.id)
      assert updated.status == "pending"

      agents = Agents.list_agents_by_company(company.id)
      assert Enum.empty?(agents)
    end
  end
end
