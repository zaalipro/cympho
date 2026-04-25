defmodule Cympho.Finances.BudgetIncidentTest do
  use Cympho.DataCase, async: true

  alias Cympho.Finances.BudgetIncident

  describe "changeset/2" do
    test "valid changeset with required fields" do
      policy_id = Ecto.UUID.generate()
      company_id = Ecto.UUID.generate()

      changeset =
        BudgetIncident.changeset(%BudgetIncident{}, %{
          budget_policy_id: policy_id,
          company_id: company_id,
          event_type: "warning",
          spend_usd: Decimal.new("80.00"),
          budget_limit_usd: Decimal.new("100.00")
        })

      assert changeset.valid?
    end

    test "requires all mandatory fields" do
      changeset = BudgetIncident.changeset(%BudgetIncident{}, %{})

      refute changeset.valid?

      assert %{
               budget_policy_id: ["can't be blank"],
               company_id: ["can't be blank"],
               event_type: ["can't be blank"],
               spend_usd: ["can't be blank"],
               budget_limit_usd: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates event_type inclusion" do
      policy_id = Ecto.UUID.generate()
      company_id = Ecto.UUID.generate()

      changeset =
        BudgetIncident.changeset(%BudgetIncident{}, %{
          budget_policy_id: policy_id,
          company_id: company_id,
          event_type: "invalid_event",
          spend_usd: Decimal.new("80.00"),
          budget_limit_usd: Decimal.new("100.00")
        })

      refute changeset.valid?
    end
  end

  describe "resolve_changeset/2" do
    test "valid changeset with resolved_at" do
      incident = %BudgetIncident{resolved_at: nil}

      changeset =
        BudgetIncident.resolve_changeset(incident, %{
          resolved_at: DateTime.utc_now()
        })

      assert changeset.valid?
    end

    test "requires resolved_at" do
      changeset = BudgetIncident.resolve_changeset(%BudgetIncident{}, %{})
      refute changeset.valid?
    end
  end
end
