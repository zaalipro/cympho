defmodule Cympho.HeartbeatEngineTeamReadsTest do
  @moduledoc "The run reads behind the r3 Team and Agent pages (plan P3, P6)."
  use Cympho.DataCase, async: true

  alias Cympho.HeartbeatEngine
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.R3Fixtures

  setup do
    %{nw: R3Fixtures.northwind!(), other: R3Fixtures.northwind!()}
  end

  describe "latest_runs_by_agent/1" do
    test "gives each agent its running run, else its newest, with the task", %{nw: nw} do
      runs = HeartbeatEngine.latest_runs_by_agent(nw.company.id)

      theo = runs[nw.agents["Theo"].id]
      assert theo.status == "running"
      assert theo.issue.identifier == "NW-9"

      mira = runs[nw.agents["Mira"].id]
      assert mira.id == nw.runs[8].id
      assert mira.issue.identifier == "NW-10"

      assert runs[nw.agents["Sol"].id].id == nw.runs[5].id
      assert runs[nw.agents["Ravi"].id].id == nw.runs[10].id
      assert map_size(runs) == 7
    end

    test "a running run wins over a newer finished one", %{nw: nw} do
      theo = nw.agents["Theo"]

      Repo.insert!(%Run{
        company_id: nw.company.id,
        agent_id: theo.id,
        issue_id: nw.issues["NW-3"].id,
        status: "completed",
        adapter: "claude_code",
        started_at: R3Fixtures.at(nw.anchor, 5),
        completed_at: R3Fixtures.at(nw.anchor, 2),
        inserted_at: R3Fixtures.at(nw.anchor, 5)
      })

      assert HeartbeatEngine.latest_runs_by_agent(nw.company.id)[theo.id].status == "running"
    end

    test "never lists another company's runs", %{nw: nw, other: other} do
      ids = nw.company.id |> HeartbeatEngine.latest_runs_by_agent() |> Map.keys()

      refute Enum.any?(other.agents, fn {_name, agent} -> agent.id in ids end)
    end
  end

  describe "runs in a window" do
    test "count_runs_since/2 counts the company's runs started since then", %{nw: nw} do
      since = DateTime.add(nw.anchor, -24 * 3600, :second)

      assert HeartbeatEngine.count_runs_since(nw.company.id, since) == 13
    end

    test "list_runs_since/3 lists them newest first with agent and task, capped", %{
      nw: nw,
      other: other
    } do
      since = DateTime.add(nw.anchor, -24 * 3600, :second)

      runs = HeartbeatEngine.list_runs_since(nw.company.id, since, limit: 20)

      assert length(runs) == 13
      assert hd(runs).id == nw.runs[14].id
      assert List.last(runs).id == nw.runs[2].id
      assert hd(runs).agent.name == "Theo"
      assert hd(runs).issue.identifier == "NW-9"
      refute Enum.any?(runs, &(&1.company_id == other.company.id))

      assert length(HeartbeatEngine.list_runs_since(nw.company.id, since, limit: 4)) == 4
    end
  end

  describe "issue_spend_for_agent/4" do
    test "sums the agent's whole-life spend on the task", %{nw: nw} do
      mira = nw.agents["Mira"]
      nw10 = nw.issues["NW-10"]

      assert Decimal.equal?(
               HeartbeatEngine.issue_spend_for_agent(nw.company.id, mira.id, nw10.id),
               "19.40"
             )
    end

    test "leaves out the spend of the runs already shown", %{nw: nw} do
      mira = nw.agents["Mira"]
      shown = Enum.map([6, 7, 8], &nw.runs[&1].id)

      spend =
        HeartbeatEngine.issue_spend_for_agent(
          nw.company.id,
          mira.id,
          nw.issues["NW-10"].id,
          shown
        )

      assert Decimal.equal?(spend, "15.72")
    end

    test "is zero for another company", %{nw: nw, other: other} do
      spend =
        HeartbeatEngine.issue_spend_for_agent(
          other.company.id,
          nw.agents["Mira"].id,
          nw.issues["NW-10"].id
        )

      assert Decimal.equal?(spend, 0)
    end
  end
end
