defmodule Cympho.SecretsKeyNamesTest do
  @moduledoc "Which keys an agent can use, as names only (plan P3 [query])."
  use Cympho.DataCase, async: true

  alias Cympho.R3Fixtures
  alias Cympho.Secrets

  setup do
    %{nw: R3Fixtures.northwind!(), other: R3Fixtures.northwind!()}
  end

  test "lists the company's keys and the agent's own, names only", %{nw: nw} do
    mira = nw.agents["Mira"]

    {:ok, _} =
      Secrets.create_secret(%{
        company_id: nw.company.id,
        scope: "agent",
        scope_id: mira.id,
        key: "MIRA_TOKEN",
        value: "mira-token-sentinel"
      })

    names = Secrets.key_names_for_agent(mira)

    assert names == ["MIRA_TOKEN", "OPENAI_API_KEY"]
    assert Enum.all?(names, &is_binary/1)
    refute inspect(names) =~ "sentinel"
    refute inspect(names) =~ "sk-northwind-demo"

    assert Secrets.key_names_for_agent(nw.agents["Ravi"]) == ["OPENAI_API_KEY"]
  end

  test "never returns another company's keys or inactive ones", %{nw: nw, other: other} do
    {:ok, _} =
      Secrets.create_secret(%{
        company_id: other.company.id,
        scope: "company",
        key: "OTHER_COMPANY_KEY",
        value: "other-value"
      })

    {:ok, retired} =
      Secrets.create_secret(%{
        company_id: nw.company.id,
        scope: "company",
        key: "RETIRED_KEY",
        value: "retired-value"
      })

    Repo.update!(Ecto.Changeset.change(retired, is_active: false))

    assert Secrets.key_names_for_agent(nw.agents["Mira"]) == ["OPENAI_API_KEY"]
  end
end
