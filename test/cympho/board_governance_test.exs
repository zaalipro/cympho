defmodule Cympho.BoardGovernanceTest do
  use Cympho.DataCase, async: true

  alias Cympho.Companies
  alias Cympho.Companies.{Company, CompanyMembership}
  alias Cympho.BoardApprovals
  alias Cympho.BoardApprovals.BoardApproval

  defp create_test_user(_attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    {:ok, user} =
      Cympho.Users.create_user(%{
        email: "test-#{unique}@example.com",
        name: "Test User #{unique}",
        password: "password123"
      })
    user
  end

  defp create_test_company(_attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    {:ok, company} =
      Companies.create_company(%{
        name: "Test Company #{unique}",
        slug: "test-company-#{unique}"
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

  describe "CompanyMembership changeset - is_board_member" do
    test "defaults is_board_member to false" do
      changeset = CompanyMembership.changeset(%CompanyMembership{}, %{
        role: "member",
        user_id: Ecto.UUID.generate(),
        company_id: Ecto.UUID.generate()
      })
      assert changeset.valid?
    end

    test "casts is_board_member when provided" do
      changeset = CompanyMembership.changeset(%CompanyMembership{}, %{
        role: "member",
        is_board_member: true,
        user_id: Ecto.UUID.generate(),
        company_id: Ecto.UUID.generate()
      })
      assert changeset.changes[:is_board_member] == true
    end
  end

  describe "Company changeset - governance_config" do
    test "accepts valid governance_config" do
      config = %{
        "categories" => ["agent_hire", "agent_termination"],
        "threshold_type" => "percentage",
        "threshold_value" => 0.6
      }
      changeset = Company.changeset(%Company{}, %{name: "Test", slug: "test", governance_config: config})
      assert changeset.valid?
    end

    test "rejects governance_config with non-list categories" do
      config = %{"categories" => "not-a-list"}
      changeset = Company.changeset(%Company{}, %{name: "Test", slug: "test", governance_config: config})
      refute changeset.valid?
      assert %{governance_config: ["categories must be a list"]} = errors_on(changeset)
    end

    test "rejects invalid threshold_type" do
      config = %{"threshold_type" => "invalid"}
      changeset = Company.changeset(%Company{}, %{name: "Test", slug: "test", governance_config: config})
      refute changeset.valid?
      assert %{governance_config: ["threshold_type must be percentage or count"]} = errors_on(changeset)
    end

    test "rejects non-numeric threshold_value" do
      config = %{"threshold_value" => "not-a-number"}
      changeset = Company.changeset(%Company{}, %{name: "Test", slug: "test", governance_config: config})
      refute changeset.valid?
      assert %{governance_config: ["threshold_value must be a number"]} = errors_on(changeset)
    end

    test "rejects non-map governance_config" do
      changeset = Company.changeset(%Company{}, %{name: "Test", slug: "test", governance_config: "not-a-map"})
      refute changeset.valid?
      assert %{governance_config: ["must be a map"]} = errors_on(changeset)
    end
  end

  describe "is_board_member?/2" do
    test "returns false for non-member" do
      user = create_test_user()
      company = create_test_company()
      refute Companies.is_board_member?(user.id, company.id)
    end

    test "returns false for regular member" do
      user = create_test_user()
      company = create_test_company()
      create_membership(user, company, "member", false)
      refute Companies.is_board_member?(user.id, company.id)
    end

    test "returns true for board member" do
      user = create_test_user()
      company = create_test_company()
      create_membership(user, company, "member", true)
      assert Companies.is_board_member?(user.id, company.id)
    end
  end

  describe "list_board_members/1" do
    test "returns only board members" do
      company = create_test_company()
      user1 = create_test_user()
      user2 = create_test_user()
      create_membership(user1, company, "member", false)
      create_membership(user2, company, "member", true)

      board_members = Companies.list_board_members(company.id)
      assert length(board_members) == 1
      assert hd(board_members).user_id == user2.id
    end

    test "returns empty list when no board members" do
      company = create_test_company()
      assert Companies.list_board_members(company.id) == []
    end
  end

  describe "update_board_membership/2" do
    test "can promote member to board member" do
      user = create_test_user()
      company = create_test_company()
      membership = create_membership(user, company, "member", false)

      {:ok, updated} = Companies.update_board_membership(membership, %{is_board_member: true})
      assert updated.is_board_member == true
    end

    test "can demote board member" do
      user = create_test_user()
      company = create_test_company()
      membership = create_membership(user, company, "member", true)

      {:ok, updated} = Companies.update_board_membership(membership, %{is_board_member: false})
      assert updated.is_board_member == false
    end
  end

  describe "BoardApproval.categories/0" do
    test "includes agent_hire" do
      assert "agent_hire" in BoardApproval.categories()
    end
  end

  describe "governance_config_required?/2" do
    test "returns true when category is in governance config" do
      company = %Company{
        governance_config: %{"categories" => ["agent_hire", "agent_termination"]}
      }
      assert BoardApprovals.governance_config_required?(company, "agent_hire")
    end

    test "returns false when category is not in governance config" do
      company = %Company{
        governance_config: %{"categories" => ["agent_termination"]}
      }
      refute BoardApprovals.governance_config_required?(company, "agent_hire")
    end

    test "returns false when governance config has no categories" do
      company = %Company{governance_config: %{}}
      refute BoardApprovals.governance_config_required?(company, "agent_hire")
    end

    test "returns false when governance config is nil" do
      company = %Company{governance_config: nil}
      refute BoardApprovals.governance_config_required?(company, "agent_hire")
    end
  end
end
