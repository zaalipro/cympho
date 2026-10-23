defmodule Cympho.R3ReadsTest do
  use Cympho.DataCase, async: true

  alias Cympho.Activities
  alias Cympho.Costs
  alias Cympho.Finances.TokenUsage
  alias Cympho.Issues
  alias Cympho.R3Fixtures

  setup do
    %{nw: R3Fixtures.northwind!(), other: R3Fixtures.northwind!()}
  end

  describe "Issues.list_completed_since/2" do
    test "lists the company's tasks finished since a time, newest first", %{nw: nw} do
      since = DateTime.add(nw.anchor, -24 * 3600, :second)

      assert nw.company.id |> Issues.list_completed_since(since) |> Enum.map(& &1.id) ==
               [nw.issues["NW-8"].id, nw.issues["NW-3"].id]
    end

    test "leaves out cancelled tasks", %{nw: nw} do
      since = DateTime.add(nw.anchor, -7 * 24 * 3600, :second)

      identifiers =
        nw.company.id |> Issues.list_completed_since(since) |> Enum.map(& &1.identifier)

      assert identifiers == ["NW-8", "NW-3", "NW-2", "NW-1"]
      refute "NW-11" in identifiers
    end
  end

  describe "Costs.issue_total/2" do
    test "sums a task's spend over its whole life", %{nw: nw} do
      assert Decimal.equal?(Costs.issue_total(nw.company.id, nw.issues["NW-6"].id), "6.85")
      assert Decimal.equal?(Costs.issue_total(nw.company.id, nw.issues["NW-5"].id), "0")
    end

    test "sums only the company's own rows", %{nw: nw, other: other} do
      Repo.insert!(%TokenUsage{
        company_id: other.company.id,
        agent_id: other.agents["Ravi"].id,
        issue_id: nw.issues["NW-6"].id,
        provider: "claude_code",
        model: "unknown",
        cost_usd: Decimal.new("100.00")
      })

      assert Decimal.equal?(Costs.issue_total(nw.company.id, nw.issues["NW-6"].id), "6.85")
      assert Decimal.equal?(Costs.issue_total(other.company.id, nw.issues["NW-4"].id), "0")
    end
  end

  describe "Costs.unattributed_total/2" do
    test "sums spend not tied to a task", %{nw: nw} do
      assert Decimal.equal?(Costs.unattributed_total(nw.company.id, 30), "37.20")
      assert Decimal.equal?(Costs.unattributed_total(nw.company.id, 1), "0.94")
    end
  end

  describe "Activities.previous_assignee_id/1" do
    test "returns who held a task before a pause rehomed it", %{nw: nw} do
      assert Activities.previous_assignee_id(nw.issues["NW-10"].id) == nw.agents["Mira"].id
    end

    test "returns nil when the task was never rehomed", %{nw: nw} do
      assert Activities.previous_assignee_id(nw.issues["NW-6"].id) == nil
    end
  end
end
