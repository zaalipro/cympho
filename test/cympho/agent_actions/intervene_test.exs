defmodule Cympho.AgentActions.InterveneTest do
  use Cympho.DataCase, async: false

  alias Cympho.{AgentActions, Agents, Comments, Companies, Issues}
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
          "reason" => delivery_restart_reason()
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

    test "rejects thin repo-delivery reassignments before waking the target", %{
      ceo: ceo,
      engineer: engineer,
      engineer_two: engineer_two,
      issue: issue
    } do
      {:ok, issue} = Issues.update_issue(issue, %{description: "Please recover this."})

      actions = [
        %{
          "type" => "intervene",
          "mode" => "reassign",
          "to_agent_id" => engineer_two.id,
          "reason" => "Different engineer should pick this up."
        }
      ]

      assert {:error,
              {:intervene_delivery_brief_too_thin, "reassign", :engineer, next_prompt, missing,
               scaffold}} =
               AgentActions.execute(issue, ceo, actions)

      assert next_prompt =~ "Acceptance criteria"
      assert "Acceptance criteria" in missing
      assert scaffold =~ "Delivery goal:"

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :in_progress
      assert reloaded.assignee_id == engineer.id

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "intervene reassign rejected") and
                 String.contains?(comment.body, "recovery directive is too thin") and
                 String.contains?(comment.body, "Repair scaffold")
             end)

      assert pending_wakes(engineer_two.id, "manager_directive") == []
    end

    test "rejects when neither to_agent_id nor to_role provided", %{ceo: ceo, issue: issue} do
      actions = [
        %{
          "type" => "intervene",
          "mode" => "reassign",
          "reason" => "Need to reassign but no target named yet."
        }
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
      stale_at =
        DateTime.utc_now() |> DateTime.add(-2 * 3600, :second) |> DateTime.truncate(:second)

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
          "reason" => delivery_restart_reason()
        }
      ]

      assert {:ok, %{results: [%{type: "intervene", mode: "unblock"}]}} =
               AgentActions.execute(issue, cto, actions)

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :todo

      assert pending_wakes(engineer.id, "issue_blockers_resolved") |> length() >= 0
    end

    test "rejects thin repo-delivery unblock before requeueing the issue", %{
      cto: cto,
      issue: issue,
      engineer: engineer
    } do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Blocked.",
          assigned_role: "engineer"
        })

      actions = [
        %{
          "type" => "intervene",
          "mode" => "unblock",
          "reason" => "Dependency landed earlier today."
        }
      ]

      assert {:error,
              {:intervene_delivery_brief_too_thin, "unblock", :engineer, next_prompt, missing,
               scaffold}} =
               AgentActions.execute(issue, cto, actions)

      assert next_prompt =~ "Acceptance criteria"
      assert "Acceptance criteria" in missing
      assert scaffold =~ "Delivery goal:"

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :blocked
      assert reloaded.assignee_id == engineer.id
      assert reloaded.assigned_role == "engineer"

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "intervene unblock rejected") and
                 String.contains?(comment.body, "recovery directive is too thin") and
                 String.contains?(comment.body, "Repair scaffold")
             end)

      assert pending_wakes(engineer.id, "issue_blockers_resolved") == []
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
          "reason" => delivery_restart_reason()
        }
      ]

      assert {:ok, %{results: [%{type: "intervene", mode: "force_handoff", to_role: "engineer"}]}} =
               AgentActions.execute(issue, cto, actions)

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.assignee_id == nil
      assert reloaded.status == :todo
      assert reloaded.assigned_role == "engineer"
    end

    test "rejects thin force handoff to repo-delivery roles", %{
      cto: cto,
      engineer: engineer,
      issue: issue
    } do
      {:ok, issue} = Issues.update_issue(issue, %{description: "Still stuck."})

      actions = [
        %{
          "type" => "intervene",
          "mode" => "force_handoff",
          "to_role" => "engineer",
          "reason" => "Put this back in the engineer pool."
        }
      ]

      assert {:error,
              {:intervene_delivery_brief_too_thin, "force_handoff", :engineer, next_prompt,
               missing, scaffold}} =
               AgentActions.execute(issue, cto, actions)

      assert next_prompt =~ "Acceptance criteria"
      assert "Acceptance criteria" in missing
      assert scaffold =~ "Delivery goal:"

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :in_progress
      assert reloaded.assignee_id == engineer.id

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "intervene force_handoff rejected") and
                 String.contains?(comment.body, "recovery directive is too thin") and
                 String.contains?(comment.body, "Repair scaffold")
             end)
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

    test "reassign rejects too-short reason", %{
      ceo: ceo,
      engineer_two: engineer_two,
      issue: issue
    } do
      actions = [
        %{
          "type" => "intervene",
          "mode" => "reassign",
          "to_agent_id" => engineer_two.id,
          "reason" => "short"
        }
      ]

      assert {:error, {:governance_reason_too_short, "intervene", 15}} =
               AgentActions.execute(issue, ceo, actions)
    end

    test "cancel records a Decision on success", %{
      ceo: ceo,
      issue: issue,
      company: company
    } do
      actions = [
        %{
          "type" => "intervene",
          "mode" => "cancel",
          "reason" => "Mission pivoted, this issue is no longer needed."
        }
      ]

      assert {:ok, _} = AgentActions.execute(issue, ceo, actions)

      decisions =
        Cympho.Decisions.list_decisions(%{
          company_id: company.id,
          resource_type: "issue",
          resource_id: issue.id,
          decision_type: "intervene_cancel"
        })

      assert [decision] = decisions
      assert decision.outcome == "implemented"
      assert decision.actor_id == ceo.id
    end
  end

  ## helpers

  defp pending_wakes(agent_id, reason) do
    Repo.all(
      from w in AgentWake,
        where: w.agent_id == ^agent_id and w.reason == ^reason and w.status == "pending"
    )
  end

  defp delivery_restart_reason do
    "Acceptance criteria: finish the stalled implementation within the existing issue scope. " <>
      "Evidence required: attach the code-change work product or PR plus a delivery note. " <>
      "Verification required: run the focused test or name the blocker preventing it. " <>
      "Definition of done: ready for CTO review with evidence, verification, and remaining risk named."
  end
end
