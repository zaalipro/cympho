defmodule Cympho.LaunchItemsTest do
  use Cympho.DataCase, async: true

  alias Cympho.{Companies, LaunchItems, Users}

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Launch Items Co #{unique}",
        slug: "launch-items-co-#{unique}"
      })

    {:ok, owner} =
      Users.create_user(%{
        email: "launch-owner-#{unique}@example.com",
        name: "Launch Owner #{unique}",
        password: "password1234"
      })

    {:ok, backup_owner} =
      Users.create_user(%{
        email: "launch-owner-b-#{unique}@example.com",
        name: "Launch Owner B #{unique}",
        password: "password1234"
      })

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: owner.id,
        company_id: company.id,
        role: "owner",
        is_board_member: true
      })

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: backup_owner.id,
        company_id: company.id,
        role: "member",
        is_board_member: false
      })

    %{company: company, owner: owner, backup_owner: backup_owner}
  end

  test "creates, updates, and summarizes launch items", %{
    company: company,
    owner: owner,
    backup_owner: backup_owner
  } do
    {:ok, blocked_item} =
      LaunchItems.create_launch_item(%{
        title: "Launch checklist",
        company_id: company.id,
        owner_user_id: owner.id,
        status: "planned",
        is_blocked: true
      })

    {:ok, completed_item} =
      LaunchItems.create_launch_item(%{
        title: "Launch comms",
        company_id: company.id,
        owner_user_id: backup_owner.id,
        status: "completed",
        is_blocked: false
      })

    assert Enum.map(LaunchItems.list_company_launch_items(company.id), & &1.id) == [
             blocked_item.id,
             completed_item.id
           ]

    summary = LaunchItems.company_readiness(company.id)

    assert summary.total == 2
    assert summary.blocked_count == 1
    assert summary.blocked_titles == ["Launch checklist"]
    assert summary.completed_count == 1
    assert summary.completion_percent == 50

    assert {:ok, updated} =
             LaunchItems.update_launch_item(blocked_item, %{
               status: "completed",
               is_blocked: false
             })

    assert updated.status == "completed"
    refute updated.is_blocked
  end

  test "ordinary update cannot move an item to a company where its owner also belongs", %{
    company: company,
    owner: owner
  } do
    unique = System.unique_integer([:positive])

    {:ok, other_company} =
      Companies.create_company(%{
        name: "Other Launch Company #{unique}",
        slug: "other-launch-company-#{unique}"
      })

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: owner.id,
        company_id: other_company.id,
        role: "member",
        is_board_member: false
      })

    {:ok, item} =
      LaunchItems.create_launch_item(%{
        title: "Keep in company A",
        company_id: company.id,
        owner_user_id: owner.id
      })

    assert {:error, changeset} =
             LaunchItems.update_launch_item(item, %{
               company_id: other_company.id,
               title: "Moved"
             })

    assert Keyword.has_key?(changeset.errors, :company_id)
    assert {:ok, unchanged} = LaunchItems.get_company_launch_item(company.id, item.id)
    assert unchanged.title == "Keep in company A"
    assert {:error, :not_found} = LaunchItems.get_company_launch_item(other_company.id, item.id)
  end
end
