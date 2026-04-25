defmodule Cympho.Secrets.SecretTest do
  use Cympho.DataCase, async: true

  alias Cympho.Secrets.Secret

  describe "changeset/2" do
    test "valid changeset with required fields" do
      company_id = Ecto.UUID.generate()

      changeset =
        Secret.changeset(%Secret{}, %{
          company_id: company_id,
          scope: "company",
          key: "api_key",
          encrypted_value: <<1, 2, 3, 4>>
        })

      assert changeset.valid?
    end

    test "requires company_id, scope, key, and encrypted_value" do
      changeset = Secret.changeset(%Secret{}, %{})

      refute changeset.valid?

      assert %{
               company_id: ["can't be blank"],
               scope: ["can't be blank"],
               key: ["can't be blank"],
               encrypted_value: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates scope inclusion" do
      company_id = Ecto.UUID.generate()

      changeset =
        Secret.changeset(%Secret{}, %{
          company_id: company_id,
          scope: "invalid_scope",
          key: "test",
          encrypted_value: <<1>>
        })

      refute changeset.valid?
    end

    test "requires scope_id for non-company/instance scopes" do
      company_id = Ecto.UUID.generate()

      changeset =
        Secret.changeset(%Secret{}, %{
          company_id: company_id,
          scope: "agent",
          key: "api_key",
          encrypted_value: <<1>>
        })

      refute changeset.valid?
      assert %{scope_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "does not require scope_id for company scope" do
      company_id = Ecto.UUID.generate()

      changeset =
        Secret.changeset(%Secret{}, %{
          company_id: company_id,
          scope: "company",
          key: "api_key",
          encrypted_value: <<1>>
        })

      assert changeset.valid?
    end

    test "does not require scope_id for instance scope" do
      company_id = Ecto.UUID.generate()

      changeset =
        Secret.changeset(%Secret{}, %{
          company_id: company_id,
          scope: "instance",
          key: "encryption_key",
          encrypted_value: <<1>>
        })

      assert changeset.valid?
    end

    test "version must be positive" do
      company_id = Ecto.UUID.generate()

      changeset =
        Secret.changeset(%Secret{}, %{
          company_id: company_id,
          scope: "company",
          key: "test",
          encrypted_value: <<1>>,
          version: 0
        })

      refute changeset.valid?
    end
  end
end
