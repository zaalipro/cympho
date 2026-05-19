defmodule Cympho.Orchestrator.BacklogPlannerTest do
  use Cympho.DataCase, async: false

  alias Cympho.Companies
  alias Cympho.Goals
  alias Cympho.Issues
  alias Cympho.Orchestrator.BacklogPlanner
  alias Cympho.Wakes.AgentWake
  import Ecto.Query

  setup do
    {:ok,
     %{
       company: company,
       agents: [ceo | _],
       goal: goal
     }} =
      Companies.create_autonomous_company(%{
        name: "Planner Co #{System.unique_integer([:positive])}",
        issue_prefix: "PLN",
        engineer_count: 1
      })

    %{company: company, ceo: ceo, goal: goal}
  end

  describe "plan_one_company/2" do
    test "wakes the CEO when company has no in-flight issues but a live mission",
         %{company: company, ceo: ceo, goal: goal} do
      # The seed issues from create_autonomous_company are in :backlog/:todo —
      # which the planner counts as "in flight." Cancel them so we exercise
      # the idle path.
      cancel_all_issues(company.id)

      # Goal must be a mission (top-level). create_autonomous_company sets
      # parent_id=nil, which the changeset auto-promotes to :mission.
      assert goal.goal_type == :mission

      assert %{checked: 1, waked: 1} =
               BacklogPlanner.plan_one_company(company.id, cooldown_ms: 0)

      [wake] = pending_wakes(ceo.id, "mission_idle")
      assert wake.reason == "mission_idle"
      assert wake.metadata["company_id"] == company.id
    end

    test "skips when an issue is in flight", %{company: company} do
      assert %{checked: 1, skipped_busy: 1} =
               BacklogPlanner.plan_one_company(company.id, cooldown_ms: 0)
    end

    test "skips when no active mission exists", %{company: company, goal: goal} do
      cancel_all_issues(company.id)
      {:ok, _} = Goals.update_goal(goal, %{status: "cancelled"})

      assert %{checked: 1, skipped_no_mission: 1} =
               BacklogPlanner.plan_one_company(company.id, cooldown_ms: 0)
    end

    test "respects cooldown — second call within window is a no-op",
         %{company: company, ceo: ceo} do
      cancel_all_issues(company.id)

      assert %{waked: 1} = BacklogPlanner.plan_one_company(company.id, cooldown_ms: 60_000)
      first = pending_wakes(ceo.id, "mission_idle") |> length()

      # Cooldown is 1 minute; immediate retry must not enqueue another wake.
      _ = BacklogPlanner.plan_one_company(company.id, cooldown_ms: 60_000)
      second = pending_wakes(ceo.id, "mission_idle") |> length()

      assert second == first
    end
  end

  describe "ensure_planning_issue/2" do
    test "creates and re-uses a singleton planning issue per company",
         %{company: company, ceo: ceo} do
      {:ok, first} = BacklogPlanner.ensure_planning_issue(company.id, ceo)
      {:ok, second} = BacklogPlanner.ensure_planning_issue(company.id, ceo)

      assert first.id == second.id
      assert first.origin_type == "backlog_planner"
      assert first.assigned_role == "ceo"
    end

    test "resets a planning issue stuck in :in_progress back to :todo",
         %{company: company, ceo: ceo} do
      {:ok, issue} = BacklogPlanner.ensure_planning_issue(company.id, ceo)

      # Simulate the orchestrator having checked it out and then crashed —
      # the next ensure call must clean it up.
      {:ok, _stuck} = Issues.update_issue(issue, %{status: :in_progress})

      {:ok, reset} = BacklogPlanner.ensure_planning_issue(company.id, ceo)
      assert reset.id == issue.id
      assert reset.status == :todo
      assert reset.assignee_id == ceo.id
    end
  end

  ## helpers

  defp cancel_all_issues(company_id) do
    issues =
      Repo.all(
        from i in Cympho.Issues.Issue,
          where: i.company_id == ^company_id
      )

    Enum.each(issues, fn issue ->
      {:ok, _} = Issues.transition_issue(issue, :cancelled)
    end)
  end

  defp pending_wakes(agent_id, reason) do
    Repo.all(
      from w in AgentWake,
        where: w.agent_id == ^agent_id and w.reason == ^reason and w.status == "pending"
    )
  end
end
