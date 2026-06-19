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
        config: %{"command" => "echo", "repo_capable" => true}
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
    run_id = Ecto.UUID.generate()

    assert {:ok, %RuntimeContext{} = context} = Runtime.preflight(issue, agent, run_id: run_id)

    assert context.issue_id == issue.id
    assert context.agent_id == agent.id
    assert context.run_id == run_id
    assert context.adapter == Cympho.Adapters.ProcessAdapter
    assert File.dir?(context.cwd)
    assert context.adapter_config["cwd"] == context.cwd
    assert context.adapter_config["workspace_path"] == context.cwd
    assert context.metadata["workspace_source"] == "issue_workspace"

    assert context.env["CYMPHO_RUN_ID"] == run_id
    assert context.env["CYMPHO_ISSUE_ID"] == issue.id
    assert context.env["CYMPHO_AGENT_ID"] == agent.id
    assert context.env["CYMPHO_COMPANY_ID"] == issue.company_id
    assert context.env["CYMPHO_WORKSPACE"] == context.cwd
    assert context.env["AGENT_HOME"] == context.cwd
    assert context.adapter_config["env"]["CYMPHO_RUN_ID"] == run_id
    assert context.adapter_config["env"]["CYMPHO_WORKSPACE"] == context.cwd
  end

  test "dispatch preflight blocks repo delivery on non-repo runtimes", %{
    company: company,
    issue: issue
  } do
    {:ok, chat_engineer} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Chat Runtime Engineer",
        role: :engineer,
        status: :idle,
        adapter: :openai_chat,
        config: %{
          "endpoint" => "https://dashscope.example.com/compatible-mode/v1/chat/completions",
          "model" => "qwen3.6-flash"
        }
      })

    {:ok, issue} = Issues.update_issue(issue, %{assigned_role: "engineer"})

    assert {:error, {:repo_delivery_runtime_unavailable, :engineer}} =
             Runtime.dispatchable?(issue, chat_engineer)
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

  test "preflight injects DashScope secret into OpenAI chat adapter config", %{
    company: company
  } do
    {:ok, ceo} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Qwen Runtime CEO",
        role: :ceo,
        status: :idle,
        adapter: :openai_chat,
        config: %{
          "endpoint" => "https://dashscope.aliyuncs.com/compatible-mode/v1",
          "model" => "qwen3.6-flash"
        }
      })

    {:ok, _secret} =
      Secrets.create_secret(%{
        company_id: company.id,
        scope: "company",
        key: "DASHSCOPE_API_KEY",
        value: "dashscope-test-key"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "CEO Qwen runtime smoke",
        status: :todo,
        assigned_role: "ceo",
        assignee_id: ceo.id
      })

    assert {:ok, context} = Runtime.preflight(issue, ceo)
    assert context.adapter == Cympho.Adapters.OpenAIChatAdapter
    assert context.adapter_config["api_key"] == "dashscope-test-key"

    assert context.adapter_config["endpoint"] ==
             "https://dashscope.aliyuncs.com/compatible-mode/v1"

    assert context.adapter_config["model"] == "qwen3.6-flash"
    assert context.adapter_config["env"]["DASHSCOPE_API_KEY"] == "dashscope-test-key"
  end

  test "preflight blocks clear adapter and model mismatches", %{
    company: company,
    issue: issue
  } do
    {:ok, ceo} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Mismatched Runtime CEO",
        role: :ceo,
        status: :idle,
        adapter: :openai_chat,
        config: %{
          "api_key" => "sk-test",
          "endpoint" => "https://api.openai.com/v1",
          "model" => "claude-sonnet-4-6"
        }
      })

    {:ok, issue} =
      Issues.update_issue(issue, %{
        assigned_role: "ceo",
        assignee_id: ceo.id
      })

    assert {:error, {:adapter_model_mismatch, message}} = Runtime.preflight(issue, ceo)
    assert message =~ "OpenAI chat endpoint"
    assert message =~ "claude-sonnet-4-6"
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

  describe "stage gate verification" do
    alias Cympho.ExecutionPolicies
    alias Cympho.Issues.ExecutionState

    setup %{company: _company, agent: _agent, issue: _issue} do
      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          name: "Test Policy",
          stage_configs: [
            %{
              "type" => "executor",
              "require_human" => false
            },
            %{
              "type" => "reviewer",
              "require_human" => true
            }
          ]
        })

      %{policy: policy}
    end

    test "preflight allows execution when no execution policy is set", %{
      agent: agent,
      issue: issue
    } do
      assert {:ok, _context} = Runtime.preflight(issue, agent)
    end

    test "preflight allows execution when execution state is empty", %{
      agent: agent,
      issue: issue,
      policy: policy
    } do
      {:ok, issue} =
        Issues.update_issue(issue, %{execution_policy_id: policy.id, execution_state: %{}})

      assert {:ok, _context} = Runtime.preflight(issue, agent)
    end

    test "preflight allows execution when execution state is nil", %{
      agent: agent,
      issue: issue,
      policy: policy
    } do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          execution_policy_id: policy.id,
          execution_state: nil
        })

      assert {:ok, _context} = Runtime.preflight(issue, agent)
    end

    test "preflight allows execution when stage is active and agent is current participant",
         %{
           agent: agent,
           issue: issue,
           policy: policy
         } do
      state = ExecutionState.initialize(policy, agent.id)

      {:ok, issue} =
        Issues.update_issue(issue, %{
          execution_policy_id: policy.id,
          execution_state: state
        })

      assert {:ok, _context} = Runtime.preflight(issue, agent)
    end

    test "preflight blocks when stage requires human intervention", %{
      agent: agent,
      issue: issue,
      policy: policy
    } do
      # Advance to reviewer stage which requires human
      state = ExecutionState.initialize(policy, agent.id)
      {:ok, state} = ExecutionState.advance(state, policy, agent.id)

      {:ok, issue} =
        Issues.update_issue(issue, %{
          execution_policy_id: policy.id,
          execution_state: state
        })

      assert {:error, {:stage_gate_blocked, :require_human}} = Runtime.preflight(issue, agent)
    end

    test "preflight blocks when stage is incomplete and agent is not current participant",
         %{
           company: company,
           agent: agent,
           issue: issue,
           policy: policy
         } do
      # Create a different agent
      {:ok, other_agent} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Other Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      # Initialize state at executor stage, set participant to other_agent
      state =
        ExecutionState.initialize(policy, agent.id)
        |> Map.put(:current_participant, other_agent.id)

      {:ok, issue} =
        Issues.update_issue(issue, %{
          execution_policy_id: policy.id,
          execution_state: state
        })

      # Try to run with agent who is not the current participant
      assert {:error, {:stage_gate_blocked, :stage_incomplete}} =
               Runtime.preflight(issue, agent)
    end

    test "preflight allows execution when stage is complete", %{
      agent: agent,
      issue: issue,
      policy: policy
    } do
      # Approve the current executor stage
      state =
        ExecutionState.initialize(policy, agent.id)
        |> ExecutionState.approve(agent.id)

      {:ok, issue} =
        Issues.update_issue(issue, %{
          execution_policy_id: policy.id,
          execution_state: state
        })

      assert {:ok, _context} = Runtime.preflight(issue, agent)
    end
  end
end
