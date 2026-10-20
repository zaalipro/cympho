defmodule CymphoWeb.DirectStartPricingRefusalTest do
  # T1-fix gate item 2: D3 keeps a pricing-refused issue queued and gates
  # before checkout. The manual spawn and the legacy direct heartbeat bypass
  # the dispatcher, so they used to check out and start an Orchestrator whose
  # preflight then failed a run, posted a refusal comment and unassigned the
  # issue.
  use CymphoWeb.LiveCase, async: false

  alias Cympho.{AgentHeartbeat, Agents, Comments, Finances, HeartbeatEngine, Issues}
  alias Cympho.{Orchestrator, Runtime, RuntimeProfiles}

  @moduletag :capture_log
  @moduletag membership_role: "admin"

  setup do
    unless Process.whereis(Cympho.OrchestratorRegistry) do
      start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
    end

    case start_supervised({Cympho.AgentHeartbeat.Supervisor, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case start_supervised({Registry, keys: :unique, name: Cympho.AgentHeartbeat.Registry}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  test "a manual spawn of a pricing-refused agent creates no run or comment", %{conn: conn} do
    %{agent: agent, issue: issue} = refused_fixture()
    assert {:error, {:budget_unpriceable_runtime, _}} = Runtime.dispatchable?(issue, agent)

    put_env(:orchestrator, :enabled, true)

    {:ok, view, _html} = live(conn, "/issues/#{issue.id}")

    html = render_submit(view, "spawn_agent", %{"agent_id" => agent.id})
    assert html =~ "does not report a USD cost"

    await_orchestrator_exit(issue.id)

    assert outcome(issue) == {:todo, agent.id, [], []}

    assert Agents.get_agent!(agent.id).status == :idle
  end

  test "repeated legacy heartbeats of a pricing-refused agent create no run or comment" do
    %{agent: agent, issue: issue} = refused_fixture()
    second = assigned_issue(agent)
    assert {:error, {:budget_unpriceable_runtime, _}} = Runtime.dispatchable?(issue, agent)

    put_env(:agent_heartbeat, :delegate_to_dispatcher, false)

    {:ok, pid} = AgentHeartbeat.start_for_agent(agent.id)
    on_exit(fn -> AgentHeartbeat.stop_for_agent(agent.id) end)

    # Two ticks stand in for the periodic timer. A refusal releases (and
    # unassigns) its issue, so each tick takes the agent's next issue.
    for _tick <- 1..2 do
      send(pid, :heartbeat)
      %{current_issue_id: started} = :sys.get_state(pid)
      if started, do: await_orchestrator_exit(started)
    end

    assert Enum.map([issue, second], &outcome/1) ==
             [{:todo, agent.id, [], []}, {:todo, agent.id, [], []}]
  end

  defp refused_fixture do
    company_id = current_company_id()

    {:ok, _policy} =
      Finances.create_budget_policy(%{
        company_id: company_id,
        scope: "company",
        period: "monthly",
        budget_limit_usd: Decimal.new("100.00"),
        action_on_exceed: "block"
      })

    # An agent hired before the built-in profile carried pricing.
    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company_id,
        name: "T1 Gate Unpriced Codex #{System.unique_integer([:positive])}",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config:
          "process-codex"
          |> RuntimeProfiles.config()
          |> Map.delete("pricing")
          |> Map.put("command", fake_codex!()),
        runtime_config: %{
          "profile_id" => "process-codex",
          "env" => %{"OPENAI_API_KEY" => "test-key"}
        }
      })

    %{agent: agent, issue: assigned_issue(agent)}
  end

  defp assigned_issue(agent) do
    {:ok, issue} =
      Issues.create_issue(%{
        company_id: agent.company_id,
        title: "T1 Gate refused issue #{System.unique_integer([:positive])}",
        status: :todo,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })

    on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)
    issue
  end

  # What a direct start left on the issue: {status, assignee_id, runs, refusal
  # comments}, with runs as {status, error_reason}.
  defp outcome(issue) do
    %{status: status, assignee_id: assignee_id} = Issues.get_issue!(issue.id)
    {status, assignee_id, runs(issue), refusal_comments(issue)}
  end

  defp runs(issue) do
    issue.id
    |> HeartbeatEngine.list_runs_for_issue()
    |> Enum.map(&{&1.status, &1.error_reason})
  end

  defp refusal_comments(issue) do
    issue.id
    |> Comments.list_comments()
    |> Enum.filter(&(&1.body =~ "does not report a USD cost"))
    |> Enum.map(& &1.body)
  end

  defp await_orchestrator_exit(issue_id) do
    case Orchestrator.whereis(issue_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end
  end

  defp put_env(app_key, key, value) do
    original = Application.get_env(:cympho, app_key, [])
    Application.put_env(:cympho, app_key, Keyword.put(original, key, value))
    on_exit(fn -> Application.put_env(:cympho, app_key, original) end)
  end

  defp fake_codex! do
    dir = Path.join(System.tmp_dir!(), "t1-gate-codex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "codex")
    File.write!(path, "#!/bin/sh\ncat > /dev/null\necho done\n")
    File.chmod!(path, 0o755)
    path
  end
end
