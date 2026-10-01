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

    test "respects cooldown — second call within window is a cooldown skip",
         %{company: company, ceo: ceo} do
      cancel_all_issues(company.id)

      assert %{checked: 1, waked: 1} =
               BacklogPlanner.plan_one_company(company.id, cooldown_ms: 60_000)

      first = pending_wakes(ceo.id, "mission_idle") |> length()
      assert first == 1

      # Cooldown is 1 minute; immediate retry must not enqueue another wake and must report skipped_cooldown.
      result = BacklogPlanner.plan_one_company(company.id, cooldown_ms: 60_000)
      assert %{checked: 1, skipped_cooldown: 1} = result
      refute Map.has_key?(result, :waked)

      second = pending_wakes(ceo.id, "mission_idle") |> length()
      assert second == 1
    end

    test "records errors and does not count as waked when enqueue fails",
         %{company: company, ceo: ceo} do
      cancel_all_issues(company.id)

      unless Process.whereis(Cympho.OrchestratorRegistry) do
        start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
      end

      # Seed the planning issue in progress with an active fake orchestrator
      {:ok, issue} = BacklogPlanner.ensure_planning_issue(company.id, ceo)
      {:ok, _in_progress} = Issues.update_issue(issue, %{status: :in_progress})

      test_pid = self()

      holder =
        spawn(fn ->
          Registry.register(Cympho.OrchestratorRegistry, issue.id, nil)
          send(test_pid, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered, 1_000

      # When ensure_planning_issue fails with :planning_issue_in_use, plan_one_company must report error
      result = BacklogPlanner.plan_one_company(company.id, cooldown_ms: 0)
      assert %{checked: 1, errors: 1, error: :planning_issue_in_use} = result
      refute Map.has_key?(result, :waked)

      Process.exit(holder, :kill)
      wait_until_unregistered(issue.id)
    end
  end

  describe "sweep_companies/1" do
    test "aggregates successful wakes, cooldown skips, and errors",
         %{company: company} do
      cancel_all_issues(company.id)

      # First sweep enqueues 1 wake
      counters = BacklogPlanner.sweep_companies(company_ids: [company.id], cooldown_ms: 60_000)
      assert counters.waked == 1
      assert counters.skipped_cooldown == 0
      assert counters.errors == 0

      # Second sweep within cooldown counts as skipped_cooldown
      counters2 = BacklogPlanner.sweep_companies(company_ids: [company.id], cooldown_ms: 60_000)
      assert counters2.waked == 0
      assert counters2.skipped_cooldown == 1
      assert counters2.errors == 0
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

    test "does not yank a planning issue out from under a live orchestrator",
         %{company: company, ceo: ceo} do
      unless Process.whereis(Cympho.OrchestratorRegistry) do
        start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
      end

      {:ok, issue} = BacklogPlanner.ensure_planning_issue(company.id, ceo)
      {:ok, in_progress} = Issues.update_issue(issue, %{status: :in_progress})

      # Register a fake live orchestrator for the planning issue.
      test_pid = self()

      holder =
        spawn(fn ->
          Registry.register(Cympho.OrchestratorRegistry, issue.id, nil)
          send(test_pid, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered, 1_000

      # Releasing now would double-dispatch the CEO's active session.
      assert {:error, :planning_issue_in_use} =
               BacklogPlanner.ensure_planning_issue(company.id, ceo)

      assert Issues.get_issue!(issue.id).status == :in_progress

      Process.exit(holder, :kill)
      wait_until_unregistered(issue.id)

      # Once the session is gone the reset works again.
      {:ok, reset} = BacklogPlanner.ensure_planning_issue(company.id, ceo)
      assert reset.id == in_progress.id
      assert reset.status == :todo
    end
  end

  ## helpers

  defp wait_until_unregistered(issue_id) do
    wait_until(fn -> assert Cympho.Orchestrator.whereis(issue_id) == nil end)
    :ok
  end

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
