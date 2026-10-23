defmodule Cympho.Finances.CompanyLimitTest do
  @moduledoc "B5: the owner changes the company spending limit set at setup (r3 Spending)."
  use Cympho.DataCase, async: true

  alias Cympho.{Companies, Costs, Finances, Users}
  alias Cympho.Finances.{BudgetIncident, BudgetPolicy, TokenUsage}
  alias Cympho.GovernanceAuditLogs.GovernanceAuditLog

  setup do
    company = company!()
    owner = member!(company, "owner", true)
    policy = setup_policy!(company, "300.00")
    %{company: company, owner: owner, policy: policy}
  end

  describe "company_limit/1" do
    test "is the one active, unowned company-wide policy", %{company: company, policy: policy} do
      assert {:ok, %BudgetPolicy{id: id}} = Finances.company_limit(company.id)
      assert id == policy.id
    end

    test "is ambiguous when another company-wide policy is active", %{company: company} do
      setup_policy!(company, "500.00")
      assert {:error, :ambiguous} = Finances.company_limit(company.id)
    end

    test "is none without a company-wide policy" do
      assert {:error, :none} = Finances.company_limit(company!().id)
      assert {:error, :none} = Finances.company_limit(nil)
    end
  end

  describe "update_company_limit/3" do
    test "a board member raises 300 to 400 and the posture follows", %{
      company: company,
      owner: owner,
      policy: policy
    } do
      assert {:ok, %BudgetPolicy{} = updated} =
               Finances.update_company_limit(company.id, "400", owner.id)

      assert Decimal.equal?(updated.budget_limit_usd, Decimal.new("400"))
      assert Decimal.equal?(Repo.get!(BudgetPolicy, policy.id).budget_limit_usd, Decimal.new(400))
      assert Decimal.equal?(Costs.spend_posture(company.id).budget_limit, Decimal.new(400))

      assert %GovernanceAuditLog{actor_type: "user", actor_id: actor_id} =
               Repo.get_by(GovernanceAuditLog,
                 company_id: company.id,
                 action_type: "spending_limit_changed"
               )

      assert actor_id == owner.id
    end

    test "a member who is not on the board is refused and nothing changes", %{
      company: company,
      policy: policy
    } do
      member = member!(company, "admin", false)

      assert {:error, :not_board_member} =
               Finances.update_company_limit(company.id, "400", member.id)

      assert Decimal.equal?(Repo.get!(BudgetPolicy, policy.id).budget_limit_usd, Decimal.new(300))
    end

    test "a board member of another company cannot change this one", %{
      company: company,
      policy: policy
    } do
      other = company!()
      outsider = member!(other, "owner", true)
      other_policy = setup_policy!(other, "300.00")

      assert {:error, :not_board_member} =
               Finances.update_company_limit(company.id, "900", outsider.id)

      assert {:ok, _} = Finances.update_company_limit(other.id, "350", outsider.id)
      assert Decimal.equal?(Repo.get!(BudgetPolicy, policy.id).budget_limit_usd, Decimal.new(300))

      assert Decimal.equal?(
               Repo.get!(BudgetPolicy, other_policy.id).budget_limit_usd,
               Decimal.new(350)
             )
    end

    test "only a positive amount is accepted", %{company: company, owner: owner, policy: policy} do
      for bad <- ["0", "-5", "abc", "", nil, "1e999999"] do
        assert {:error, :invalid_limit} = Finances.update_company_limit(company.id, bad, owner.id)
      end

      assert {:ok, updated} = Finances.update_company_limit(company.id, " 250.50 ", owner.id)
      assert Decimal.equal?(updated.budget_limit_usd, Decimal.new("250.50"))
      refute Decimal.equal?(policy.budget_limit_usd, updated.budget_limit_usd)
    end

    test "two company-wide policies are ambiguous: neither changes", %{
      company: company,
      owner: owner,
      policy: policy
    } do
      owned = setup_policy!(company, "500.00")

      assert {:error, :ambiguous} = Finances.update_company_limit(company.id, "450", owner.id)
      assert Decimal.equal?(Repo.get!(BudgetPolicy, policy.id).budget_limit_usd, Decimal.new(300))
      assert Decimal.equal?(Repo.get!(BudgetPolicy, owned.id).budget_limit_usd, Decimal.new(500))
    end

    test "a raise needs a board vote when the company requires one for budget increases", %{
      company: company,
      owner: owner,
      policy: policy
    } do
      {:ok, _} =
        Companies.execute_company_update(company, %{
          governance_config: %{"required_approvals" => ["budget_increase"]}
        })

      assert {:error, :approval_required} =
               Finances.update_company_limit(company.id, "400", owner.id)

      assert Decimal.equal?(Repo.get!(BudgetPolicy, policy.id).budget_limit_usd, Decimal.new(300))

      # Lowering the limit never loosens spend, so it needs no vote.
      assert {:ok, _} = Finances.update_company_limit(company.id, "200", owner.id)
    end

    test "accounting: the hard stop blocks at the old limit and allows after the raise", %{
      company: company,
      owner: owner
    } do
      usage!(company, "300.00")
      issue = %{company_id: company.id}
      agent = %{company_id: company.id, id: Ecto.UUID.generate()}

      assert {:error, {:budget_blocked, %{limit_usd: "300.00"}}} =
               Finances.check_runtime_budget(issue, agent)

      assert {:ok, _} = Finances.update_company_limit(company.id, "400", owner.id)
      assert {:ok, %{status: "available"}} = Finances.check_runtime_budget(issue, agent)

      assert {:ok, _} = Finances.update_company_limit(company.id, "300", owner.id)
      assert {:error, {:budget_blocked, _}} = Finances.check_runtime_budget(issue, agent)
    end

    test "the limit-reached incident is resolved only when spend falls below the new limit", %{
      company: company,
      owner: owner,
      policy: policy
    } do
      usage!(company, "320.00")
      exceeded = incident!(company, policy, "budget_exceeded", "320.00")

      assert {:ok, _} = Finances.update_company_limit(company.id, "310", owner.id)
      assert is_nil(Repo.get!(BudgetIncident, exceeded.id).resolved_at)
      assert Costs.spend_posture(company.id).budget_status == :over_budget

      assert {:ok, _} = Finances.update_company_limit(company.id, "500", owner.id)
      refute is_nil(Repo.get!(BudgetIncident, exceeded.id).resolved_at)
    end

    test "a warning is resolved once spend is under the new warning line", %{
      company: company,
      owner: owner,
      policy: policy
    } do
      usage!(company, "246.00")
      warning = incident!(company, policy, "warning", "246.00")
      assert Costs.spend_posture(company.id, Decimal.new("246")).budget_status == :watch

      # 246 of 305 is still past 80%.
      assert {:ok, _} = Finances.update_company_limit(company.id, "305", owner.id)
      assert is_nil(Repo.get!(BudgetIncident, warning.id).resolved_at)

      assert {:ok, _} = Finances.update_company_limit(company.id, "400", owner.id)
      refute is_nil(Repo.get!(BudgetIncident, warning.id).resolved_at)
      assert Costs.spend_posture(company.id, Decimal.new("246")).budget_status == :on_track
    end

    test "an incident whose hard stop never finished stays open", %{
      company: company,
      owner: owner,
      policy: policy
    } do
      usage!(company, "300.00")
      incident = incident!(company, policy, "budget_exceeded", "300.00", "incomplete")

      assert {:ok, _} = Finances.update_company_limit(company.id, "500", owner.id)
      assert is_nil(Repo.get!(BudgetIncident, incident.id).resolved_at)
    end

    test "does not resume a paused company", %{company: company, owner: owner} do
      {:ok, paused} = Companies.execute_company_update(company, %{status: "paused"})
      assert {:ok, _} = Finances.update_company_limit(paused.id, "500", owner.id)
      assert Companies.get_company!(company.id).status == "paused"
    end
  end

  defp company! do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{name: "Limit Co #{unique}", slug: "limit-#{unique}"})

    company
  end

  defp member!(company, role, board?) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.create_user(%{email: "limit-#{unique}@example.com", name: "Limit #{unique}"})

    {:ok, _} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: role,
        is_board_member: board?
      })

    user
  end

  defp setup_policy!(company, limit) do
    Repo.insert!(%BudgetPolicy{
      company_id: company.id,
      scope: "company",
      period: "monthly",
      budget_limit_usd: Decimal.new(limit),
      warning_threshold_pct: Decimal.new("80.0"),
      action_on_exceed: "block",
      is_active: true
    })
  end

  defp usage!(company, cost) do
    Repo.insert!(%TokenUsage{
      company_id: company.id,
      provider: "claude_code",
      model: "test",
      input_tokens: 10,
      output_tokens: 10,
      total_tokens: 20,
      cost_usd: Decimal.new(cost)
    })
  end

  defp incident!(company, policy, event_type, spend, enforcement \\ "complete") do
    Repo.insert!(%BudgetIncident{
      company_id: company.id,
      budget_policy_id: policy.id,
      event_type: event_type,
      spend_usd: Decimal.new(spend),
      budget_limit_usd: policy.budget_limit_usd,
      threshold_pct: Decimal.new("100"),
      enforcement_status: enforcement
    })
  end
end
