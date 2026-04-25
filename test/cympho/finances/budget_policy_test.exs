defmodule Cympho.Finances.BudgetPolicyTest do
  use Cympho.DataCase, async: true

  alias Cympho.Finances.BudgetPolicy

  describe "changeset/2" do
    test "valid changeset for company-scoped policy" do
      company_id = Ecto.UUID.generate()

      changeset =
        BudgetPolicy.changeset(%BudgetPolicy{}, %{
          company_id: company_id,
          scope: "company",
          budget_limit_usd: Decimal.new("1000.00"),
          warning_threshold_pct: Decimal.new("80.0"),
          action_on_exceed: "warn"
        })

      assert changeset.valid?
    end

    test "valid changeset for agent-scoped policy" do
      company_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()

      changeset =
        BudgetPolicy.changeset(%BudgetPolicy{}, %{
          company_id: company_id,
          scope: "agent",
          scope_id: agent_id,
          budget_limit_usd: Decimal.new("500.00")
        })

      assert changeset.valid?
    end

    test "requires scope_id for non-company scopes" do
      company_id = Ecto.UUID.generate()

      changeset =
        BudgetPolicy.changeset(%BudgetPolicy{}, %{
          company_id: company_id,
          scope: "agent",
          budget_limit_usd: Decimal.new("500.00")
        })

      refute changeset.valid?
      assert %{scope_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "does not require scope_id for company scope" do
      company_id = Ecto.UUID.generate()

      changeset =
        BudgetPolicy.changeset(%BudgetPolicy{}, %{
          company_id: company_id,
          scope: "company",
          budget_limit_usd: Decimal.new("1000.00")
        })

      assert changeset.valid?
    end

    test "validates scope inclusion" do
      company_id = Ecto.UUID.generate()

      changeset =
        BudgetPolicy.changeset(%BudgetPolicy{}, %{
          company_id: company_id,
          scope: "invalid_scope",
          budget_limit_usd: Decimal.new("100.00")
        })

      refute changeset.valid?
    end

    test "validates period inclusion" do
      company_id = Ecto.UUID.generate()

      changeset =
        BudgetPolicy.changeset(%BudgetPolicy{}, %{
          company_id: company_id,
          scope: "company",
          period: "yearly_invalid",
          budget_limit_usd: Decimal.new("100.00")
        })

      refute changeset.valid?
    end

    test "budget limit must be positive" do
      company_id = Ecto.UUID.generate()

      changeset =
        BudgetPolicy.changeset(%BudgetPolicy{}, %{
          company_id: company_id,
          scope: "company",
          budget_limit_usd: Decimal.new("0")
        })

      refute changeset.valid?
    end

    test "warning threshold must be between 0 and 100" do
      company_id = Ecto.UUID.generate()

      changeset =
        BudgetPolicy.changeset(%BudgetPolicy{}, %{
          company_id: company_id,
          scope: "company",
          budget_limit_usd: Decimal.new("100.00"),
          warning_threshold_pct: Decimal.new("150.0")
        })

      refute changeset.valid?
    end
  end
end
