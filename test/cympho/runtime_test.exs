defmodule Cympho.RuntimeTest do
  use Cympho.DataCase, async: false

  alias Cympho.{
    Agents,
    Companies,
    Finances,
    Issues,
    Projects,
    Runtime,
    RuntimeContext,
    Secrets,
    Workspace,
    Workspaces
  }

  setup do
    unique = System.unique_integer([:positive])
    original_key = Application.get_env(:cympho, :encryption_key)
    Application.put_env(:cympho, :encryption_key, String.duplicate("r", 32))

    {:ok, company} =
      Companies.create_company(%{
        name: "Runtime Company #{unique}",
        slug: "runtime-company-#{unique}",
        issue_prefix: "RT"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Runtime Engineer",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "Runtime issue",
        status: :todo
      })

    on_exit(fn ->
      File.rm_rf(Workspace.workspace_path(issue.id))

      if original_key do
        Application.put_env(:cympho, :encryption_key, original_key)
      else
        Application.delete_env(:cympho, :encryption_key)
      end
    end)

    %{company: company, agent: agent, issue: issue}
  end

  test "preflight returns adapter, cwd, and runtime context", %{agent: agent, issue: issue} do
    assert {:ok, %RuntimeContext{} = context} = Runtime.preflight(issue, agent)

    assert context.issue_id == issue.id
    assert context.agent_id == agent.id
    assert context.adapter == Cympho.Adapters.ProcessAdapter
    assert File.dir?(context.cwd)
    assert context.adapter_config["cwd"] == context.cwd
    assert context.metadata["workspace_source"] == "issue_workspace"
  end

  test "preflight blocks paused companies", %{company: company, agent: agent, issue: issue} do
    assert {:ok, _company} = Companies.pause_company(company, "operator pause")

    assert {:error, :company_paused} = Runtime.preflight(issue, agent)
  end

  test "preflight blocks exhausted blocking budget policies", %{
    company: company,
    agent: agent,
    issue: issue
  } do
    assert {:ok, _usage} =
             Finances.record_token_usage(%{
               company_id: company.id,
               provider: "openai",
               model: "test",
               input_tokens: 1,
               output_tokens: 1,
               cost_usd: Decimal.new("1.00")
             })

    assert {:ok, policy} =
             Finances.create_budget_policy(%{
               company_id: company.id,
               scope: "company",
               period: "monthly",
               budget_limit_usd: Decimal.new("1.00"),
               action_on_exceed: "block"
             })

    assert {:error, {:budget_blocked, info}} = Runtime.preflight(issue, agent)
    assert info.policy_id == policy.id
    assert info.scope == "company"
  end

  test "preflight resolves company and agent secrets into env", %{
    company: company,
    agent: agent,
    issue: issue
  } do
    assert {:ok, _secret} =
             Secrets.create_secret(%{
               company_id: company.id,
               scope: "company",
               key: "OPENAI_API_KEY",
               value: "company-key"
             })

    assert {:ok, _secret} =
             Secrets.create_secret(%{
               company_id: company.id,
               scope: "agent",
               scope_id: agent.id,
               key: "AGENT_TOKEN",
               value: "agent-key"
             })

    assert {:ok, context} = Runtime.preflight(issue, agent)
    assert context.env["OPENAI_API_KEY"] == "company-key"
    assert context.env["AGENT_TOKEN"] == "agent-key"
    assert context.adapter_config["env"]["AGENT_TOKEN"] == "agent-key"
  end

  test "preflight rejects configured workspaces whose cwd is missing", %{
    company: company,
    agent: agent,
    issue: issue
  } do
    {:ok, project} =
      Projects.create_project(%{
        company_id: company.id,
        name: "Runtime Project",
        prefix: "RTA"
      })

    missing_cwd = Path.join(System.tmp_dir!(), "cympho-missing-#{System.unique_integer()}")

    {:ok, project_workspace} =
      Workspaces.create_project_workspace(%{
        company_id: company.id,
        project_id: project.id,
        name: "Missing workspace",
        cwd: missing_cwd
      })

    {:ok, issue} =
      Issues.update_issue(issue, %{
        project_id: project.id,
        project_workspace_id: project_workspace.id
      })

    assert {:error, {:workspace_unavailable, ^missing_cwd}} = Runtime.preflight(issue, agent)
  end
end
