defmodule CymphoWeb.TeamRailTest do
  use Cympho.DataCase, async: true

  alias Cympho.Agents
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Repo
  alias CymphoWeb.TeamRail

  setup do
    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Rail Co",
        slug: "rail-co-#{System.unique_integer([:positive])}"
      })

    {:ok, theo} =
      Agents.create_agent(%{name: "Theo", role: :cto, status: :running, company_id: company.id})

    {:ok, issue} =
      Cympho.Issues.create_issue(%{
        title: "Design empty states",
        status: :in_review,
        company_id: company.id
      })

    Repo.insert!(%Run{
      company_id: company.id,
      agent_id: theo.id,
      issue_id: issue.id,
      status: "running",
      started_at: DateTime.utc_now() |> DateTime.add(-28 * 60) |> DateTime.truncate(:second)
    })

    %{company: company, issue: issue}
  end

  test "the rail rows leave out what a Working agent is doing", %{company: company} do
    assert [%{name: "Theo", kind: :working, word: "Working", detail: nil}] =
             TeamRail.rows(company.id, nil)
  end

  test "on request, a Working row says what the agent is doing and for how long", %{
    company: company,
    issue: issue
  } do
    assert [%{detail: detail}] = TeamRail.rows(company.id, nil, detail: true)
    assert detail == "reviewing #{issue.identifier} · 28 min"
  end
end
