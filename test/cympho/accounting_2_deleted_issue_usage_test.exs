defmodule Cympho.T1Review.Accounting2DeletedIssueUsageTest do
  # Finding accounting-2: a deleted issue's run with settled usage permanently
  # blocks new runs for its company.
  use Cympho.DataCase, async: false

  alias Cympho.{Agents, Companies, Finances, HeartbeatEngine, Issues, Orchestrator}
  alias Cympho.HeartbeatEngine.Run

  import Ecto.Query

  @moduletag :capture_log

  setup do
    unless Process.whereis(Cympho.OrchestratorRegistry) do
      start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
    end

    :ok
  end

  test "late usage on a run whose issue was deleted is ledgered and does not block the company" do
    %{company: company, agent: agent, issue: issue} = runtime_fixture("deleted")
    {:ok, run} = create_started_run(company, agent, issue)
    {:ok, _cancelled} = HeartbeatEngine.cancel_run(run)

    # Deleting the issue nilifies the run's FK (heartbeat_runs.issue_id is
    # ON DELETE nilify_all). The stopped turn's billed result then settles
    # onto the run through record_late_usage, as Orchestrator.terminate does.
    :ok = Issues.delete_issue(issue)
    assert %Run{issue_id: nil, company_id: company_id} = issueless = Repo.get!(Run, run.id)
    assert company_id == company.id

    {:ok, settled} =
      HeartbeatEngine.record_late_usage(issueless, %{
        input_tokens: 800,
        output_tokens: 200,
        cost_usd: Decimal.new("0.30")
      })

    assert settled.input_tokens == 800

    # New runs for the company are not refused...
    {:ok, next_issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "Next issue",
        status: :todo,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })

    assert {:ok, %Run{}} =
             HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: agent.id,
               issue_id: next_issue.id,
               adapter: "openai_chat"
             })

    # ...and the spend reaches the ledger as a company/agent-only row.
    assert [ledger] = Finances.list_token_usages(company.id)
    assert ledger.heartbeat_run_id == run.id
    assert is_nil(ledger.issue_id)
  end

  test "deleting an issue while its Claude turn holds a billed result keeps the company open" do
    %{company: company, ceo: ceo, issue: issue} = claude_ceo_hang_fixture()
    :ok = Orchestrator.subscribe(issue.id)
    :ok = CymphoWeb.Endpoint.subscribe("company:#{company.id}:runs")

    {:ok, _pid} = Orchestrator.start_and_run(issue, ceo.id)
    # The runner reports progress for the chunk it then decodes (the result).
    assert_receive {:run_progress, %{bytes: bytes}} when bytes > 0, 10_000

    # delete_issue deletes the row first, then stops the orchestrator; its
    # terminate cancels the run and settles the drained billed result.
    :ok = Issues.delete_issue(issue)

    assert [%Run{issue_id: nil} = run] =
             Repo.all(from r in Run, where: r.agent_id == ^ceo.id and r.company_id == ^company.id)

    assert run.input_tokens == 1_000
    assert Decimal.eq?(run.cost_usd, Decimal.new("0.12"))

    # The issueless run's terminal status still reaches its company's topic.
    run_id = run.id

    assert_receive %Phoenix.Socket.Broadcast{
      event: "run_status",
      payload: %{resource_id: ^run_id, issue_id: nil}
    }

    assert :ok = HeartbeatEngine.ensure_usage_reconciled(company.id)

    # Exactly one ledger row, company/agent-only now the issue is gone.
    assert [%{heartbeat_run_id: run_id, issue_id: nil}] = Finances.list_token_usages(company.id)
    assert run_id == run.id
  end

  defp claude_ceo_hang_fixture do
    unique = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "t1-review-fake-claude-#{unique}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "claude")

    result =
      Jason.encode!(%{
        "type" => "result",
        "result" => "Still working on it.",
        "usage" => %{"input_tokens" => 1_000, "output_tokens" => 200},
        "total_cost_usd" => 0.12
      })

    File.write!(path, "#!/bin/sh\ncat > /dev/null\nprintf '%s\\n' '#{result}'\nexec sleep 30\n")
    File.chmod!(path, 0o755)

    {:ok, %{company: company, agents: [ceo | _], seed_issues: [issue | _]}} =
      Companies.create_autonomous_company(%{
        name: "T1 Review Deleted Co #{System.unique_integer([:positive])}",
        issue_prefix: "TRD",
        engineer_count: 1
      })

    {:ok, ceo} = Agents.update_agent(ceo, %{adapter: :claude_code, config: %{"command" => path}})
    {:ok, issue} = Issues.checkout_issue(issue, ceo, :ceo)
    on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)
    %{company: company, ceo: ceo, issue: issue}
  end

  defp runtime_fixture(suffix) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "T1 Review #{suffix} #{unique}",
        slug: "t1-review-#{suffix}-#{unique}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "T1 Review Agent #{suffix} #{unique}",
        role: :engineer,
        status: :idle,
        adapter: :openai_chat,
        config: %{"provider" => "openai", "model" => "gpt-5.4-mini"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "T1 Review issue #{suffix} #{unique}",
        status: :todo,
        assignee_id: agent.id,
        assigned_role: "engineer"
      })

    {:ok, issue} = Issues.checkout_issue(issue, agent)
    on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)

    %{company: company, agent: agent, issue: issue}
  end

  defp create_started_run(company, agent, issue) do
    with {:ok, %Run{} = run} <-
           HeartbeatEngine.create_run(%{
             company_id: company.id,
             agent_id: agent.id,
             issue_id: issue.id,
             adapter: "openai_chat",
             run_metadata: %{"runtime" => %{"provider" => "openai", "model" => "gpt-5.4-mini"}},
             bind_checkout: true
           }) do
      HeartbeatEngine.start_run(run)
    end
  end
end
