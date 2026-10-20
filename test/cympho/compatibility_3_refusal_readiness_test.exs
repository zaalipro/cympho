defmodule Cympho.T1Review.Compatibility3RefusalReadinessTest do
  # Finding compatibility-3: a refused runtime blocks issues one at a time,
  # and readiness checks still report the agent as Ready.
  use Cympho.DataCase, async: false

  alias Cympho.{Agents, Comments, Companies, Finances, Goals, HeartbeatEngine, Issues}
  alias Cympho.{Projects, Runtime, RuntimePreflight, RuntimeProfiles}
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Orchestrator.Dispatcher.State

  @moduletag :capture_log

  setup do
    unless Process.whereis(Cympho.OrchestratorRegistry) do
      start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
    end

    :ok
  end

  test "readiness does not report Ready for an agent every run refuses" do
    %{agent: agent, issue: issue} = refused_codex_fixture()
    assert {:error, {:budget_unpriceable_runtime, _info}} = Runtime.preflight(issue, agent)

    preflight = RuntimePreflight.for_agent(agent, autonomy_enabled?: true)

    assert preflight.status == :blocked,
           "readiness is #{inspect(preflight.status)}: " <>
             inspect(Enum.map(preflight.items, &{&1.label, &1.status}))
  end

  test "a pricing refusal keeps the issue queued without checkout, run or comment" do
    %{company: company, agent: agent, issue: issue} = refused_codex_fixture()

    # The dispatcher's pre-checkout gate refuses the runtime (D3)...
    assert {:error, {:budget_unpriceable_runtime, _info}} = Runtime.dispatchable?(issue, agent)

    original = Application.get_env(:cympho, :orchestrator, [])
    Application.put_env(:cympho, :orchestrator, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:cympho, :orchestrator, original) end)

    assert {:noreply, %State{} = state} =
             Dispatcher.handle_info({:poll_company, company.id}, State.new())

    # ...so a dispatch pass leaves the issue queued under backoff with no run,
    # no comment, and the agent free for work a scoped policy does not cover.
    assert %{attempts: 1} = state.retry_attempts[issue.id]
    assert Issues.get_issue!(issue.id).status == :todo
    assert HeartbeatEngine.list_runs_for_issue(issue.id) == []
    assert Comments.list_comments(issue.id) == []
    assert Agents.get_agent!(agent.id).status == :idle
  end

  for scope <- ~w(project goal issue agent) do
    test "a #{scope}-scoped refusal leaves work outside the #{scope} eligible" do
      scope = unquote(scope)
      %{covered: {issue, agent}, other: {other_issue, other_agent}} = scoped_fixture(scope)

      assert {:error, {:budget_unpriceable_runtime, %{scope: ^scope}}} =
               Runtime.dispatchable?(issue, agent)

      assert spending_limit?(RuntimePreflight.for_issue(issue))

      assert Runtime.dispatchable?(other_issue, other_agent) == :ok
      refute spending_limit?(RuntimePreflight.for_issue(other_issue))

      # Agent readiness has no issue: only an agent-scoped policy shows there.
      assert spending_limit?(RuntimePreflight.for_agent(agent)) == (scope == "agent")
      refute spending_limit?(RuntimePreflight.for_agent(other_agent))
    end
  end

  # One codex agent, an issue inside a project and goal, and an unrelated
  # issue; for an agent scope the unrelated work belongs to a second agent.
  defp scoped_fixture(scope) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "T1 Review Scoped #{unique}",
        slug: "t1-review-scoped-#{unique}"
      })

    agent = codex_agent(company, "T1 Review Scoped Codex #{unique}")

    {:ok, project} =
      Projects.create_project(%{
        name: "T1 Review Scoped #{unique}",
        prefix: "TRS",
        company_id: company.id
      })

    {:ok, goal} =
      Goals.create_goal(%{
        title: "T1 Review Scoped goal #{unique}",
        company_id: company.id,
        project_id: project.id
      })

    issue = todo_issue(agent, %{project_id: project.id, goal_id: goal.id})

    {other_issue, other_agent} =
      if scope == "agent" do
        other_agent = codex_agent(company, "T1 Review Other Codex #{unique}")
        {todo_issue(other_agent), other_agent}
      else
        {todo_issue(agent), agent}
      end

    scope_id =
      case scope do
        "project" -> project.id
        "goal" -> goal.id
        "issue" -> issue.id
        "agent" -> agent.id
      end

    {:ok, _policy} =
      Finances.create_budget_policy(%{
        company_id: company.id,
        scope: scope,
        scope_id: scope_id,
        period: "monthly",
        budget_limit_usd: Decimal.new("100.00"),
        action_on_exceed: "block"
      })

    %{covered: {issue, agent}, other: {other_issue, other_agent}}
  end

  # An agent hired before the built-in profile carried pricing.
  defp codex_agent(company, name) do
    config =
      "process-codex"
      |> RuntimeProfiles.config()
      |> Map.delete("pricing")
      |> Map.put("command", fake_codex!())

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: name,
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: config,
        runtime_config: %{
          "profile_id" => "process-codex",
          "env" => %{"OPENAI_API_KEY" => "test-key"}
        }
      })

    agent
  end

  defp todo_issue(agent, attrs \\ %{}) do
    {:ok, issue} =
      attrs
      |> Map.merge(%{
        company_id: agent.company_id,
        title: "T1 Review scoped issue #{System.unique_integer([:positive])}",
        status: :todo,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })
      |> Issues.create_issue()

    on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)
    issue
  end

  defp spending_limit?(preflight),
    do: Enum.any?(preflight.items, &(&1.label == "Spending limit" and &1.status == :blocked))

  defp refused_codex_fixture do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "T1 Review Ready #{unique}",
        slug: "t1-review-ready-#{unique}"
      })

    agent = codex_agent(company, "T1 Review Codex #{unique}")

    {:ok, _policy} =
      Finances.create_budget_policy(%{
        company_id: company.id,
        scope: "company",
        period: "monthly",
        budget_limit_usd: Decimal.new("100.00"),
        action_on_exceed: "block"
      })

    %{company: company, agent: agent, issue: todo_issue(agent)}
  end

  defp fake_codex! do
    dir = Path.join(System.tmp_dir!(), "t1-review-codex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "codex")
    File.write!(path, "#!/bin/sh\ncat > /dev/null\necho done\n")
    File.chmod!(path, 0o755)
    path
  end
end
