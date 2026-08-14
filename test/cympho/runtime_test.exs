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
    refute Map.has_key?(context.metadata, "project_repository_fingerprint")

    assert context.env["CYMPHO_RUN_ID"] == run_id
    assert context.env["CYMPHO_ISSUE_ID"] == issue.id
    assert context.env["CYMPHO_AGENT_ID"] == agent.id
    assert context.env["CYMPHO_COMPANY_ID"] == issue.company_id
    assert context.env["CYMPHO_WORKSPACE"] == context.cwd
    assert context.env["AGENT_HOME"] == context.cwd
    assert context.adapter_config["env"]["CYMPHO_RUN_ID"] == run_id
    assert context.adapter_config["env"]["CYMPHO_WORKSPACE"] == context.cwd
  end

  test "preflight provisions a configured repo over an empty CLI scaffold", %{
    company: company,
    agent: agent,
    issue: issue
  } do
    repo_dir = local_git_repo!()

    {:ok, project} =
      Projects.create_project(%{
        company_id: company.id,
        name: "Runtime Repo Project",
        prefix: "RRP",
        settings: %{"repo_url" => repo_dir}
      })

    {:ok, issue} = Issues.update_issue(issue, %{project_id: project.id})
    path = Workspace.workspace_path(issue)

    for dirname <- [".git", ".agents", ".codex"] do
      File.mkdir_p!(Path.join(path, dirname))
    end

    on_exit(fn -> File.rm_rf!(repo_dir) end)

    assert {:ok, context} = Runtime.preflight(issue, agent)
    assert context.cwd == path
    assert File.read!(Path.join(path, "README.md")) == "# Runtime repo\n"
    assert {:ok, expected_fingerprint} = Workspace.repository_fingerprint(repo_dir)
    assert context.metadata["project_repository_fingerprint"] == expected_fingerprint

    assert {"true\n", 0} =
             System.cmd("git", ["-C", path, "rev-parse", "--is-inside-work-tree"])
  end

  test "preflight does not trust an app-wide fallback as a project repository", %{
    company: company,
    agent: agent,
    issue: issue
  } do
    repo_dir = local_git_repo!()
    original_default_repo = Application.get_env(:cympho, :workspace_default_repo)
    Application.put_env(:cympho, :workspace_default_repo, repo_dir)

    {:ok, project} =
      Projects.create_project(%{
        company_id: company.id,
        name: "Runtime Fallback Repo Project",
        prefix: "RFR"
      })

    {:ok, issue} = Issues.update_issue(issue, %{project_id: project.id})

    on_exit(fn ->
      File.rm_rf!(repo_dir)

      if original_default_repo do
        Application.put_env(:cympho, :workspace_default_repo, original_default_repo)
      else
        Application.delete_env(:cympho, :workspace_default_repo)
      end
    end)

    assert {:ok, context} = Runtime.preflight(issue, agent)
    assert File.read!(Path.join(context.cwd, "README.md")) == "# Runtime repo\n"
    refute Map.has_key?(context.metadata, "project_repository_fingerprint")
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

  test "preflight rejects nil company_id on either side", %{company: company, agent: agent} do
    {:ok, unscoped_issue} =
      Issues.create_issue(%{title: "Unscoped runtime issue", status: :todo})

    {:ok, unscoped_agent} =
      Agents.create_agent(%{
        name: "Unscoped Runtime Agent",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, scoped_issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "Scoped runtime issue",
        status: :todo
      })

    assert is_nil(unscoped_issue.company_id)
    assert is_nil(unscoped_agent.company_id)
    assert {:error, :company_mismatch} = Runtime.preflight(unscoped_issue, agent)
    assert {:error, :company_mismatch} = Runtime.preflight(scoped_issue, unscoped_agent)
    assert {:error, :company_mismatch} = Runtime.preflight(unscoped_issue, unscoped_agent)
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

  test "preflight injects LLMotions secret into OpenAI chat adapter config", %{
    company: company
  } do
    {:ok, ceo} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "LLMotions Runtime CEO",
        role: :ceo,
        status: :idle,
        adapter: :openai_chat,
        config: %{
          "endpoint" => "https://cli.llmotions.com/v1",
          "model" => "gemma-4-31b"
        }
      })

    {:ok, _secret} =
      Secrets.create_secret(%{
        company_id: company.id,
        scope: "company",
        key: "LLMOTIONS_API_KEY",
        value: "llmotions-test-key"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "CEO LLMotions runtime smoke",
        status: :todo,
        assigned_role: "ceo",
        assignee_id: ceo.id
      })

    assert {:ok, context} = Runtime.preflight(issue, ceo)
    assert context.adapter == Cympho.Adapters.OpenAIChatAdapter
    assert context.adapter_config["api_key"] == "llmotions-test-key"
    assert context.adapter_config["endpoint"] == "https://cli.llmotions.com/v1"
    assert context.adapter_config["model"] == "gemma-4-31b"
    assert context.adapter_config["env"]["LLMOTIONS_API_KEY"] == "llmotions-test-key"
  end

  test "preflight injects an LLMotions secret into a Codex LLMotions config", %{
    company: company
  } do
    original_bwrap = Application.get_env(:cympho, :codex_bwrap_path)
    Application.put_env(:cympho, :codex_bwrap_path, "/usr/bin/true")

    on_exit(fn ->
      if original_bwrap do
        Application.put_env(:cympho, :codex_bwrap_path, original_bwrap)
      else
        Application.delete_env(:cympho, :codex_bwrap_path)
      end
    end)

    repo_dir = local_git_repo!()
    on_exit(fn -> File.rm_rf!(repo_dir) end)

    {:ok, project} =
      Projects.create_project(%{
        company_id: company.id,
        name: "LLMotions Codex Project",
        prefix: "LCP",
        settings: %{"repo_url" => repo_dir}
      })

    {:ok, engineer} =
      Agents.create_agent(%{
        company_id: company.id,
        project_id: project.id,
        name: "LLMotions Codex Engineer",
        role: :engineer,
        status: :idle,
        adapter: :codex,
        config: %{
          "base_url" => "https://cli.llmotions.com/v1",
          "model" => "gpt-5.6-terra",
          "repo_capable" => true
        }
      })

    {:ok, _secret} =
      Secrets.create_secret(%{
        company_id: company.id,
        scope: "company",
        key: "LLMOTIONS_API_KEY",
        value: "llmotions-codex-test-key"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        project_id: project.id,
        title: "Codex LLMotions runtime smoke",
        status: :todo,
        assigned_role: "engineer",
        assignee_id: engineer.id
      })

    on_exit(fn -> File.rm_rf!(Workspace.workspace_path(issue.id)) end)

    assert {:ok, context} = Runtime.preflight(issue, engineer)
    assert context.adapter == Cympho.Adapters.CodexAdapter
    assert context.adapter_config["api_key"] == "llmotions-codex-test-key"
    assert context.adapter_config["base_url"] == "https://cli.llmotions.com/v1"
    assert context.adapter_config["model"] == "gpt-5.6-terra"
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

    missing_cwd = Path.join("/tmp", "cympho-missing-#{System.unique_integer()}")

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

  test "preflight rejects unsafe configured cwd", %{
    company: company,
    agent: agent,
    issue: issue
  } do
    {:ok, project} =
      Projects.create_project(%{
        company_id: company.id,
        name: "Unsafe Cwd Project",
        prefix: "UCD"
      })

    {:ok, project_workspace} =
      %Cympho.Workspaces.ProjectWorkspace{}
      |> Ecto.Changeset.change(%{
        company_id: company.id,
        project_id: project.id,
        name: "Unsafe workspace",
        cwd: "/etc"
      })
      |> Cympho.Repo.insert()

    {:ok, issue} =
      Issues.update_issue(issue, %{
        project_id: project.id,
        project_workspace_id: project_workspace.id
      })

    assert {:error, {:workspace_unavailable, "/etc"}} = Runtime.preflight(issue, agent)
  end

  test "does not inject a company OpenAI key to a private endpoint", %{
    company: company,
    issue: issue
  } do
    {:ok, ceo} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Private Endpoint CEO",
        role: :ceo,
        status: :idle,
        adapter: :openai_chat,
        config: %{
          "endpoint" => "http://169.254.169.254/",
          "model" => "gpt-4"
        }
      })

    {:ok, _} =
      Secrets.create_secret(%{
        company_id: company.id,
        scope: "company",
        key: "OPENAI_API_KEY",
        value: "company-openai-key"
      })

    {:ok, issue} =
      Issues.update_issue(issue, %{
        assigned_role: "ceo",
        assignee_id: ceo.id
      })

    assert {:error, :missing_api_key} = Runtime.preflight(issue, ceo)
  end

  describe "stage gate verification" do
    alias Cympho.ExecutionPolicies
    alias Cympho.Issues.ExecutionState

    setup %{company: company, agent: _agent, issue: _issue} do
      {:ok, policy} =
        ExecutionPolicies.create_execution_policy(%{
          name: "Test Policy",
          company_id: company.id,
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

    test "preflight uses JSONB-normalized execution_state after reload", %{
      company: company,
      agent: agent,
      issue: issue,
      policy: policy
    } do
      {:ok, other_agent} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Other Gate Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      state =
        ExecutionState.initialize(policy, agent.id)
        |> Map.put(:current_participant, other_agent.id)

      {:ok, issue} =
        Issues.update_issue(issue, %{
          execution_policy_id: policy.id,
          execution_state: state
        })

      reloaded = Repo.get(Cympho.Issues.Issue, issue.id)

      assert {:error, {:stage_gate_blocked, :stage_incomplete}} =
               Runtime.preflight(reloaded, agent)
    end
  end

  describe "provider environment preflight" do
    alias Cympho.Workspaces.Drivers.Fake

    setup %{company: company, issue: issue} do
      unique = System.unique_integer([:positive])

      {:ok, project} =
        Projects.create_project(%{
          company_id: company.id,
          name: "Provider Project #{unique}",
          prefix: "PRV"
        })

      cwd =
        Path.join("/tmp", "cympho-provider-#{unique}")
        |> tap(&File.mkdir_p!/1)

      on_exit(fn -> File.rm_rf(cwd) end)

      {:ok, project_workspace} =
        Workspaces.create_project_workspace(%{
          company_id: company.id,
          project_id: project.id,
          name: "Provider PW",
          cwd: cwd
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          project_id: project.id,
          project_workspace_id: project_workspace.id
        })

      %{
        project: project,
        project_workspace: project_workspace,
        issue: issue,
        cwd: cwd
      }
    end

    test "preflight acquires Fake env when provider_type is set", %{
      company: company,
      agent: agent,
      issue: issue,
      project: project,
      project_workspace: project_workspace,
      cwd: cwd
    } do
      {:ok, ew} =
        Workspaces.create_execution_workspace(%{
          name: "Fake Exec",
          status: "open",
          cwd: cwd,
          project_id: project.id,
          company_id: company.id,
          project_workspace_id: project_workspace.id,
          provider_type: "fake"
        })

      {:ok, issue} = Issues.update_issue(issue, %{execution_workspace_id: ew.id})

      assert {:ok, context} = Runtime.preflight(issue, agent)
      assert context.execution_workspace.id == ew.id
      assert is_binary(context.execution_workspace.provider_ref)
      assert String.starts_with?(context.execution_workspace.provider_ref, "fake-")
      assert context.metadata["provider_type"] == "fake"
      assert context.metadata["provider_ref"] == context.execution_workspace.provider_ref
      assert context.env["CYMPHO_PROVIDER_REF"] == context.execution_workspace.provider_ref

      reloaded = Workspaces.get_execution_workspace!(ew.id)
      assert reloaded.provider_ref == context.execution_workspace.provider_ref

      assert {:ok, _} = Fake.execute(reloaded.provider_ref, "echo preflight", %{})
    end

    test "preflight reuses existing provider_ref", %{
      company: company,
      agent: agent,
      issue: issue,
      project: project,
      project_workspace: project_workspace,
      cwd: cwd
    } do
      {:ok, ew} =
        Workspaces.create_execution_workspace(%{
          name: "Reuse Exec",
          status: "open",
          cwd: cwd,
          project_id: project.id,
          company_id: company.id,
          project_workspace_id: project_workspace.id,
          provider_type: "fake"
        })

      assert {:ok, acquired} = Workspaces.ensure_provider_environment(ew)
      ref = acquired.provider_ref

      {:ok, issue} = Issues.update_issue(issue, %{execution_workspace_id: acquired.id})

      assert {:ok, context} = Runtime.preflight(issue, agent)
      assert context.execution_workspace.provider_ref == ref
    end

    test "preflight fails closed on unknown provider", %{
      company: company,
      agent: agent,
      issue: issue,
      project: project,
      project_workspace: project_workspace,
      cwd: cwd
    } do
      {:ok, ew} =
        Workspaces.create_execution_workspace(%{
          name: "E2B Exec",
          status: "open",
          cwd: cwd,
          project_id: project.id,
          company_id: company.id,
          project_workspace_id: project_workspace.id,
          provider_type: "e2b"
        })

      {:ok, issue} = Issues.update_issue(issue, %{execution_workspace_id: ew.id})

      assert {:error, {:environment_provider_error, :unknown_provider}} =
               Runtime.preflight(issue, agent)

      reloaded = Workspaces.get_execution_workspace!(ew.id)
      assert is_nil(reloaded.provider_ref)
    end

    test "preflight without provider_type leaves local workspace unchanged", %{
      company: company,
      agent: agent,
      issue: issue,
      project: project,
      project_workspace: project_workspace,
      cwd: cwd
    } do
      {:ok, ew} =
        Workspaces.create_execution_workspace(%{
          name: "Local Exec",
          status: "open",
          cwd: cwd,
          project_id: project.id,
          company_id: company.id,
          project_workspace_id: project_workspace.id
        })

      {:ok, issue} = Issues.update_issue(issue, %{execution_workspace_id: ew.id})

      assert {:ok, context} = Runtime.preflight(issue, agent)
      assert context.execution_workspace.id == ew.id
      assert is_nil(context.execution_workspace.provider_ref)
      refute Map.has_key?(context.metadata, "provider_type")
      refute Map.has_key?(context.env, "CYMPHO_PROVIDER_REF")
    end

    test "release after preflight tears down Fake env", %{
      company: company,
      agent: agent,
      issue: issue,
      project: project,
      project_workspace: project_workspace,
      cwd: cwd
    } do
      {:ok, ew} =
        Workspaces.create_execution_workspace(%{
          name: "Terminal Exec",
          status: "open",
          cwd: cwd,
          project_id: project.id,
          company_id: company.id,
          project_workspace_id: project_workspace.id,
          provider_type: "fake"
        })

      {:ok, issue} = Issues.update_issue(issue, %{execution_workspace_id: ew.id})
      assert {:ok, context} = Runtime.preflight(issue, agent)
      ref = context.execution_workspace.provider_ref

      assert {:ok, released} =
               Workspaces.release_provider_environment(context.execution_workspace)

      assert is_nil(released.provider_ref)
      assert {:error, :released} = Fake.execute(ref, "echo", %{})
    end
  end

  defp local_git_repo! do
    repo_dir =
      Path.join(System.tmp_dir!(), "cympho_runtime_repo_#{System.unique_integer([:positive])}")

    File.mkdir_p!(repo_dir)
    assert {_output, 0} = System.cmd("git", ["init", "--quiet"], cd: repo_dir)

    assert {_output, 0} =
             System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo_dir)

    assert {_output, 0} = System.cmd("git", ["config", "user.name", "Cympho Test"], cd: repo_dir)
    File.write!(Path.join(repo_dir, "README.md"), "# Runtime repo\n")
    assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: repo_dir)
    assert {_output, 0} = System.cmd("git", ["commit", "--quiet", "-m", "initial"], cd: repo_dir)
    repo_dir
  end
end
