defmodule Cympho.R3FixturesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Costs
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.R3Fixtures

  setup do
    %{nw: R3Fixtures.northwind!()}
  end

  test "the ledger reproduces every amount the mockups draw", %{nw: nw} do
    company_id = nw.company.id

    assert agent_costs(Costs.by_agent(company_id, 30, 10)) == %{
             "Ada" => "38.20",
             "Theo" => "41.60",
             "Priya" => "14.90",
             "Jun" => "12.35",
             "Ravi" => "52.80",
             "Mira" => "19.40",
             "Sol" => "7.25"
           }

    assert agent_costs(Costs.by_agent(company_id, 1, 10)) == %{
             "Ada" => "1.06",
             "Theo" => "3.44",
             "Priya" => "0.61",
             "Jun" => "0.47",
             "Ravi" => "5.12",
             "Mira" => "3.68",
             "Sol" => "0.44"
           }

    assert usd(Costs.summary(company_id, 30).total_cost) == "186.50"
    assert usd(Costs.summary(company_id, 1).total_cost) == "14.82"
    refute Costs.summary(company_id, 30).has_unpriced_usage?

    assert Map.new(Costs.by_issue(company_id, 30, 20), &{&1.issue.identifier, usd(&1.total_cost)}) ==
             %{
               "NW-2" => "41.30",
               "NW-1" => "24.60",
               "NW-3" => "22.75",
               "NW-10" => "19.40",
               "NW-9" => "9.80",
               "NW-4" => "9.40",
               "NW-8" => "6.90",
               "NW-6" => "6.85",
               "NW-7" => "5.20",
               "NW-11" => "3.10"
             }

    assert Map.new(Costs.by_provider(company_id, 30), &{&1.provider, usd(&1.total_cost)}) == %{
             "claude_code" => "159.85",
             "codex" => "19.40",
             "openai_chat" => "7.25"
           }

    posture = Costs.spend_posture(company_id, Costs.summary(company_id, 30).total_cost)
    assert posture.budget_used_percent == 62
    assert posture.budget_status == :on_track
    assert usd(posture.budget_limit) == "300.00"
  end

  test "13 runs started in the last 24 hours, one still working", %{nw: nw} do
    since = DateTime.add(nw.anchor, -24 * 3600, :second)

    runs =
      Repo.all(from r in Run, where: r.company_id == ^nw.company.id and r.started_at >= ^since)

    assert length(runs) == 13

    assert Enum.frequencies_by(runs, & &1.status) == %{
             "completed" => 9,
             "failed" => 2,
             "timed_out" => 1,
             "running" => 1
           }
  end

  test "the people, tasks and decisions match the dataset", %{nw: nw} do
    assert nw.company.issue_prefix == "NW"
    assert nw.agents["Mira"].status == :paused
    assert nw.agents["Mira"].paused_by_user_id == nil
    assert nw.agents["Theo"].status == :running

    assert Map.new(nw.issues, fn {id, issue} -> {id, issue.status} end) == %{
             "NW-1" => :done,
             "NW-2" => :done,
             "NW-3" => :done,
             "NW-4" => :in_review,
             "NW-5" => :todo,
             "NW-6" => :blocked,
             "NW-7" => :blocked,
             "NW-8" => :done,
             "NW-9" => :in_review,
             "NW-10" => :blocked,
             "NW-11" => :cancelled
           }

    assert nw.issues["NW-10"].assignee_id == nil
    assert nw.hire.category == "agent_hire" and nw.hire.status == "pending"

    assert [%{"options" => options}] = nw.questions["Q1"].payload["questions"]
    assert length(options) == 3
  end

  defp agent_costs(rows), do: Map.new(rows, &{&1.agent.name, usd(&1.total_cost)})

  defp usd(%Decimal{} = value), do: value |> Decimal.round(2) |> Decimal.to_string(:normal)
end
