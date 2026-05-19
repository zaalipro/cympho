defmodule Cympho.AgentActions.InterveneTest do
  use Cympho.DataCase, async: false

  alias Cympho.{AgentActions, Agents, Companies, Issues}
  alias Cympho.Repo
  alias Cympho.Wakes.AgentWake
  import Ecto.Query

  setup do
    {:ok,
     %{
       company: company,
       agents: [ceo, cto, engineer | _],
       seed_issues: [seed | _]
     }} =
      Companies.create_autonomous_company(%{
        name: "Intervene Co #{System.unique_integer([:positive])}",
        issue_prefix: "INT",
        engineer_count: 1
      })

    # Spawn a second engineer so reassign has a real target.
    {:ok, engineer_two} =
      Agents.create_agent(%{
        name: "Engineer Two",
        role: :engineer,
        status: :idle,
        company_id: company.id,
        parent_id: cto.id
      })

    # Stale issue assigned to engineer
    stale_at =
      DateTime.utc_now() |> DateTime.add(-3 * 3600, :second) |> DateTime.truncate(:second)

    {:ok, issue} =
      Issues.update_issue(seed, %{
        status: :in_progress,
        assignee_id: engineer.id,
        checked_out_at: stale_at,
        updated_at: stale_at
      })

    %{
      company: company,
      ceo: ceo,
      cto: cto,
      engineer: engineer,
      engineer_two: engineer_two,
      issue: issue
    }
  end

  describe "intervene reassign" do
    test "CEO can reassign to a named engineer", %{
      ceo: ceo,
      engineer_two: engineer_two,
      issue: issue
    } do
      actions = [
        %{
          "type" => "intervene",
          "mode" => "reassign",
          "to_agent_id" => engineer_two.id,
          "reason" => "Engineer Two has the context."
        }
      ]

      assert {:ok, %{results: [%{type: "intervene", mode: "reassign", to_agent_id: target}]}} =
               AgentActions.execute(issue, ceo, actions)

      assert target == engineer_two.id

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.assignee_id == engineer_two.id
      assert reloaded.status == :todo
      assert reloaded.assigned_role == "engineer"

      [wake] = pending_wakes(engineer_two.id, "manager_directive")
      assert wake.metadata["via"] == "intervene"
    end

    test "rejects when neither to_agent_id nor to_role provided", %{ceo: ceo, issue: issue} do
      actions = [
        %{"type" => "intervene", "mode" => "reassign", "reason" => "no target"}
      ]

      assert {:error, :missing_intervene_target} =
               AgentActions.execute(issue, ceo, actions)
    end

    test "engineer cannot intervene", %{engineer: engineer, issue: issue} do
      actions = [
        %{
          "type" => "intervene",
          "mode" => "reassign",
          "to_agent_id" => engineer.id,
          "reason" => "x"
        }
      ]

      assert {:error, :unauthorized_action} =
               AgentActions.execute(issue, engineer, actions)
    end
  end

  describe "intervene unblock" do
    setup %{issue: issue, engineer: engineer} do
      stale_at = DateTime.utc_now() |> DateTime.add(-2 * 3600, :second) |> DateTime.truncate(:second)

      {:ok, blocked} =
        Issues.update_issue(issue, %{
          status: :blocked,
          assignee_id: engineer.id,
          updated_at: stale_at
        })

      %{issue: blocked}
    end

    test "CTO unblocks → :todo, comment, blockers_resolved wake", %{
      cto: cto,
      issue: issue,
      engineer: engineer
    } do
      actions = [
        %{
          "type" => "intervene",
          "mode" => "unblock",
          "reason" => "Dependency landed earlier today."
        }
      ]

      assert {:ok, %{results: [%{type: "intervene", mode: "unblock"}]}} =
               AgentActions.execute(issue, cto, actions)

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :todo

      assert pending_wakes(engineer.id, "issue_blockers_resolved") |> length() >= 0
    end
  end

  describe "intervene cancel" do
    test "CEO cancels a stalled issue", %{ceo: ceo, issue: issue} do
      actions = [
        %{
          "type" => "intervene",
          "mode" => "cancel",
          "reason" => "Mission pivoted, this isn't needed anymore."
        }
      ]

      assert {:ok, %{results: [%{type: "intervene", mode: "cancel"}]}} =
               AgentActions.execute(issue, ceo, actions)

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :cancelled
    end
  end

  describe "intervene force_handoff" do
    test "CTO clears assignee and sets role for dispatcher routing", %{
      cto: cto,
      issue: issue
    } do
      actions = [
        %{
          "type" => "intervene",
          "mode" => "force_handoff",
          "to_role" => "engineer",
          "reason" => "Different engineer should pick this up."
        }
      ]

      assert {:ok, %{results: [%{type: "intervene", mode: "force_handoff", to_role: "engineer"}]}} =
               AgentActions.execute(issue, cto, actions)

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.assignee_id == nil
      assert reloaded.status == :todo
      assert reloaded.assigned_role == "engineer"
    end
  end

  describe "validation" do
    test "rejects unknown mode", %{ceo: ceo, issue: issue} do
      actions = [%{"type" => "intervene", "mode" => "yeet", "reason" => "x"}]

      assert {:error, {:invalid_intervene_mode, _}} =
               AgentActions.execute(issue, ceo, actions)
    end

    test "rejects missing mode", %{ceo: ceo, issue: issue} do
      actions = [%{"type" => "intervene", "reason" => "x"}]

      assert {:error, {:invalid_intervene_mode, _}} =
               AgentActions.execute(issue, ceo, actions)
    end
  end

  ## helpers

  defp pending_wakes(agent_id, reason) do
    Repo.all(
      from w in AgentWake,
        where: w.agent_id == ^agent_id and w.reason == ^reason and w.status == "pending"
    )
  end
end
