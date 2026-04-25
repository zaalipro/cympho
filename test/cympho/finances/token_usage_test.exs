defmodule Cympho.Finances.TokenUsageTest do
  use Cympho.DataCase, async: true

  alias Cympho.Finances.TokenUsage

  describe "changeset/2" do
    test "valid changeset with required fields" do
      company_id = Ecto.UUID.generate()

      changeset =
        TokenUsage.changeset(%TokenUsage{}, %{
          company_id: company_id,
          provider: "anthropic",
          model: "claude-sonnet-4-6",
          input_tokens: 100,
          output_tokens: 50,
          cost_usd: Decimal.new("0.0015")
        })

      assert changeset.valid?
    end

    test "computes total_tokens from input + output" do
      company_id = Ecto.UUID.generate()

      changeset =
        TokenUsage.changeset(%TokenUsage{}, %{
          company_id: company_id,
          provider: "openai",
          model: "gpt-4",
          input_tokens: 100,
          output_tokens: 50
        })

      assert changeset.valid?
      assert get_field(changeset, :total_tokens) == 150
    end

    test "requires company_id, provider, and model" do
      changeset = TokenUsage.changeset(%TokenUsage{}, %{})

      refute changeset.valid?

      assert %{
               company_id: ["can't be blank"],
               provider: ["can't be blank"],
               model: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "rejects negative token counts" do
      company_id = Ecto.UUID.generate()

      changeset =
        TokenUsage.changeset(%TokenUsage{}, %{
          company_id: company_id,
          provider: "anthropic",
          model: "claude-sonnet-4-6",
          input_tokens: -1
        })

      refute changeset.valid?
    end

    test "optional associations can be set" do
      company_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()
      project_id = Ecto.UUID.generate()

      changeset =
        TokenUsage.changeset(%TokenUsage{}, %{
          company_id: company_id,
          agent_id: agent_id,
          project_id: project_id,
          provider: "anthropic",
          model: "claude-sonnet-4-6"
        })

      assert changeset.valid?
    end
  end
end
