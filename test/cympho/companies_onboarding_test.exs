defmodule Cympho.CompaniesOnboardingTest do
  use Cympho.DataCase, async: true

  alias Cympho.Companies

  defp create_user! do
    {:ok, user} =
      Cympho.Users.create_user(%{
        email: "owner-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        password: "password1234"
      })

    user
  end

  describe "create_company_for_owner/2" do
    test "atomically creates the owner membership and selects the company" do
      user = create_user!()

      assert {:ok, company} =
               Companies.create_company_for_owner(
                 %{name: "Manual Owned Co", slug: "manual-owned-co"},
                 user.id
               )

      membership = Companies.get_membership(user.id, company.id)
      assert membership.role == "owner"
      assert membership.is_board_member

      assert {:ok, reloaded} = Cympho.Users.get_user(user.id)
      assert reloaded.company_id == company.id
    end

    test "does not create a company when the owner does not exist" do
      assert {:error, :not_found} =
               Companies.create_company_for_owner(
                 %{name: "Orphan Co", slug: "orphan-co"},
                 Ecto.UUID.generate()
               )

      assert Companies.get_company_by_slug("orphan-co") == nil
    end
  end

  describe "create_autonomous_company/1 owner linkage" do
    test "creates an owner board membership and sets the user's default company" do
      user = create_user!()

      {:ok, %{company: company}} =
        Companies.create_autonomous_company(%{name: "Owned Co", owner_user_id: user.id})

      membership = Companies.get_membership(user.id, company.id)
      assert membership.role == "owner"
      assert membership.is_board_member

      {:ok, reloaded} = Cympho.Users.get_user(user.id)
      assert reloaded.company_id == company.id
    end

    test "without owner_user_id no membership is created (backward compatible)" do
      {:ok, %{company: company}} = Companies.create_autonomous_company(%{name: "Legacy Co"})

      assert Companies.list_memberships(company.id) == []
    end

    test "an unknown owner_user_id rolls the whole launch back" do
      assert {:error, :owner_not_found} =
               Companies.create_autonomous_company(%{
                 name: "Ghost Co",
                 owner_user_id: Ecto.UUID.generate()
               })

      assert Companies.get_company_by_slug("ghost-co") == nil
    end
  end

  describe "create_autonomous_company/1 project name" do
    test "uses the supplied project_name over the blueprint default" do
      {:ok, %{project: project}} =
        Companies.create_autonomous_company(%{
          name: "Named Project Co",
          project_name: "Growth Engine"
        })

      assert project.name == "Growth Engine"
    end

    test "falls back to the blueprint default when project_name is blank" do
      {:ok, %{project: project}} =
        Companies.create_autonomous_company(%{name: "Default Project Co", project_name: "  "})

      assert project.name == "Company OS"
    end

    test "falls back to the blueprint default when project_name is absent" do
      {:ok, %{project: project}} =
        Companies.create_autonomous_company(%{name: "No Project Key Co"})

      assert project.name == "Company OS"
    end
  end

  describe "create_autonomous_company/1 governance permissions" do
    test "CEO and CTO carry the governance authority flags" do
      {:ok, %{agents: agents}} =
        Companies.create_autonomous_company(%{name: "Gov Co"})

      for role <- [:ceo, :cto] do
        agent = Enum.find(agents, &(&1.role == role))
        assert agent.permissions["can_create_agents"]
        assert agent.permissions["can_assign_tasks"]
        assert agent.permissions["can_approve"]
      end
    end

    test "engineers do not carry the governance authority flags" do
      {:ok, %{agents: agents}} =
        Companies.create_autonomous_company(%{name: "Eng Co", engineer_count: 1})

      engineer = Enum.find(agents, &(&1.role == :engineer))
      refute engineer.permissions["can_assign_tasks"]
    end
  end

  describe "create_autonomous_company/1 engineer names" do
    test "names engineer agents in order, padding with defaults" do
      {:ok, %{agents: agents}} =
        Companies.create_autonomous_company(%{
          name: "Named Co",
          engineer_count: 3,
          engineer_names: ["Ada", "Grace", ""]
        })

      engineer_names =
        agents |> Enum.filter(&(&1.role == :engineer)) |> Enum.map(& &1.name)

      assert engineer_names == ["Ada", "Grace", "Engineer 3"]
    end
  end

  describe "create_autonomous_company/1 agent runtime" do
    test "command and model land in every agent's runtime_config" do
      {:ok, %{agents: agents}} =
        Companies.create_autonomous_company(%{
          name: "Runtime Co",
          engineer_count: 1,
          agent_runtime: %{"command" => "cz", "model" => "claude-sonnet-5"}
        })

      assert agents != []

      for agent <- agents do
        assert agent.runtime_config["command"] == "cz"
        assert agent.runtime_config["env"]["ANTHROPIC_MODEL"] == "claude-sonnet-5"
        assert agent.runtime_config["autonomous"] == true
      end
    end

    test "blank runtime values are dropped and autonomous default is preserved" do
      {:ok, %{agents: agents}} =
        Companies.create_autonomous_company(%{
          name: "Default Runtime Co",
          engineer_count: 1,
          agent_runtime: %{"command" => "  ", "model" => ""}
        })

      for agent <- agents do
        refute Map.has_key?(agent.runtime_config, "command")
        refute Map.has_key?(agent.runtime_config, "env")
        assert agent.runtime_config["autonomous"] == true
      end
    end
  end
end
