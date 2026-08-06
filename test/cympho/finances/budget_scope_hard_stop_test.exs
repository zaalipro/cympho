defmodule Cympho.Finances.BudgetScopeHardStopTest do
  use Cympho.DataCase, async: false

  import ExUnit.CaptureLog
  import Mock
  import Cympho.WaitHelpers

  alias Cympho.{
    Agents,
    Companies,
    Finances,
    Goals,
    HeartbeatEngine,
    Issues,
    Orchestrator,
    Projects,
    Wakes
  }

  alias Cympho.Adapters.MockAdapter
  alias Cympho.Finances.{BudgetIncident, TokenUsage}
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Repo
  alias Cympho.Wakes.AgentWake

  @tag :capture_log
  test "agent hard stop terminates its live orchestrator and active runs only" do
    company = company_fixture("agent-stop")
    agent = agent_fixture(company, "agent-stop")
    live_issue = issue_fixture(company, agent, "agent-live")
    {:ok, live_issue} = Issues.update_issue(live_issue, %{assigned_role: "product_manager"})
    queued_issue = issue_fixture(company, agent, "agent-queued", status: :todo)
    queued_run = run_fixture(company, agent, queued_issue, "pending")
    wake = wake_fixture(agent, queued_issue)

    other_agent = agent_fixture(company, "agent-other")
    other_issue = issue_fixture(company, other_agent, "agent-other")
    other_run = run_fixture(company, other_agent, other_issue, "running")
    other_wake = wake_fixture(other_agent, other_issue)

    policy = blocking_policy(company, "agent", agent.id)

    MockAdapter.clear()
    MockAdapter.script(agent.id, live_issue.id, [:silent])

    on_exit(fn ->
      Orchestrator.stop(live_issue.id)
      MockAdapter.clear()
    end)

    with_mock Cympho.Adapters, [:passthrough], resolve: fn _ -> {:ok, MockAdapter, %{}} end do
      assert {:ok, orchestrator_pid} =
               Orchestrator.start_and_run(live_issue, agent.id,
                 adapter: :mock,
                 adapter_config: %{}
               )

      monitor_ref = Process.monitor(orchestrator_pid)
      assert Process.alive?(orchestrator_pid)

      wait_until(fn ->
        assert Enum.any?(
                 HeartbeatEngine.list_runs_for_issue(live_issue.id),
                 &(&1.status == "running")
               )
      end)

      assert {:error, :budget_blocked} =
               record_crossing_usage(company, %{agent_id: agent.id})

      assert_receive {:DOWN, ^monitor_ref, :process, ^orchestrator_pid, {:runtime_stop, _reason}},
                     1_000

      refute Process.alive?(orchestrator_pid)
    end

    assert Repo.get!(Cympho.Agents.Agent, agent.id).status == :paused
    assert Issues.get_issue!(live_issue.id).status == :todo
    assert [%Run{status: "cancelled"}] = HeartbeatEngine.list_runs_for_issue(live_issue.id)
    assert Repo.get!(Run, queued_run.id).status == "cancelled"
    assert Repo.get!(AgentWake, wake.id).status == "cancelled"

    assert Repo.get!(Cympho.Agents.Agent, other_agent.id).status != :paused
    assert Issues.get_issue!(other_issue.id).status == :in_progress
    assert Repo.get!(Run, other_run.id).status == "running"
    assert Repo.get!(AgentWake, other_wake.id).status == "pending"

    assert_durable_crossing(company, policy)
  end

  test "agent run cancellation requires the exact company and agent pair" do
    company = company_fixture("agent-run-scope")
    agent = agent_fixture(company, "agent-run-scope")
    issue = issue_fixture(company, agent, "agent-run-scope")
    local_run = run_fixture(company, agent, issue, "running")

    other_company = company_fixture("agent-run-scope-other")
    other_agent = agent_fixture(other_company, "agent-run-scope-other")
    other_issue = issue_fixture(other_company, other_agent, "agent-run-scope-other")

    # A malformed/stale row may carry the scoped agent ID with another
    # company. The cleanup API must still honor the explicit tenant boundary.
    foreign_run = run_fixture(other_company, agent, other_issue, "running")

    assert {:ok, 1} =
             HeartbeatEngine.cancel_active_runs_for_agent(
               company.id,
               agent.id,
               "budget hard stop"
             )

    assert Repo.get!(Run, local_run.id).status == "cancelled"
    assert Repo.get!(Run, foreign_run.id).status == "running"
  end

  test "company hard stop pauses the company and cancels only its active runtime and wakes" do
    company = company_fixture("company-stop")
    agent = agent_fixture(company, "company-stop")
    issue = issue_fixture(company, agent, "company-stop")
    run = run_fixture(company, agent, issue, "running")
    wake = wake_fixture(agent, issue)

    other_company = company_fixture("company-other")
    other_agent = agent_fixture(other_company, "company-other")
    other_issue = issue_fixture(other_company, other_agent, "company-other")
    other_run = run_fixture(other_company, other_agent, other_issue, "running")
    other_wake = wake_fixture(other_agent, other_issue)

    policy = blocking_policy(company, "company", nil)

    assert {:error, :budget_blocked} = record_crossing_usage(company)

    assert Repo.get!(Cympho.Companies.Company, company.id).status == "paused"
    assert Repo.get!(Cympho.Agents.Agent, agent.id).status == :paused
    assert Repo.get!(Run, run.id).status == "cancelled"
    assert Repo.get!(AgentWake, wake.id).status == "cancelled"

    assert Repo.get!(Cympho.Companies.Company, other_company.id).status == "active"
    assert Repo.get!(Cympho.Agents.Agent, other_agent.id).status != :paused
    assert Repo.get!(Run, other_run.id).status == "running"
    assert Repo.get!(AgentWake, other_wake.id).status == "pending"

    assert_durable_crossing(company, policy)
  end

  test "issue hard stop pauses the issue and cancels only that issue's run and wakes" do
    company = company_fixture("issue-stop")
    agent = agent_fixture(company, "issue-stop")
    issue = issue_fixture(company, agent, "issue-stop")
    run = run_fixture(company, agent, issue, "running")
    wake = wake_fixture(agent, issue)

    other_agent = agent_fixture(company, "issue-other")
    other_issue = issue_fixture(company, other_agent, "issue-other")
    other_run = run_fixture(company, other_agent, other_issue, "running")
    other_wake = wake_fixture(other_agent, other_issue)

    policy = blocking_policy(company, "issue", issue.id)

    assert {:error, :budget_blocked} =
             record_crossing_usage(company, %{issue_id: issue.id, agent_id: agent.id})

    stopped_issue = Issues.get_issue!(issue.id)
    assert Issues.issue_runtime_paused?(stopped_issue)
    assert stopped_issue.status == :todo
    assert Repo.get!(Run, run.id).status == "cancelled"
    assert Repo.get!(AgentWake, wake.id).status == "cancelled"

    refute Issues.issue_runtime_paused?(Issues.get_issue!(other_issue.id))
    assert Repo.get!(Run, other_run.id).status == "running"
    assert Repo.get!(AgentWake, other_wake.id).status == "pending"

    assert {:error, {:budget_blocked, %{policy_id: finance_policy_id}}} =
             Finances.check_runtime_budget(Issues.get_issue!(issue.id), agent)

    assert finance_policy_id == policy.id

    assert {:error, {:budget_blocked, %{policy_id: policy_id}}} =
             HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: agent.id,
               issue_id: issue.id,
               adapter: "process"
             })

    assert policy_id == policy.id
    assert_durable_crossing(company, policy)
  end

  test "project hard stop cancels every current project issue and leaves another project alone" do
    company = company_fixture("project-stop")
    project = project_fixture(company, "Project Stop")
    other_project = project_fixture(company, "Other Project")

    first_agent = agent_fixture(company, "project-first")
    first_issue = issue_fixture(company, first_agent, "project-first", project_id: project.id)
    first_run = run_fixture(company, first_agent, first_issue, "running")
    first_wake = wake_fixture(first_agent, first_issue)

    second_agent = agent_fixture(company, "project-second")

    second_issue =
      issue_fixture(company, second_agent, "project-second",
        project_id: project.id,
        status: :todo
      )

    second_run = run_fixture(company, second_agent, second_issue, "pending")
    second_wake = wake_fixture(second_agent, second_issue)

    other_agent = agent_fixture(company, "project-other")

    other_issue =
      issue_fixture(company, other_agent, "project-other", project_id: other_project.id)

    other_run = run_fixture(company, other_agent, other_issue, "running")
    other_wake = wake_fixture(other_agent, other_issue)

    policy = blocking_policy(company, "project", project.id)

    assert {:error, :budget_blocked} =
             record_crossing_usage(company, %{project_id: project.id, agent_id: first_agent.id})

    assert Repo.get!(Run, first_run.id).status == "cancelled"
    assert Repo.get!(Run, second_run.id).status == "cancelled"
    assert Repo.get!(AgentWake, first_wake.id).status == "cancelled"
    assert Repo.get!(AgentWake, second_wake.id).status == "cancelled"
    assert Issues.get_issue!(first_issue.id).status == :todo

    assert Repo.get!(Run, other_run.id).status == "running"
    assert Repo.get!(AgentWake, other_wake.id).status == "pending"

    assert {:error, {:budget_blocked, %{policy_id: finance_policy_id}}} =
             Finances.check_runtime_budget(Issues.get_issue!(second_issue.id), second_agent)

    assert finance_policy_id == policy.id

    assert {:error, {:budget_blocked, %{policy_id: policy_id}}} =
             HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: second_agent.id,
               issue_id: second_issue.id,
               adapter: "process"
             })

    assert policy_id == policy.id
    assert_durable_crossing(company, policy)
  end

  test "goal hard stop cancels current goal runtime and leaves another goal alone" do
    company = company_fixture("goal-stop")
    goal = goal_fixture(company, "Goal Stop")
    other_goal = goal_fixture(company, "Other Goal")

    agent = agent_fixture(company, "goal-stop")
    issue = issue_fixture(company, agent, "goal-stop", goal_id: goal.id)
    run = run_fixture(company, agent, issue, "running")
    wake = wake_fixture(agent, issue)

    other_agent = agent_fixture(company, "goal-other")
    other_issue = issue_fixture(company, other_agent, "goal-other", goal_id: other_goal.id)
    other_run = run_fixture(company, other_agent, other_issue, "running")
    other_wake = wake_fixture(other_agent, other_issue)

    policy = blocking_policy(company, "goal", goal.id)

    assert {:error, :budget_blocked} =
             record_crossing_usage(company, %{goal_id: goal.id, agent_id: agent.id})

    assert Repo.get!(Run, run.id).status == "cancelled"
    assert Repo.get!(AgentWake, wake.id).status == "cancelled"
    assert Issues.get_issue!(issue.id).status == :todo

    assert Repo.get!(Run, other_run.id).status == "running"
    assert Repo.get!(AgentWake, other_wake.id).status == "pending"

    assert {:error, {:budget_blocked, %{policy_id: finance_policy_id}}} =
             Finances.check_runtime_budget(Issues.get_issue!(issue.id), agent)

    assert finance_policy_id == policy.id

    assert {:error, {:budget_blocked, %{policy_id: policy_id}}} =
             HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: agent.id,
               issue_id: issue.id,
               adapter: "process"
             })

    assert policy_id == policy.id
    assert_durable_crossing(company, policy)
  end

  test "cleanup exceptions are logged after usage and incident commit, and later cleanup still runs" do
    company = company_fixture("cleanup-failure")
    agent = agent_fixture(company, "cleanup-failure")
    issue = issue_fixture(company, agent, "cleanup-failure")
    run = run_fixture(company, agent, issue, "running")
    wake = wake_fixture(agent, issue)
    policy = blocking_policy(company, "issue", issue.id)

    log =
      capture_log(fn ->
        with_mock Dispatcher, [:passthrough],
          stop_issue: fn _issue_id, _reason -> raise "simulated runtime stop failure" end do
          assert {:error, :budget_blocked} =
                   record_crossing_usage(company, %{issue_id: issue.id, agent_id: agent.id})
        end
      end)

    assert log =~ "Finances: budget hard-stop cleanup failed"
    assert Repo.get!(Run, run.id).status == "cancelled"
    assert Repo.get!(AgentWake, wake.id).status == "cancelled"
    assert Issues.issue_runtime_paused?(Issues.get_issue!(issue.id))
    assert_durable_crossing(company, policy)
  end

  @tag :capture_log
  test "post-commit hard-stop failure leaves incomplete enforcement; recovery quiets the scope" do
    company = company_fixture("hardstop-recover")
    agent = agent_fixture(company, "hardstop-recover")
    issue = issue_fixture(company, agent, "hardstop-recover")
    run = run_fixture(company, agent, issue, "running")
    wake = wake_fixture(agent, issue)
    policy = blocking_policy(company, "issue", issue.id)

    # Simulate a crash/partial failure after the finance ledger commit: stop,
    # cancel-runs, and cancel-wakes all fail so active work remains.
    capture_log(fn ->
      with_mocks([
        {Dispatcher, [:passthrough],
         [stop_issue: fn _issue_id, _reason -> {:error, :simulated_post_commit_failure} end]},
        {HeartbeatEngine, [:passthrough],
         [
           cancel_active_runs_for_issue: fn _issue_id, _reason ->
             {:error, :simulated_post_commit_failure}
           end
         ]},
        {Wakes, [:passthrough],
         [
           cancel_issue_wakes: fn _issue_id, _reason ->
             {:error, :simulated_post_commit_failure}
           end
         ]}
      ]) do
        assert {:error, :budget_blocked} =
                 record_crossing_usage(company, %{issue_id: issue.id, agent_id: agent.id})
      end
    end)

    assert [%TokenUsage{}] = Finances.list_token_usages(company.id)

    assert [%BudgetIncident{event_type: "budget_exceeded", enforcement_status: "incomplete"}] =
             Repo.all(
               from i in BudgetIncident,
                 where: i.company_id == ^company.id and i.budget_policy_id == ^policy.id
             )

    assert Repo.get!(Run, run.id).status == "running"
    assert Repo.get!(AgentWake, wake.id).status == "pending"

    assert Finances.recover_incomplete_hard_stops() >= 1

    assert Repo.get!(Run, run.id).status == "cancelled"
    assert Repo.get!(AgentWake, wake.id).status == "cancelled"
    assert Issues.issue_runtime_paused?(Issues.get_issue!(issue.id))

    assert [%BudgetIncident{enforcement_status: "complete"}] =
             Repo.all(
               from i in BudgetIncident,
                 where: i.company_id == ^company.id and i.budget_policy_id == ^policy.id
             )

    # Idempotent: a second recovery pass finds nothing incomplete.
    assert Finances.recover_incomplete_hard_stops() == 0
  end

  test "budget_exceeded incident notifies OwnerAttention; resolve does too" do
    company = company_fixture("hardstop-attention")
    policy = blocking_policy(company, "company", nil)

    :ok = Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company.id}:owner_attention")

    assert {:error, :budget_blocked} = record_crossing_usage(company)

    assert_receive {:owner_attention_changed, company_id}, 1_000
    assert company_id == company.id

    assert [incident] =
             Repo.all(
               from i in BudgetIncident,
                 where: i.company_id == ^company.id and i.budget_policy_id == ^policy.id
             )

    assert incident.event_type == "budget_exceeded"
    assert incident.enforcement_status == "complete"

    assert {:ok, _resolved} = Finances.resolve_budget_incident(incident)
    assert_receive {:owner_attention_changed, ^company_id}, 1_000
  end

  test "heartbeat usage rejects project and goal IDs that do not belong to the run issue" do
    company = company_fixture("usage-scope")
    other_company = company_fixture("usage-scope-other")
    project = project_fixture(company, "Usage Project")
    wrong_project = project_fixture(company, "Wrong Local Project")
    other_project = project_fixture(other_company, "Foreign Project")
    goal = goal_fixture(company, "Usage Goal")
    wrong_goal = goal_fixture(company, "Wrong Local Goal")
    other_goal = goal_fixture(other_company, "Foreign Goal")
    agent = agent_fixture(company, "usage-scope")

    issue =
      issue_fixture(company, agent, "usage-scope", project_id: project.id, goal_id: goal.id)

    run = run_fixture(company, agent, issue, "completed")

    base_attrs = %{
      company_id: company.id,
      agent_id: agent.id,
      issue_id: issue.id,
      heartbeat_run_id: run.id,
      provider: "scope-test",
      model: "scope-test",
      total_tokens: 1,
      cost_usd: Decimal.new("0.01")
    }

    assert {:error, :heartbeat_run_scope_mismatch} =
             Finances.record_token_usage(Map.put(base_attrs, :project_id, other_project.id))

    assert {:error, :heartbeat_run_scope_mismatch} =
             Finances.record_token_usage(Map.put(base_attrs, :goal_id, other_goal.id))

    assert {:error, :heartbeat_run_scope_mismatch} =
             Finances.record_token_usage(Map.put(base_attrs, :project_id, wrong_project.id))

    assert {:error, :heartbeat_run_scope_mismatch} =
             Finances.record_token_usage(Map.put(base_attrs, :goal_id, wrong_goal.id))

    refute Repo.exists?(from t in TokenUsage, where: t.heartbeat_run_id == ^run.id)

    assert {:ok, usage} =
             Finances.record_token_usage(
               Map.merge(base_attrs, %{project_id: project.id, goal_id: goal.id})
             )

    assert usage.project_id == project.id
    assert usage.goal_id == goal.id
  end

  test "heartbeat usage requires the complete run scope instead of accepting omitted IDs" do
    company = company_fixture("usage-complete-scope")
    project = project_fixture(company, "Complete Scope Project")
    goal = goal_fixture(company, "Complete Scope Goal")
    agent = agent_fixture(company, "usage-complete-scope")

    issue =
      issue_fixture(company, agent, "usage-complete-scope",
        project_id: project.id,
        goal_id: goal.id
      )

    run = run_fixture(company, agent, issue, "completed")

    attrs = %{
      company_id: company.id,
      agent_id: agent.id,
      issue_id: issue.id,
      project_id: project.id,
      goal_id: goal.id,
      heartbeat_run_id: run.id,
      provider: "scope-test",
      model: "scope-test",
      total_tokens: 1,
      cost_usd: Decimal.new("0.01")
    }

    for key <- [:agent_id, :issue_id, :project_id, :goal_id] do
      assert {:error, :heartbeat_run_scope_mismatch} =
               attrs
               |> Map.delete(key)
               |> Finances.record_token_usage()
    end

    refute Repo.exists?(from t in TokenUsage, where: t.heartbeat_run_id == ^run.id)
    assert {:ok, usage} = Finances.record_token_usage(attrs)
    assert usage.heartbeat_run_id == run.id
  end

  defp company_fixture(label) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Budget Scope #{label} #{unique}",
        slug: "budget-scope-#{label}-#{unique}"
      })

    company
  end

  defp agent_fixture(company, label) do
    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Budget Agent #{label} #{System.unique_integer([:positive])}",
        role: :engineer,
        status: :idle,
        adapter: :process
      })

    agent
  end

  defp issue_fixture(company, agent, label, opts \\ []) do
    attrs = %{
      company_id: company.id,
      title: "Budget issue #{label} #{System.unique_integer([:positive])}",
      status: Keyword.get(opts, :status, :in_progress),
      assignee_id: agent.id,
      project_id: Keyword.get(opts, :project_id),
      goal_id: Keyword.get(opts, :goal_id)
    }

    {:ok, issue} = Issues.create_issue(attrs)
    issue
  end

  defp project_fixture(company, name) do
    {:ok, project} =
      Projects.create_project(%{
        company_id: company.id,
        name: "#{name} #{System.unique_integer([:positive])}",
        prefix: unique_prefix()
      })

    project
  end

  defp goal_fixture(company, title) do
    {:ok, goal} =
      Goals.create_goal(%{
        company_id: company.id,
        title: "#{title} #{System.unique_integer([:positive])}"
      })

    goal
  end

  defp run_fixture(company, agent, issue, status) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Run{
      company_id: company.id,
      agent_id: agent.id,
      issue_id: issue.id,
      status: status,
      adapter: "process",
      started_at: if(status == "running", do: now),
      completed_at: if(status == "completed", do: now),
      last_heartbeat_at: now
    })
  end

  defp wake_fixture(agent, issue) do
    {:ok, wake} =
      Wakes.do_wake_agent(agent.id, issue.id, "manual_dispatch", "system", nil, %{
        "source" => "budget_scope_test"
      })

    wake
  end

  defp blocking_policy(company, scope, scope_id) do
    attrs = %{
      company_id: company.id,
      scope: scope,
      budget_limit_usd: Decimal.new("1.00"),
      action_on_exceed: "block",
      period: "monthly"
    }

    attrs = if scope_id, do: Map.put(attrs, :scope_id, scope_id), else: attrs
    {:ok, policy} = Finances.create_budget_policy(attrs)
    policy
  end

  defp record_crossing_usage(company, scope_attrs \\ %{}) do
    Finances.record_token_usage(
      Map.merge(
        %{
          company_id: company.id,
          provider: "scope-test",
          model: "scope-test",
          total_tokens: 100,
          cost_usd: Decimal.new("1.00")
        },
        scope_attrs
      )
    )
  end

  defp assert_durable_crossing(company, policy) do
    assert [%TokenUsage{}] = Finances.list_token_usages(company.id)

    assert [%BudgetIncident{event_type: "budget_exceeded", enforcement_status: "complete"}] =
             Repo.all(
               from i in BudgetIncident,
                 where: i.company_id == ^company.id and i.budget_policy_id == ^policy.id
             )
  end

  defp unique_prefix do
    value = System.unique_integer([:positive])

    letters =
      for power <- 0..4 do
        <<?A + rem(div(value, Integer.pow(26, power)), 26)>>
      end

    "P" <> Enum.join(letters)
  end
end
