defmodule Cympho.Budgets.BudgetTest do
  use Cympho.DataCase, async: true

  alias Cympho.Budgets.Budget

  describe "changeset/2 amount validation" do
    test "rejects a negative limit when spent amount uses its default" do
      changeset =
        Budget.changeset(%Budget{}, %{
          name: "Invalid limit",
          scope_type: "custom",
          limit_amount: Decimal.new("-1")
        })

      assert "must be greater than or equal to 0" in errors_on(changeset).limit_amount
    end

    test "rejects a negative spent amount independently of the limit" do
      changeset =
        Budget.changeset(%Budget{}, %{
          name: "Invalid spend",
          scope_type: "custom",
          limit_amount: Decimal.new("10"),
          spent_amount: Decimal.new("-1")
        })

      assert "must be greater than or equal to 0" in errors_on(changeset).spent_amount
    end
  end
end
