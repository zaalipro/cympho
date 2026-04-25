defmodule CymphoWeb.Live.BoardAuthTest do
  use Cympho.DataCase, async: true

  alias Cympho.{Companies, GovernanceAuditLogs}
  alias Cympho.Users.User

  defp create_user(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    %User{}
    |> User.registration_changeset(Map.merge(%{
      email: "lv-board-#{unique}@example.com",
      name: "LV Board Test #{unique}",
      password: "password123"
    }, attrs))
    |> Cympho.Repo.insert!()
  end

  defp create_company do
    unique = System.unique_integer([:positive])
    {:ok, company} =
      Companies.create_company(%{
        name: "LV Board Company #{unique}",
        slug: "lv-board-company-#{unique}"
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

  describe "on_mount/4 - board member access" do
    test "allows board members through with :is_board_member true" do
      user = create_user()
      company = create_company()
      create_membership(user, company, "member", true)
      socket = build_socket(user, company)

      result = CymphoWeb.Live.BoardAuth.on_mount(:default, %{}, %{}, socket)

      assert {:cont, updated_socket} = result
      assert updated_socket.assigns[:is_board_member] == true
    end

    test "redirects non-board members with halt" do
      user = create_user()
      board_user = create_user()
      company = create_company()
      create_membership(user, company, "member", false)
      create_membership(board_user, company, "member", true)
      socket = build_socket(user, company)

      result = CymphoWeb.Live.BoardAuth.on_mount(:default, %{}, %{}, socket)

      assert {:halt, _socket} = result
    end

    test "assigns :is_board_member false when user is nil" do
      company = create_company()
      socket = build_socket(nil, company)

      result = CymphoWeb.Live.BoardAuth.on_mount(:default, %{}, %{}, socket)

      assert {:cont, updated_socket} = result
      assert updated_socket.assigns[:is_board_member] == false
    end

    test "assigns :is_board_member false when company is nil" do
      user = create_user()
      socket = build_socket(user, nil)

      result = CymphoWeb.Live.BoardAuth.on_mount(:default, %{}, %{}, socket)

      assert {:cont, updated_socket} = result
      assert updated_socket.assigns[:is_board_member] == false
    end

    test "assigns :is_board_member false when both user and company are nil" do
      socket = build_socket(nil, nil)

      result = CymphoWeb.Live.BoardAuth.on_mount(:default, %{}, %{}, socket)

      assert {:cont, updated_socket} = result
      assert updated_socket.assigns[:is_board_member] == false
    end
  end

  describe "on_mount/4 - no board members configured" do
    test "redirects when no board members exist for company" do
      user = create_user()
      company = create_company()
      create_membership(user, company, "member", false)
      socket = build_socket(user, company)

      result = CymphoWeb.Live.BoardAuth.on_mount(:default, %{}, %{}, socket)

      assert {:halt, _socket} = result
    end

    test "redirects even for owner when no board members exist" do
      user = create_user()
      company = create_company()
      create_membership(user, company, "owner", false)
      socket = build_socket(user, company)

      result = CymphoWeb.Live.BoardAuth.on_mount(:default, %{}, %{}, socket)

      assert {:halt, _socket} = result
    end
  end

  describe "on_mount/4 - audit logging" do
    test "logs denial for non-board member" do
      user = create_user()
      board_user = create_user()
      company = create_company()
      create_membership(user, company, "member", false)
      create_membership(board_user, company, "member", true)
      socket = build_socket(user, company)

      CymphoWeb.Live.BoardAuth.on_mount(:default, %{}, %{}, socket)

      [log] = GovernanceAuditLogs.list_governance_audit_logs(action_type: "guard_denied", limit: 1)
      assert log.actor_id == user.id
      assert log.metadata["company_id"] == company.id
    end

    test "logs denial when no board members configured" do
      user = create_user()
      company = create_company()
      create_membership(user, company, "member", false)
      socket = build_socket(user, company)

      CymphoWeb.Live.BoardAuth.on_mount(:default, %{}, %{}, socket)

      [log] = GovernanceAuditLogs.list_governance_audit_logs(action_type: "guard_denied", limit: 1)
      assert log.actor_id == user.id
    end
  end
end
