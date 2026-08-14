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
