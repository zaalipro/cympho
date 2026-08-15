defmodule Cympho.PrincipalPermissionsTest do
  use Cympho.DataCase, async: true

  alias Cympho.BoardApprovals
  alias Cympho.Companies
  alias Cympho.PrincipalPermissions
  alias Cympho.Users

  test "blank-scope grant in company A does not pass has_permission? for company B" do
    company_a = create_company()
    company_b = create_company()
    user = create_user()

    {:ok, grant} =
      PrincipalPermissions.create_permission_grant(%{
        company_id: company_a.id,
        principal_id: user.id,
        principal_type: "user",
        permission: "task.assign"
      })

    assert grant.company_id == company_a.id
    assert is_nil(grant.scope_type)
    assert is_nil(grant.scope_id)

    assert PrincipalPermissions.has_permission?(user.id, "user", "task.assign", %{
             company_id: company_a.id
           })

    refute PrincipalPermissions.has_permission?(user.id, "user", "task.assign", %{
             company_id: company_b.id
           })

    assert PrincipalPermissions.has_permission_in_scope?(
             user.id,
             "user",
             "task.assign",
             company: company_a.id
           )

    refute PrincipalPermissions.has_permission_in_scope?(
             user.id,
             "user",
             "task.assign",
             company: company_b.id
           )
  end

  test "create requires company_id" do
    user = create_user()

    assert {:error, changeset} =
             PrincipalPermissions.create_permission_grant(%{
               principal_id: user.id,
               principal_type: "user",
               permission: "task.assign"
             })

    assert %{company_id: ["can't be blank"]} = errors_on(changeset)
  end

  test "get_company_principal_permission_grant is company-scoped" do
    company_a = create_company()
    company_b = create_company()
    user = create_user()

    {:ok, grant} =
      PrincipalPermissions.create_permission_grant(%{
        company_id: company_a.id,
        principal_id: user.id,
        principal_type: "user",
        permission: "task.assign"
      })

    assert {:ok, ^grant} =
             PrincipalPermissions.get_company_principal_permission_grant(company_a.id, grant.id)

    assert {:error, :not_found} =
             PrincipalPermissions.get_company_principal_permission_grant(company_b.id, grant.id)

    refute function_exported?(PrincipalPermissions, :get_principal_permission_grant!, 1)
  end

  test "create_permission_grant_from_approval copies board_approval.company_id" do
    company = create_company()
    user = create_user()

    {:ok, approval} =
      BoardApprovals.create_board_approval(%{
        title: "Grant task.assign",
        category: "principal_permission",
        company_id: company.id,
        proposal_data: %{
          "principal_id" => user.id,
          "principal_type" => "user",
          "permission" => "task.assign"
        }
      })

    {:ok, grant} = PrincipalPermissions.create_permission_grant_from_approval(approval)

    assert grant.company_id == company.id
    assert grant.board_approval_id == approval.id
    assert grant.permission == "task.assign"
  end

  test "list_principal_permission_grants requires a company_id" do
    company_a = create_company()
    company_b = create_company()
    user = create_user()

    {:ok, grant} =
      PrincipalPermissions.create_permission_grant(%{
        company_id: company_a.id,
        principal_id: user.id,
        principal_type: "user",
        permission: "task.assign"
      })

    assert Enum.map(PrincipalPermissions.list_principal_permission_grants(company_a.id), & &1.id) ==
             [grant.id]

    assert PrincipalPermissions.list_principal_permission_grants(company_b.id) == []
  end

  describe "broadcast scoping" do
    # These were published on the global topic "principal_permissions", so any
    # subscriber received every tenant's grants. CLAUDE.md requires per-company
    # topics for exactly this reason.
    test "a grant in company A is not delivered to a subscriber in company B" do
      company_a = create_company()
      company_b = create_company()
      user = create_user()

      :ok = PrincipalPermissions.subscribe(company_b.id)

      {:ok, grant} =
        PrincipalPermissions.create_permission_grant(%{
          company_id: company_a.id,
          principal_id: user.id,
          principal_type: "user",
          permission: "task.assign"
        })

      refute_receive {:permission_grant_created, ^grant}, 200
    end

    test "a grant is delivered to a subscriber in its own company" do
      company_a = create_company()
      user = create_user()

      :ok = PrincipalPermissions.subscribe(company_a.id)

      {:ok, grant} =
        PrincipalPermissions.create_permission_grant(%{
          company_id: company_a.id,
          principal_id: user.id,
          principal_type: "user",
          permission: "task.assign"
        })

      grant_id = grant.id
      assert_receive {:permission_grant_created, %{id: ^grant_id}}, 500
    end

    test "revocation is also company-scoped" do
      company_a = create_company()
      company_b = create_company()
      user = create_user()

      {:ok, grant} =
        PrincipalPermissions.create_permission_grant(%{
          company_id: company_a.id,
          principal_id: user.id,
          principal_type: "user",
          permission: "task.assign"
        })

      :ok = PrincipalPermissions.subscribe(company_b.id)
      {:ok, revoked} = PrincipalPermissions.revoke_permission_grant(grant)

      refute_receive {:permission_grant_revoked, ^revoked}, 200
    end
  end

  defp create_company do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Grant Co #{unique}",
        slug: "grant-co-#{unique}"
      })

    company
  end

  defp create_user do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.create_user(%{
        email: "grant-user-#{unique}@example.com",
        name: "Grant User #{unique}",
        password: "password1234"
      })

    user
  end
end
