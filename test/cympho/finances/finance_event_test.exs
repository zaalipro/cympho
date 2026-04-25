defmodule Cympho.Finances.FinanceEventTest do
  use Cympho.DataCase, async: true

  alias Cympho.Finances.FinanceEvent

  describe "changeset/2" do
    test "valid changeset with required fields" do
      company_id = Ecto.UUID.generate()

      changeset =
        FinanceEvent.changeset(%FinanceEvent{}, %{
          company_id: company_id,
          event_type: "token_usage",
          amount_usd: Decimal.new("0.05")
        })

      assert changeset.valid?
    end

    test "requires company_id, event_type, and amount_usd" do
      changeset = FinanceEvent.changeset(%FinanceEvent{}, %{})

      refute changeset.valid?

      assert %{
               company_id: ["can't be blank"],
               event_type: ["can't be blank"],
               amount_usd: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates event_type inclusion" do
      company_id = Ecto.UUID.generate()

      changeset =
        FinanceEvent.changeset(%FinanceEvent{}, %{
          company_id: company_id,
          event_type: "invalid_type",
          amount_usd: Decimal.new("0.05")
        })

      refute changeset.valid?
    end

    test "amount must be non-negative" do
      company_id = Ecto.UUID.generate()

      changeset =
        FinanceEvent.changeset(%FinanceEvent{}, %{
          company_id: company_id,
          event_type: "charge",
          amount_usd: Decimal.new("-1.00")
        })

      refute changeset.valid?
    end

    test "currency must be 3 characters" do
      company_id = Ecto.UUID.generate()

      changeset =
        FinanceEvent.changeset(%FinanceEvent{}, %{
          company_id: company_id,
          event_type: "charge",
          amount_usd: Decimal.new("1.00"),
          currency: "US"
        })

      refute changeset.valid?
    end
  end
end
