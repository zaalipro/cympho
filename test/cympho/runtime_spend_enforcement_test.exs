defmodule Cympho.RuntimeSpendEnforcementTest do
  use Cympho.DataCase, async: false

  alias Cympho.{Agents, Budgets, Companies, Finances, HeartbeatEngine, Issues, Wakes}
  alias Cympho.Finances.BudgetIncident
  alias Cympho.Finances.TokenUsage
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Repo
  alias Cympho.Wakes.AgentWake

  import Ecto.Query

  test "domain budget create syncs hard-stop policy that blocks Runtime budget gate after spend" do
    %{company: company, agent: agent, issue: issue} = runtime_fixture("domain-policy-sync")

    # No direct Finances.create_budget_policy — only domain Budgets.create_budget.
    assert {:ok, budget} =
             Budgets.create_budget(%{
               company_id: company.id,
               name: "Domain-synced agent hard stop",
               scope_type: "agent",
               scope_id: agent.id,
               agent_id: agent.id,
               limit_amount: Decimal.new("1.00"),
               hard_stop: true,
               status: "active"
             })

    policy = Finances.matching_budget_policy(budget)
    assert policy.action_on_exceed == "block"
    assert policy.scope_id == agent.id

    # Seed over-limit spend (TokenUsage is what runtime policy spend reads).
    Repo.insert!(%TokenUsage{
      company_id: company.id,
      agent_id: agent.id,
      issue_id: issue.id,
      provider: "llmotions",
      model: "gpt-5.6-terra",
      input_tokens: 100,
      output_tokens: 25,
      total_tokens: 125,
      cost_usd: Decimal.new("1.25")
    })

    # Runtime.preflight delegates here — assert the BudgetPolicy gate itself.
    assert {:error, {:budget_blocked, info}} = Finances.check_runtime_budget(issue, agent)
    assert info.policy_id == policy.id
    assert info.scope == "agent"
  end

  test "terminal spend commits usage and incident, pauses the agent, and blocks the next run" do
    %{company: company, agent: agent, issue: issue} = runtime_fixture("hard-stop")

    {:ok, policy} =
      Finances.create_budget_policy(%{
        company_id: company.id,
        scope: "agent",
        scope_id: agent.id,
        period: "monthly",
        budget_limit_usd: Decimal.new("1.00"),
        warning_threshold_pct: Decimal.new("80"),
        action_on_exceed: "block"
      })

    {:ok, wake} =
      Wakes.do_wake_agent(agent.id, issue.id, "manual_dispatch", "system", nil, %{
        "source" => "runtime_spend_test"
      })

    {:ok, started_run} = create_started_run(company, agent, issue)

    assert {:ok, completed_run} =
             HeartbeatEngine.complete_run(started_run, %{
               input_tokens: 1_200,
               output_tokens: 300,
               cost_usd: Decimal.new("1.25")
             })

    assert [usage] = Finances.list_token_usages(company.id)
    assert usage.agent_id == agent.id
    assert usage.issue_id == issue.id
    assert usage.heartbeat_run_id == completed_run.id
    assert usage.provider == "llmotions"
    assert usage.model == "gpt-5.6-terra"
    assert usage.input_tokens == 1_200
    assert usage.output_tokens == 300
    assert Decimal.eq?(usage.cost_usd, Decimal.new("1.25"))
    assert usage.metadata["heartbeat_run_id"] == completed_run.id

    assert [incident] =
             Repo.all(
               from i in BudgetIncident,
                 where: i.company_id == ^company.id and i.budget_policy_id == ^policy.id
             )

    assert incident.event_type == "budget_exceeded"
    assert incident.metadata["token_usage_id"] == usage.id

    paused_agent = Repo.get!(Cympho.Agents.Agent, agent.id)
    assert paused_agent.status == :paused
    assert paused_agent.governance_status == "paused"
    assert paused_agent.pause_reason =~ "Budget hard stop"

    assert %AgentWake{status: "cancelled"} = Wakes.get_agent_wake!(wake.id)

    released_issue = Issues.get_issue!(issue.id)
    assert released_issue.status == :todo
    assert is_nil(released_issue.assignee_id)
    assert is_nil(released_issue.checkout_run_id)

    assert {:error, {:budget_blocked, budget_info}} =
             HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: agent.id,
               issue_id: issue.id,
               adapter: "openai_chat"
             })

    assert budget_info.policy_id == policy.id
    assert budget_info.scope == "agent"
    assert [persisted_run] = HeartbeatEngine.list_runs_for_issue(issue.id)
    assert persisted_run.id == completed_run.id
    assert persisted_run.status == "completed"
  end

  test "spend exactly at a hard limit commits an incident and blocks future runs" do
    %{company: company, agent: agent, issue: issue} = runtime_fixture("exact-limit")

    {:ok, policy} =
      Finances.create_budget_policy(%{
        company_id: company.id,
        scope: "agent",
        scope_id: agent.id,
        period: "monthly",
        budget_limit_usd: Decimal.new("1.00"),
        warning_threshold_pct: Decimal.new("80"),
        action_on_exceed: "block"
      })

    {:ok, started_run} = create_started_run(company, agent, issue)

    assert {:ok, _completed_run} =
             HeartbeatEngine.complete_run(started_run, %{
               input_tokens: 100,
               output_tokens: 25,
               cost_usd: Decimal.new("1.00")
             })

    assert [%BudgetIncident{event_type: "budget_exceeded"}] =
             Repo.all(
               from i in BudgetIncident,
                 where: i.company_id == ^company.id and i.budget_policy_id == ^policy.id
             )

    assert Repo.get!(Cympho.Agents.Agent, agent.id).status == :paused

    assert {:error, {:budget_blocked, %{policy_id: policy_id}}} =
             HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: agent.id,
               issue_id: issue.id,
               adapter: "openai_chat"
             })

    assert policy_id == policy.id
  end

  test "terminal usage is idempotent for one heartbeat run" do
    %{company: company, agent: agent, issue: issue} = runtime_fixture("idempotent")
    {:ok, started_run} = create_started_run(company, agent, issue)

    assert {:ok, completed_run} =
             HeartbeatEngine.complete_run(started_run, %{
               input_tokens: 200,
               output_tokens: 50,
               cost_usd: Decimal.new("0.25")
             })

    assert {:error, {:invalid_status, "completed"}} =
             HeartbeatEngine.complete_run(started_run, %{
               input_tokens: 200,
               output_tokens: 50,
               cost_usd: Decimal.new("0.25")
             })

    assert [first_usage] = Finances.list_token_usages(company.id)

    duplicate_attrs = %{
      company_id: company.id,
      agent_id: agent.id,
      issue_id: issue.id,
      heartbeat_run_id: completed_run.id,
      provider: "llmotions",
      model: "gpt-5.6-terra",
      input_tokens: 200,
      output_tokens: 50,
      cost_usd: Decimal.new("0.25"),
      metadata: %{"heartbeat_run_id" => completed_run.id}
    }

    assert {:ok, duplicate_result} = Finances.record_token_usage(duplicate_attrs)
    assert duplicate_result.id == first_usage.id
    assert [only_usage] = Finances.list_token_usages(company.id)
    assert only_usage.id == first_usage.id
    assert length(Finances.list_finance_events(company.id)) == 1
  end

  test "unpriced failed-run token usage remains durable without invented cost" do
    %{company: company, agent: agent, issue: issue} = runtime_fixture("unpriced")
    {:ok, started_run} = create_started_run(company, agent, issue)

    assert {:ok, _failed_run} =
             HeartbeatEngine.fail_run(started_run, :stall_timeout, %{
               input_tokens: 900,
               output_tokens: 100,
               cost_usd: Decimal.new("0")
             })

    assert [usage] = Finances.list_token_usages(company.id)
    assert usage.provider == "llmotions"
    assert usage.model == "gpt-5.6-terra"
    assert usage.total_tokens == 1_000
    assert Decimal.eq?(usage.cost_usd, Decimal.new("0"))
  end

  test "a hard stop in one company does not block another company's matching agent scope" do
    first = runtime_fixture("tenant-a")
    second = runtime_fixture("tenant-b")

    {:ok, _first_policy} =
      Finances.create_budget_policy(%{
        company_id: first.company.id,
        scope: "agent",
        scope_id: first.agent.id,
        budget_limit_usd: Decimal.new("0.50"),
        action_on_exceed: "block"
      })

    {:ok, _second_policy} =
      Finances.create_budget_policy(%{
        company_id: second.company.id,
        scope: "agent",
        scope_id: second.agent.id,
        budget_limit_usd: Decimal.new("0.50"),
        action_on_exceed: "block"
      })

    {:ok, first_run} = create_started_run(first.company, first.agent, first.issue)

    assert {:ok, first_completed} =
             HeartbeatEngine.complete_run(first_run, %{
               input_tokens: 10,
               output_tokens: 5,
               cost_usd: Decimal.new("0.75")
             })

    assert [_usage] = Finances.list_token_usages(first.company.id)
    assert Finances.list_token_usages(second.company.id) == []

    assert {:error, :heartbeat_run_scope_mismatch} =
             Finances.record_token_usage(%{
               company_id: second.company.id,
               agent_id: second.agent.id,
               issue_id: second.issue.id,
               heartbeat_run_id: first_completed.id,
               provider: "llmotions",
               model: "gpt-5.6-terra",
               input_tokens: 10,
               output_tokens: 5,
               cost_usd: Decimal.new("0.75")
             })

    assert Finances.list_token_usages(second.company.id) == []

    assert {:ok, second_run} =
             HeartbeatEngine.create_run(%{
               company_id: second.company.id,
               agent_id: second.agent.id,
               issue_id: second.issue.id,
               adapter: "openai_chat",
               bind_checkout: true
             })

    assert Repo.get!(Cympho.Agents.Agent, second.agent.id).status != :paused
    assert Repo.get!(Cympho.Issues.Issue, second.issue.id).checkout_run_id == second_run.id
  end

  test "an unscoped legacy issue bypasses company finance policy preflight" do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Legacy unscoped #{unique}",
        slug: "legacy-unscoped-#{unique}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Legacy Agent #{unique}",
        role: :engineer,
        status: :idle
      })

    Repo.insert!(%TokenUsage{
      company_id: company.id,
      agent_id: agent.id,
      provider: "legacy",
      model: "legacy",
      cost_usd: Decimal.new("2.00")
    })

    {:ok, _policy} =
      Finances.create_budget_policy(%{
        company_id: company.id,
        scope: "agent",
        scope_id: agent.id,
        budget_limit_usd: Decimal.new("1.00"),
        action_on_exceed: "block"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Legacy issue without company scope #{unique}",
        status: :todo,
        assignee_id: agent.id
      })

    assert is_nil(issue.company_id)

    assert {:ok, run} =
             HeartbeatEngine.create_run(%{
               agent_id: agent.id,
               issue_id: issue.id,
               adapter: "claude_local"
             })

    assert run.status == "pending"
    assert is_nil(run.company_id)
  end

  defp runtime_fixture(suffix) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Runtime Spend #{suffix} #{unique}",
        slug: "runtime-spend-#{suffix}-#{unique}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Spend Agent #{suffix} #{unique}",
        role: :engineer,
        status: :idle,
        adapter: :openai_chat,
        config: %{"provider" => "llmotions", "model" => "gpt-5.6-terra"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "Spend issue #{suffix} #{unique}",
        status: :todo,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })

    {:ok, issue} = Issues.checkout_issue(issue, agent)

    on_exit(fn ->
      File.rm_rf(Cympho.Workspace.workspace_path(issue.id))
    end)

    %{company: company, agent: agent, issue: issue}
  end

  defp create_started_run(company, agent, issue) do
    with {:ok, %Run{} = run} <-
           HeartbeatEngine.create_run(%{
             company_id: company.id,
             agent_id: agent.id,
             issue_id: issue.id,
             adapter: "openai_chat",
             run_metadata: %{
               "runtime" => %{"provider" => "llmotions", "model" => "gpt-5.6-terra"}
             },
             bind_checkout: true
           }),
         {:ok, %Run{} = started_run} <- HeartbeatEngine.start_run(run) do
      {:ok, started_run}
    end
  end
end
