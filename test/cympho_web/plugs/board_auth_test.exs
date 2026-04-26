defmodule CymphoWeb.Plugs.BoardAuthTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.{Users, Companies, GovernanceAuditLogs}
  alias Cympho.Users.User
  alias Cympho.Companies.CompanyMembership

  defp create_user(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    %User{}
    |> User.registration_changeset(Map.merge(%{
      email: "board-test-#{unique}@example.com",
      name: "Board Test User #{unique}",
      password: "password123"
    }, attrs))
    |> Cympho.Repo.insert!()
  end

  defp create_company do
    unique = System.unique_integer([:positive])
    {:ok, company} =
      Companies.create_company(%{
        name: "Board Test Company #{unique}",
        slug: "board-test-company-#{unique}"
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

  describe "BoardAuth plug" do
    test "allows board members through" do
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

    test "denies non-board users with 403" do
      user = create_user()
      board_user = create_user()
      company = create_company()
      create_membership(user, company, "member", false)
      create_membership(board_user, company, "member", true)

      conn =
        build_conn()
        |> Plug.Conn.assign(:current_user, user)
        |> Plug.Conn.assign(:current_company_id, company.id)
        |> CymphoWeb.Plugs.BoardAuth.call([])

      assert conn.halted
      assert conn.status == 403
    end

    test "denies when no user is present" do
      conn =
        build_conn()
        |> Plug.Conn.assign(:current_company_id, "some-id")
        |> CymphoWeb.Plugs.BoardAuth.call([])

      assert conn.halted
      assert conn.status == 403
    end

    test "denies when no company context is present" do
      user = create_user()

      conn =
        build_conn()
        |> Plug.Conn.assign(:current_user, user)
        |> CymphoWeb.Plugs.BoardAuth.call([])

      assert conn.halted
      assert conn.status == 403
    end

    test "denies agent-authenticated requests (current_agent without current_user)" do
      user = create_user()
      company = create_company()
      create_membership(user, company, "member", true)

      conn =
        build_conn()
        |> Plug.Conn.assign(:current_agent, %{id: "agent-123"})
        |> Plug.Conn.assign(:current_company_id, company.id)
        |> CymphoWeb.Plugs.BoardAuth.call([])

      assert conn.halted
      assert conn.status == 403
    end

    test "denies all mutations when no board members exist" do
      user = create_user()
      company = create_company()
      create_membership(user, company, "member", false)

      conn =
        build_conn()
        |> Plug.Conn.assign(:current_user, user)
        |> Plug.Conn.assign(:current_company_id, company.id)
        |> CymphoWeb.Plugs.BoardAuth.call([])

      assert conn.halted
      assert conn.status == 403
    end

    test "logs denied attempt to governance audit log" do
      user = create_user()
      board_user = create_user()
      company = create_company()
      create_membership(user, company, "member", false)
      create_membership(board_user, company, "member", true)

      conn =
        build_conn()
        |> Plug.Conn.assign(:current_user, user)
        |> Plug.Conn.assign(:current_company_id, company.id)
        |> Plug.Conn.put_req_header("user-agent", "test-agent")
        |> CymphoWeb.Plugs.BoardAuth.call([])

      assert conn.halted

      [log] = GovernanceAuditLogs.list_governance_audit_logs(action_type: "guard_denied", limit: 1)
      assert log.actor_id == user.id
      assert log.metadata["company_id"] == company.id
    end
  end
end
