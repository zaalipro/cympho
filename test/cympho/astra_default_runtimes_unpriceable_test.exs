defmodule Cympho.T1Review.AstraDefaultRuntimesUnpriceableTest do
  # Finding astra-opus-missed-2: built-in default runtimes are unpriceable, so
  # the CEO's default hires and the LLMotions smoke agents are refused under
  # the always-on onboarding block policy.
  use Cympho.DataCase, async: false

  alias Cympho.{AgentActions, Agents, Companies, Issues, Runtime}
  alias Cympho.Smoke.LLMotions

  @moduletag :capture_log

  test "the CEO's default engineer hire can start its first run" do
    start_heartbeat_supervisor()

    # create_autonomous_company always inserts a company-scope block policy.
    {:ok, %{agents: [ceo, _cto, engineer | _], seed_issues: [seed | _]}} =
      Companies.create_autonomous_company(%{
        name: "T1 Review Hire Co #{System.unique_integer([:positive])}",
        issue_prefix: "TRH",
        engineer_count: 1
      })

    {:ok, seed} = Issues.checkout_issue(seed, ceo, :ceo)
    {:ok, _active} = saturate_agent(engineer)

    assert {:ok, %{results: [%{type: "spawn_agent", agent_id: hire_id}]}} =
             AgentActions.execute(seed, ceo, [
               %{"type" => "spawn_agent", "name" => "Hired Engineer", "role" => "engineer"}
             ])

    on_exit(fn -> Cympho.AgentHeartbeat.stop_for_agent(hire_id) end)
    {:ok, hire} = Agents.get_agent(hire_id)
    assert hire.runtime_config["profile_id"] == "process-codex"

    # Only the binary path changes, so the run does not depend on a local
    # codex install; the pricing-relevant config is the hire's own.
    {:ok, hire} =
      Agents.update_agent(hire, %{config: Map.put(hire.config, "command", fake_codex!())})

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: hire.company_id,
        title: "First engineering task",
        status: :todo,
        assignee_id: hire.id,
        assigned_role: "engineer"
      })

    {:ok, issue} = Issues.checkout_issue(issue, hire)
    on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)

    assert {:ok, _context} = Runtime.preflight(issue, hire)
  end

  test "the LLMotions smoke CEO can start the pinned smoke issue" do
    original_key = Application.get_env(:cympho, :encryption_key)
    Application.put_env(:cympho, :encryption_key, String.duplicate("s", 32))

    on_exit(fn ->
      if original_key,
        do: Application.put_env(:cympho, :encryption_key, original_key),
        else: Application.delete_env(:cympho, :encryption_key)
    end)

    opts = [
      company_name: "T1 Review LLMotions #{System.unique_integer([:positive])}",
      issue_prefix: "TRL",
      api_key: "llmotions-secret-value",
      model: "gemini-3.5-flash-low"
    ]

    # The smoke company always runs under a USD block policy, so billing is an
    # explicit setup choice (D8).
    assert {:error, :llmotions_billing_required} = LLMotions.setup(opts)

    assert {:ok, report} =
             LLMotions.setup(
               opts ++
                 [billing: %{"input_usd_per_mtok" => "0.10", "output_usd_per_mtok" => "0.40"}]
             )

    issue = Issues.get_issue!(report.issue.id)
    on_exit(fn -> File.rm_rf(Cympho.Workspace.workspace_path(issue.id)) end)

    assert {:ok, _context} = Runtime.preflight(issue, report.agents.ceo)
  end

  defp saturate_agent(agent) do
    Issues.create_issue(%{
      title: "Saturate #{agent.name}",
      description: "Consumes the existing agent slot so the CEO may hire.",
      status: :in_progress,
      priority: :medium,
      company_id: agent.company_id,
      assignee_id: agent.id,
      assigned_role: to_string(agent.role)
    })
  end

  defp start_heartbeat_supervisor do
    case start_supervised({Cympho.AgentHeartbeat.Supervisor, []}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case start_supervised({Registry, keys: :unique, name: Cympho.AgentHeartbeat.Registry}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
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
