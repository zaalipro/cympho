defmodule Cympho.CompaniesAccessTest do
  use Cympho.DataCase, async: false

  alias Cympho.Companies

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{name: "Access #{unique}", slug: "access-#{unique}"})

    owner = user("owner-#{unique}")
    admin = user("admin-#{unique}")
    board = user("board-#{unique}")
    target = user("target-#{unique}")

    {:ok, _} =
      Companies.create_membership(%{company_id: company.id, user_id: owner.id, role: "owner"})

    {:ok, _} =
      Companies.create_membership(%{company_id: company.id, user_id: admin.id, role: "admin"})

    {:ok, _} =
      Companies.create_membership(%{
        company_id: company.id,
        user_id: board.id,
        role: "member",
        is_board_member: true
      })

    %{company: company, owner: owner, admin: admin, board: board, target: target}
  end

  test "only an owner can grant owner membership", %{
    company: company,
    admin: admin,
    board: board,
    target: target,
    owner: owner
  } do
    attrs = %{company_id: company.id, user_id: target.id, role: "owner"}
    assert {:error, :forbidden} = Companies.create_membership_for_actor(admin.id, attrs)
    assert {:error, :forbidden} = Companies.create_membership_for_actor(board.id, attrs)
    refute Companies.has_access?(target.id, company.id)
    assert {:ok, membership} = Companies.create_membership_for_actor(owner.id, attrs)
    assert membership.role == "owner"
  end

  test "managers can grant and remove lower roles but cannot remove an owner", %{
    company: company,
    owner: owner,
    admin: admin,
    board: board,
    target: target
  } do
    attrs = %{company_id: company.id, user_id: target.id, role: "member"}
    assert {:ok, membership} = Companies.create_membership_for_actor(board.id, attrs)
    assert {:ok, _} = Companies.delete_membership_for_actor(admin.id, company.id, membership.id)

    assert {:error, :forbidden} =
             Companies.delete_membership_for_actor(
               board.id,
               company.id,
               Companies.get_membership(owner.id, company.id).id
             )

    refute Companies.has_access?(target.id, company.id)
  end

  test "a lone owner cannot remove itself", %{
    company: company,
    owner: owner,
    admin: admin,
    board: board
  } do
    owner_membership = Companies.get_membership(owner.id, company.id)

    assert {:error, :last_owner} =
             Companies.delete_membership_for_actor(owner.id, company.id, owner_membership.id)

    assert Companies.get_membership(owner.id, company.id)

    assert {:error, :forbidden} =
             Companies.delete_membership_for_actor(admin.id, company.id, owner_membership.id)

    assert {:error, :forbidden} =
             Companies.delete_membership_for_actor(board.id, company.id, owner_membership.id)
  end

  test "owner invites require current owner authority at creation and acceptance", %{
    company: company,
    owner: owner,
    admin: admin,
    board: board,
    target: target
  } do
    attrs = %{company_id: company.id, email: target.email, role: "owner"}
    assert {:error, :forbidden} = Companies.create_invite_for_actor(admin.id, attrs)
    assert {:error, :forbidden} = Companies.create_invite_for_actor(board.id, attrs)
    assert {:ok, invite} = Companies.create_invite_for_actor(owner.id, attrs)
    owner_membership = Companies.get_membership(owner.id, company.id)
    {:ok, _} = Companies.update_membership(owner_membership, %{role: "member"})
    assert {:error, :forbidden} = Companies.accept_invite(invite.token, target.id)
    refute Companies.has_access?(target.id, company.id)
  end

  test "a current owner's invite can be accepted as owner", %{
    company: company,
    owner: owner,
    target: target
  } do
    assert {:ok, invite} =
             Companies.create_invite_for_actor(owner.id, %{
               company_id: company.id,
               email: target.email,
               role: "owner"
             })

    assert {:ok, _} = Companies.accept_invite(invite.token, target.id)
    assert Companies.get_role(target.id, company.id) == "owner"
  end

  test "manager can invite a member while owner can revoke owner invite", %{
    company: company,
    owner: owner,
    board: board,
    target: target
  } do
    assert {:ok, member_invite} =
             Companies.create_invite_for_actor(board.id, %{
               company_id: company.id,
               email: target.email,
               role: "member"
             })

    assert member_invite.token

    assert {:ok, owner_invite} =
             Companies.create_invite_for_actor(owner.id, %{
               company_id: company.id,
               email: target.email,
               role: "owner"
             })

    assert {:error, :forbidden} =
             Companies.revoke_invite_for_actor(board.id, company.id, owner_invite.id)

    assert {:ok, _} = Companies.revoke_invite_for_actor(owner.id, company.id, owner_invite.id)
  end

  test "join-request approval rechecks manager authority and company scope", %{
    company: company,
    board: board,
    target: target
  } do
    {:ok, request} =
      Companies.create_join_request(%{company_id: company.id, user_id: target.id})

    board_membership = Companies.get_membership(board.id, company.id)
    {:ok, _} = Companies.update_membership(board_membership, %{is_board_member: false})

    assert {:error, :forbidden} =
             Companies.approve_join_request_for_actor(board.id, company.id, request.id)

    refute Companies.has_access?(target.id, company.id)

    {:ok, _} =
      board.id
      |> Companies.get_membership(company.id)
      |> Companies.update_membership(%{is_board_member: true})

    assert {:error, :not_found} =
             Companies.approve_join_request_for_actor(
               board.id,
               Ecto.UUID.generate(),
               request.id
             )

    assert {:ok, _} =
             Companies.approve_join_request_for_actor(board.id, company.id, request.id)

    assert Companies.has_access?(target.id, company.id)
  end

  test "join-request rejection rechecks manager authority", %{
    company: company,
    board: board,
    target: target
  } do
    {:ok, request} =
      Companies.create_join_request(%{company_id: company.id, user_id: target.id})

    board_membership = Companies.get_membership(board.id, company.id)
    {:ok, _} = Companies.update_membership(board_membership, %{is_board_member: false})

    assert {:error, :forbidden} =
             Companies.reject_join_request_for_actor(board.id, company.id, request.id)

    assert Repo.get!(Cympho.Companies.JoinRequest, request.id).status == "pending"
  end

  test "resolved join requests cannot be replayed or crossed into another decision", %{
    company: company,
    owner: owner,
    target: target
  } do
    {:ok, rejected} =
      Companies.create_join_request(%{company_id: company.id, user_id: target.id})

    assert {:ok, _} =
             Companies.reject_join_request_for_actor(owner.id, company.id, rejected.id)

    assert {:error, :not_pending} =
             Companies.approve_join_request_for_actor(owner.id, company.id, rejected.id)

    assert {:error, :not_pending} =
             Companies.reject_join_request_for_actor(owner.id, company.id, rejected.id)

    refute Companies.has_access?(target.id, company.id)
    assert Repo.get!(Cympho.Companies.JoinRequest, rejected.id).status == "rejected"

    other = user("approved-#{System.unique_integer([:positive])}")

    {:ok, approved} =
      Companies.create_join_request(%{company_id: company.id, user_id: other.id})

    assert {:ok, _} =
             Companies.approve_join_request_for_actor(owner.id, company.id, approved.id)

    assert {:error, :not_pending} =
             Companies.approve_join_request_for_actor(owner.id, company.id, approved.id)

    assert {:error, :not_pending} =
             Companies.reject_join_request_for_actor(owner.id, company.id, approved.id)

    assert Companies.get_role(other.id, company.id) == "member"
    assert Repo.get!(Cympho.Companies.JoinRequest, approved.id).status == "approved"
  end

  test "approving a pending request for an existing member is a conflict without role change", %{
    company: company,
    owner: owner,
    target: target
  } do
    {:ok, request} =
      Companies.create_join_request(%{company_id: company.id, user_id: target.id})

    {:ok, _} =
      Companies.create_membership_for_actor(owner.id, %{
        company_id: company.id,
        user_id: target.id,
        role: "owner"
      })

    assert {:error, :already_member} =
             Companies.approve_join_request_for_actor(owner.id, company.id, request.id)

    assert Companies.get_role(target.id, company.id) == "owner"
    assert Repo.get!(Cympho.Companies.JoinRequest, request.id).status == "pending"
  end

  defp user(prefix) do
    {:ok, user} =
      Cympho.Users.create_user(%{
        name: prefix,
        email: "#{prefix}@example.com",
        password: "password1234"
      })

    user
  end
end
