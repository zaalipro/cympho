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

  test "a review waiting on a task counts for the task's assignee, not the reviewer", %{
    company: company
  } do
    {:ok, ada} =
      Agents.create_agent(%{name: "Ada", role: :ceo, status: :idle, company_id: company.id})

    {:ok, ravi} =
      Agents.create_agent(%{name: "Ravi", role: :engineer, status: :idle, company_id: company.id})

    {:ok, task} =
      Cympho.Issues.create_issue(%{
        title: "First core feature",
        status: :in_review,
        assignee_id: ravi.id,
        company_id: company.id
      })

    # The review wake belongs to the CEO (an unassigned root task's reviewer).
    Repo.insert!(%Cympho.Wakes.AgentWake{
      agent_id: ada.id,
      issue_id: task.id,
      reason: "final_review_required",
      status: "pending",
      triggered_by_type: "system"
    })

    chips = Map.new(TeamRail.rows(company.id, nil), &{&1.name, &1.for_you})

    assert chips["Ravi"] == 1
    assert chips["Ada"] == 0
  end

  describe "spending/1, the one spend read of the rail slot and Home" do
    test "the spend of the limit's window against the limit", %{company: company} do
      spend!(company, "300", "186.50")

      assert %{
               spent: spent,
               limit: limit,
               days: 30,
               percent: percent,
               used_percent: 62,
               warn_percent: 80,
               status: :on_track
             } = TeamRail.spending(company.id)

      assert Decimal.equal?(spent, Decimal.new("186.50"))
      assert Decimal.equal?(limit, Decimal.new("300"))
      assert_in_delta percent, 62.17, 0.01
      assert TeamRail.spend(company.id) == nil
    end

    test "without a limit there is no limit and no slot", %{company: company} do
      assert %{limit: nil, percent: nil, used_percent: nil} = TeamRail.spending(company.id)
      assert TeamRail.spend(company.id) == nil
    end
  end

  defp spend!(company, limit, spent) do
    %Cympho.Finances.BudgetPolicy{}
    |> Cympho.Finances.BudgetPolicy.changeset(%{
      company_id: company.id,
      scope: "company",
      period: "monthly",
      budget_limit_usd: Decimal.new(limit),
      warning_threshold_pct: Decimal.new("80.0")
    })
    |> Repo.insert!()

    Repo.insert!(%Cympho.Finances.TokenUsage{
      company_id: company.id,
      provider: "test",
      model: "test",
      input_tokens: 100,
      output_tokens: 50,
      total_tokens: 150,
      cost_usd: Decimal.new(spent)
    })
  end
end
