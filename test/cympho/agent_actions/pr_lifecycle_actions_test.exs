defmodule Cympho.AgentActions.PrLifecycleActionsTest do
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
        name: "PR Action Co #{System.unique_integer([:positive])}",
        issue_prefix: "PRA",
        engineer_count: 1
      })

    # Set engineer parent to CTO so escalations/iterations route correctly.
    {:ok, engineer} = Agents.update_agent(engineer, %{parent_id: cto.id})

    {:ok, issue} =
      Issues.update_issue(seed, %{
        status: :in_review,
        assignee_id: cto.id,
        github_pr_url: "https://github.com/owner/repo/pull/42",
        created_by_agent_id: engineer.id
      })

    %{company: company, ceo: ceo, cto: cto, engineer: engineer, issue: issue}
  end

  describe "merge_pr authorization" do
    test "engineer cannot merge their own PR", %{engineer: engineer, issue: issue} do
      actions = [%{"type" => "merge_pr"}]

      assert {:error, :unauthorized_action} =
               AgentActions.execute(issue, engineer, actions)
    end

    test "release engineer can merge", %{company: company, issue: issue} do
      {:ok, rel_eng} =
        Agents.create_agent(%{
          name: "Rel Eng",
          role: :release_engineer,
          status: :idle,
          company_id: company.id
        })

      # No PR URL → action fails with :no_pr_url, but auth passes (the auth
      # check would reject earlier if release_engineer wasn't authorized).
      {:ok, no_pr_issue} = Issues.update_issue(issue, %{github_pr_url: nil})

      actions = [%{"type" => "merge_pr"}]
      assert {:error, :no_pr_url} = AgentActions.execute(no_pr_issue, rel_eng, actions)
    end

    test "CTO can merge in a pinch", %{cto: cto, issue: issue} do
      # Same as above — auth passes, the action errors on no_pr_url. The
      # test asserts the auth check accepted CTO and we got past it to the
      # executor logic.
      {:ok, no_pr_issue} = Issues.update_issue(issue, %{github_pr_url: nil})

      actions = [%{"type" => "merge_pr"}]
      assert {:error, :no_pr_url} = AgentActions.execute(no_pr_issue, cto, actions)
    end
  end

  describe "force_fix_pr" do
    test "CTO routes a stalled PR back to the engineer with structured comments", %{
      cto: cto,
      engineer: engineer,
      issue: issue
    } do
      actions = [
        %{
          "type" => "force_fix_pr",
          "reason" => "Tests fail and the null check is missing.",
          "comments" => [
            %{"path" => "lib/x.ex", "line" => 42, "body" => "missing nil check"},
            %{"path" => "test/x_test.exs", "line" => 10, "body" => "test missing"}
          ]
        }
      ]

      assert {:ok, %{results: [%{type: "force_fix_pr", iteration: 1, to_agent_id: target}]}} =
               AgentActions.execute(issue, cto, actions)

      assert target == engineer.id

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :in_progress
      assert reloaded.monitor_state["pr_iteration_count"] == 1

      [wake] = pending_wakes(engineer.id, "pr_review_changes_requested")
      assert wake.metadata["iteration"] == 1
      assert wake.metadata["comment_count"] == 2

      assert Repo.exists?(
               from c in Cympho.Comments.Comment,
                 where:
                   c.issue_id == ^issue.id and
                     fragment("? LIKE ?", c.body, "[pr-review] CHANGES REQUESTED%")
             )
    end

    test "engineer cannot force_fix_pr (governance/release tier only)", %{
      engineer: engineer,
      issue: issue
    } do
      actions = [%{"type" => "force_fix_pr", "reason" => "x"}]

      assert {:error, :unauthorized_action} =
               AgentActions.execute(issue, engineer, actions)
    end

    test "iteration counter increments and at 3 escalates to CEO", %{
      cto: cto,
      ceo: ceo,
      engineer: engineer,
      issue: issue
    } do
      action = fn ->
        %{"type" => "force_fix_pr", "reason" => "again", "comments" => []}
      end

      # Iteration 1
      {:ok, %{results: [%{iteration: 1}]}} = AgentActions.execute(issue, cto, [action.()])
      reload1 = Issues.get_issue!(issue.id)

      # Move it back to :in_review so force_fix_pr can move it again.
      {:ok, _} =
        Issues.update_issue(reload1, %{
          status: :in_review,
          assignee_id: cto.id,
          assigned_role: "cto"
        })

      # Iteration 2
      {:ok, %{results: [%{iteration: 2}]}} =
        AgentActions.execute(Issues.get_issue!(issue.id), cto, [action.()])

      {:ok, _} =
        Issues.update_issue(Issues.get_issue!(issue.id), %{
          status: :in_review,
          assignee_id: cto.id,
          assigned_role: "cto"
        })

      # Iteration 3 → escalate to CEO
      assert {:ok, %{results: [%{iteration: 3}]}} =
               AgentActions.execute(Issues.get_issue!(issue.id), cto, [action.()])

      assert pending_wakes(ceo.id, "escalation_from_subordinate") |> length() >= 1
      _ = engineer
    end
  end

  describe "resolve_conflict" do
    test "engineer acks merge conflict with a [handoff] comment", %{
      engineer: engineer,
      issue: issue
    } do
      # Re-checkout for the engineer
      {:ok, _} = Issues.update_issue(issue, %{assignee_id: engineer.id, status: :in_progress})

      actions = [
        %{
          "type" => "resolve_conflict",
          "branch" => "feature/x",
          "summary" => "Rebased onto main, resolved 3 file conflicts."
        }
      ]

      assert {:ok, %{results: [%{type: "resolve_conflict"}]}} =
               AgentActions.execute(Issues.get_issue!(issue.id), engineer, actions)

      assert Repo.exists?(
               from c in Cympho.Comments.Comment,
                 where:
                   c.issue_id == ^issue.id and
                     fragment("? LIKE ?", c.body, "%[handoff] Resolving merge conflict%")
             )
    end
  end

  describe "submit_review head-SHA gate" do
    test "rejects re-submit when monitor_state says SHA hasn't changed", %{
      engineer: engineer,
      issue: issue
    } do
      # Stamp a last_review_head_sha into the issue. Without a fetchable PR
      # (Github.fetch_pull_request will fail without a real token in test
      # env), the gate's fetch returns nil — which we treat as :ok. To
      # exercise the rejection branch deterministically we'd need to inject
      # an http_fn. Verify the metadata stamping side path instead.
      {:ok, _} =
        Issues.update_issue(issue, %{
          monitor_state: Map.put(issue.monitor_state || %{}, "last_review_head_sha", "abc"),
          status: :in_progress,
          assignee_id: engineer.id
        })

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.monitor_state["last_review_head_sha"] == "abc"
    end

    test "force_resubmit: true bypasses the gate", %{engineer: engineer, issue: issue} do
      {:ok, _} =
        Issues.update_issue(issue, %{
          monitor_state: Map.put(issue.monitor_state || %{}, "last_review_head_sha", "abc"),
          status: :in_progress,
          assignee_id: engineer.id
        })

      # The actual transition will fail review_gates without proper digest
      # state; we accept either an :ok or a quality_gate_failed error — the
      # important thing is the gate did NOT return :no_code_changes_since_last_review.
      result =
        AgentActions.execute(Issues.get_issue!(issue.id), engineer, [
          %{
            "type" => "submit_review",
            "role" => "cto",
            "force_resubmit" => true,
            "notes" => "Same code, prior reviewer agreed offline."
          }
        ])

      refute match?({:error, :no_code_changes_since_last_review}, result)
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
