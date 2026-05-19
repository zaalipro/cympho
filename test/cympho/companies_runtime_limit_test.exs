defmodule Cympho.CompaniesRuntimeLimitTest do
  use Cympho.DataCase, async: true

  alias Cympho.Companies

  test "returns default when company has no limits configured" do
    {:ok, company} =
      Companies.create_company(%{
        name: "RL Co #{System.unique_integer([:positive])}",
        slug: "rl-#{System.unique_integer([:positive])}"
      })

    assert Companies.runtime_limit(company, "max_concurrent_runs", 3) == 3
    assert Companies.runtime_limit(company, "max_request_depth", 5) == 5
  end

  test "returns configured limit when present" do
    {:ok, company} =
      Companies.create_company(%{
        name: "RL Co #{System.unique_integer([:positive])}",
        slug: "rl-#{System.unique_integer([:positive])}",
        governance_config: %{"limits" => %{"max_concurrent_runs" => 8}}
      })

    assert Companies.runtime_limit(company, "max_concurrent_runs", 3) == 8
    # Other keys still fall through.
    assert Companies.runtime_limit(company, "max_request_depth", 5) == 5
  end

  test "ignores invalid (non-positive integer) values" do
    {:ok, company} =
      Companies.create_company(%{
        name: "RL Co #{System.unique_integer([:positive])}",
        slug: "rl-#{System.unique_integer([:positive])}",
        governance_config: %{"limits" => %{"max_request_depth" => "not a number"}}
      })

    assert Companies.runtime_limit(company, "max_request_depth", 5) == 5
  end

  test "accepts nil and binary id" do
    assert Companies.runtime_limit(nil, "anything", 99) == 99
    assert Companies.runtime_limit("not-a-real-id", "anything", 42) == 42
  end
end
