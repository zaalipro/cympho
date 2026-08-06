defmodule Cympho.CompaniesOnboardingTest do
  use Cympho.DataCase, async: true

  alias Cympho.{Agents, Budgets, Companies, Finances, Issues}
  alias Cympho.Finances.{BudgetPolicy, TokenUsage}
  alias Cympho.Repo

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

  describe "create_autonomous_company/1 budget hard-stop ownership" do
    test "onboarding policy has no budget_id and survives UI company budget create/delete" do
      assert {:ok, result} =
               Companies.create_autonomous_company(%{
                 name: "Hardstop Protect Co",
                 budget_monthly_cents: 100,
                 engineer_count: 1
               })

      company = result.company
      onboarding = result.budget_policy
      assert %BudgetPolicy{} = onboarding
      assert is_nil(onboarding.budget_id)
      assert onboarding.scope == "company"
      assert onboarding.action_on_exceed == "block"
      assert onboarding.is_active
      assert Decimal.eq?(onboarding.budget_limit_usd, Decimal.new("1.00"))

      agent = hd(result.agents)
      issue = hd(result.seed_issues)

      assert {:ok, ui_budget} =
               Budgets.create_budget(%{
                 company_id: company.id,
                 name: "Owner UI budget",
                 scope_type: "company",
                 scope_id: company.id,
                 limit_amount: Decimal.new("999.00"),
                 hard_stop: false
               })

      ui_policy = Finances.matching_budget_policy(ui_budget)
      assert ui_policy.budget_id == ui_budget.id
      assert ui_policy.id != onboarding.id
      assert ui_policy.action_on_exceed == "warn"

      still = Repo.get!(BudgetPolicy, onboarding.id)
      assert still.is_active
      assert is_nil(still.budget_id)
      assert still.action_on_exceed == "block"
      assert Decimal.eq?(still.budget_limit_usd, Decimal.new("1.00"))

      Repo.insert!(%TokenUsage{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        provider: "test",
        model: "test",
        input_tokens: 1,
        output_tokens: 1,
        total_tokens: 2,
        cost_usd: Decimal.new("1.50")
      })

      assert {:error, {:budget_blocked, info}} = Finances.check_runtime_budget(issue, agent)
      assert info.policy_id == onboarding.id

      assert {:ok, _} = Budgets.delete_budget(ui_budget)
      refute Repo.get!(BudgetPolicy, ui_policy.id).is_active
      assert Repo.get!(BudgetPolicy, onboarding.id).is_active

      assert {:error, {:budget_blocked, %{policy_id: policy_id}}} =
               Finances.check_runtime_budget(
                 Issues.get_issue!(issue.id),
                 Agents.get_agent!(agent.id)
               )

      assert policy_id == onboarding.id
    end
  end
end
