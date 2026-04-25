defmodule Cympho.Finances.BillerTest do
  use Cympho.DataCase, async: true

  alias Cympho.Finances.Biller

  describe "changeset/2" do
    test "valid changeset with required fields" do
      company_id = Ecto.UUID.generate()

      changeset =
        Biller.changeset(%Biller{}, %{
          company_id: company_id,
          name: "AWS Bedrock",
          provider: "aws"
        })

      assert changeset.valid?
    end

    test "requires company_id, name, and provider" do
      changeset = Biller.changeset(%Biller{}, %{})

      refute changeset.valid?

      assert %{
               company_id: ["can't be blank"],
               name: ["can't be blank"],
               provider: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates billing_cycle inclusion" do
      company_id = Ecto.UUID.generate()

      changeset =
        Biller.changeset(%Biller{}, %{
          company_id: company_id,
          name: "Test",
          provider: "test",
          billing_cycle: "hourly"
        })

      refute changeset.valid?
    end

    test "billing_day must be between 1 and 31" do
      company_id = Ecto.UUID.generate()

      changeset =
        Biller.changeset(%Biller{}, %{
          company_id: company_id,
          name: "Test",
          provider: "test",
          billing_day: 32
        })

      refute changeset.valid?
    end
  end
end
