defmodule Cympho.RuntimePreflightTest do
  use Cympho.DataCase, async: false

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Issues
  alias Cympho.Projects
  alias Cympho.RuntimePreflight
  alias Cympho.Secrets
  alias Cympho.Workspaces

  test "treats a found Claude wrapper command as review-mode ready without exposing secrets" do
    agent = %{
      adapter: :claude_code,
      config: %{"command" => "echo"},
      runtime_config: %{
        "env" => %{"ANTHROPIC_MODEL" => "test-model", "ANTHROPIC_API_KEY" => "test-key"}
      }
    }

    preflight = RuntimePreflight.for_agent(agent, autonomy_enabled?: false)

    assert preflight.status == :review_mode
    assert preflight.label == "Review mode only"
    assert preflight.command == "echo"
    assert preflight.model == "test-model"
    assert Enum.any?(preflight.items, &(&1.label == "Runtime command" and &1.status == :ok))
    assert Enum.any?(preflight.items, &(&1.label == "Credentials" and &1.status == :ok))
    refute inspect(preflight) =~ "test-key"
  end

  test "surfaces Claude-compatible model and gateway endpoint without exposing the key" do
    agent = %{
      adapter: :claude_code,
      config: %{"command" => "echo"},
      runtime_config: %{
        "env" => %{
          "ANTHROPIC_API_KEY" => "secret-key",
          "ANTHROPIC_MODEL" => "qwen3.7-plus",
          "ANTHROPIC_BASE_URL" => "https://dashscope.aliyuncs.com/compatible-mode/v1"
        }
      }
    }

    preflight = RuntimePreflight.for_agent(agent, autonomy_enabled?: true)

    assert preflight.status == :ready
    assert preflight.model == "qwen3.7-plus"

    assert Enum.any?(
             preflight.items,
             &(&1.label == "Provider model" and &1.detail == "qwen3.7-plus")
           )

    assert Enum.any?(
             preflight.items,
             &(&1.label == "Gateway endpoint" and
                 &1.detail ==
                   "https://dashscope.aliyuncs.com/compatible-mode/v1")
           )

    refute inspect(preflight) =~ "secret-key"
  end

  test "surfaces OpenAI-compatible chat readiness without exposing the key" do
    agent = %{
      adapter: :openai_chat,
      config: %{
        "endpoint" => "https://dashscope.example.com/compatible-mode/v1/",
        "model" => "qwen3.7-plus"
      },
      runtime_config: %{"env" => %{"DASHSCOPE_API_KEY" => "secret-key"}}
    }

    preflight = RuntimePreflight.for_agent(agent, autonomy_enabled?: true)

    assert preflight.status == :ready
    assert preflight.model == "qwen3.7-plus"

    assert Enum.any?(
             preflight.items,
             &(&1.label == "Chat model" and &1.detail == "qwen3.7-plus")
           )

    assert Enum.any?(
             preflight.items,
             &(&1.label == "Configured endpoint" and
                 &1.detail == "https://dashscope.example.com/compatible-mode/v1/")
           )

    assert Enum.any?(
             preflight.items,
             &(&1.label == "Request URL" and
                 &1.detail ==
                   "https://dashscope.example.com/compatible-mode/v1/chat/completions")
           )

    assert Enum.any?(
             preflight.items,
             &(&1.label == "Chat completion key" and &1.status == :ok)
           )

    assert Enum.any?(
             preflight.items,
             &(&1.label == "Execution capability" and &1.status == :info and
                 &1.detail =~ "cannot edit files")
           )

    refute inspect(preflight) =~ "secret-key"
  end

  test "surfaces LLMotions chat readiness without exposing the key" do
    agent = %{
      adapter: :openai_chat,
      config: %{
        "endpoint" => "https://cli.llmotions.com/v1",
        "model" => "gemma-4-31b"
      },
      runtime_config: %{"env" => %{"LLMOTIONS_API_KEY" => "secret-key"}}
    }

    preflight = RuntimePreflight.for_agent(agent, autonomy_enabled?: true)

    assert preflight.status == :ready
    assert preflight.model == "gemma-4-31b"

    assert Enum.any?(
             preflight.items,
             &(&1.label == "Configured endpoint" and
                 &1.detail == "https://cli.llmotions.com/v1")
           )

    assert Enum.any?(
             preflight.items,
             &(&1.label == "Request URL" and
                 &1.detail == "https://cli.llmotions.com/v1/chat/completions")
           )

    assert Enum.any?(
             preflight.items,
             &(&1.label == "Chat completion key" and &1.status == :ok)
           )

    refute inspect(preflight) =~ "secret-key"
  end

  test "surfaces model and harness mismatch before launch" do
    agent = %{
      id: Ecto.UUID.generate(),
      adapter: :openai_chat,
      config: %{
        "endpoint" => "https://api.openai.com/v1",
        "model" => "claude-sonnet-4-6"
      },
      runtime_config: %{"env" => %{"OPENAI_API_KEY" => "secret-key"}}
    }

    preflight = RuntimePreflight.for_agent(agent, autonomy_enabled?: true)
    item = Enum.find(preflight.items, &(&1.label == "Model/harness match"))

    assert preflight.status == :attention
    assert item.status == :attention
    assert item.detail =~ "OpenAI chat endpoint"
    assert item.detail =~ "claude-sonnet-4-6"
    assert item.target_path == "/agents/#{agent.id}?tab=configuration#agent-runtime-profile"
    assert item.target_label == "Fix model"
    refute inspect(preflight) =~ "secret-key"
  end

  test "links missing DashScope chat credentials to DASHSCOPE_API_KEY" do
    without_chat_provider_env(fn ->
      agent = %{
        adapter: :openai_chat,
        config: %{
          "endpoint" => "https://dashscope.aliyuncs.com/compatible-mode/v1",
          "model" => "qwen3.6-flash"
        },
        runtime_config: %{}
      }

      preflight = RuntimePreflight.for_agent(agent, autonomy_enabled?: true)
      item = Enum.find(preflight.items, &(&1.label == "Chat completion key"))
      uri = URI.parse(item.target_path)
      query = URI.decode_query(uri.query)

      assert preflight.status == :attention
      assert item.status == :attention
      assert item.detail =~ "Add DASHSCOPE_API_KEY or OPENAI_API_KEY or ANTHROPIC_API_KEY"
      assert uri.path == "/settings/secrets"
      assert query["key"] == "DASHSCOPE_API_KEY"
      assert query["scope"] == "company"
      assert query["description"] == "Chat completion key for agent runtime"
    end)
  end

  test "links missing LLMotions chat credentials to LLMOTIONS_API_KEY" do
    without_chat_provider_env(fn ->
      agent = %{
        adapter: :openai_chat,
        config: %{
          "endpoint" => "https://cli.llmotions.com/v1",
          "model" => "gemma-4-31b"
        },
        runtime_config: %{}
      }

      preflight = RuntimePreflight.for_agent(agent, autonomy_enabled?: true)
      item = Enum.find(preflight.items, &(&1.label == "Chat completion key"))
      uri = URI.parse(item.target_path)
      query = URI.decode_query(uri.query)

      assert preflight.status == :attention
      assert item.status == :attention
      assert item.detail =~ "Add LLMOTIONS_API_KEY or OPENAI_API_KEY"
      assert uri.path == "/settings/secrets"
      assert query["key"] == "LLMOTIONS_API_KEY"
      assert query["scope"] == "company"
      assert query["description"] == "Chat completion key for agent runtime"
    end)
  end

  test "links missing generic chat credentials to OPENAI_API_KEY" do
    without_chat_provider_env(fn ->
      agent = %{
        adapter: :openai_chat,
        config: %{
          "endpoint" => "https://api.openai.example.com/v1",
          "model" => "gpt-compatible"
        },
        runtime_config: %{}
      }

      preflight = RuntimePreflight.for_agent(agent, autonomy_enabled?: true)
      item = Enum.find(preflight.items, &(&1.label == "Chat completion key"))
      uri = URI.parse(item.target_path)
      query = URI.decode_query(uri.query)

      assert preflight.status == :attention
      assert item.status == :attention
      assert item.detail =~ "Add OPENAI_API_KEY or DASHSCOPE_API_KEY or ANTHROPIC_API_KEY"
      assert uri.path == "/settings/secrets"
      assert query["key"] == "OPENAI_API_KEY"
      assert query["scope"] == "company"
    end)
  end

  test "blocks when a local process command is missing" do
    agent = %{
      adapter: :process,
      config: %{"command" => "__missing_cympho_test_command__", "model" => "custom"}
    }

    preflight = RuntimePreflight.for_agent(agent, autonomy_enabled?: true)

    assert preflight.status == :blocked
    assert preflight.label == "Blocked"

    assert Enum.any?(
             preflight.items,
             &(&1.label == "Command" and &1.status == :blocked and
                 &1.detail =~ "__missing_cympho_test_command__ was not found")
           )
  end

  test "process Codex preset flags missing OpenAI/Codex keys with setup path" do
    without_process_provider_env(fn ->
      agent = %{
        adapter: :process,
        config: %{
          "command" => "echo",
          "process_preset" => "codex",
          "model" => "gpt-5.5"
        },
        runtime_config: %{}
      }

      preflight = RuntimePreflight.for_agent(agent, autonomy_enabled?: true)
      item = Enum.find(preflight.items, &(&1.label == "OpenAI/Codex key"))
      uri = URI.parse(item.target_path)
      query = URI.decode_query(uri.query)

      assert preflight.status == :attention
      assert item.status == :attention
      assert item.detail =~ "Add OPENAI_API_KEY or CODEX_API_KEY"
      assert uri.path == "/settings/secrets"
      assert query["key"] == "OPENAI_API_KEY"
      assert query["scope"] == "company"
      assert query["description"] == "OpenAI/Codex key for agent runtime"
    end)
  end

  test "process Claude preset flags missing Anthropic key with setup path" do
    without_process_provider_env(fn ->
      agent = %{
        adapter: :process,
        config: %{
          "command" => "claude",
          "process_preset" => "claude_code",
          "model" => "sonnet"
        },
        runtime_config: %{}
      }

      preflight = RuntimePreflight.for_agent(agent, autonomy_enabled?: true)
      item = Enum.find(preflight.items, &(&1.label == "Anthropic key"))
      uri = URI.parse(item.target_path)
      query = URI.decode_query(uri.query)

      assert item.status == :attention
      assert item.detail =~ "Add ANTHROPIC_API_KEY"
      assert uri.path == "/settings/secrets"
      assert query["key"] == "ANTHROPIC_API_KEY"
      assert query["scope"] == "company"
      # Command may be blocked if claude is not on PATH; credentials attention still required.
      assert preflight.status in [:attention, :blocked]
    end)
  end

  test "process Codex preset is ready when OpenAI key is present in secrets" do
    without_process_provider_env(fn ->
      agent = %{
        adapter: :process,
        config: %{
          "command" => "echo",
          "process_preset" => "codex",
          "model" => "gpt-5.5"
        },
        runtime_config: %{}
      }

      preflight =
        RuntimePreflight.for_agent(agent,
          autonomy_enabled?: true,
          secret_keys: ["OPENAI_API_KEY"]
        )

      item = Enum.find(preflight.items, &(&1.label == "OpenAI/Codex key"))

      assert item.status == :ok
      assert item.detail =~ "Credential source is configured"
      assert preflight.status == :ready
    end)
  end

  test "links missing provider credentials to company secrets" do
    without_agrenting_env(fn ->
      agent = %{
        id: Ecto.UUID.generate(),
        adapter: :agrenting,
        config: %{},
        runtime_config: %{}
      }

      preflight = RuntimePreflight.for_agent(agent, autonomy_enabled?: true)

      item = Enum.find(preflight.items, &(&1.label == "Agrenting API key"))
      uri = URI.parse(item.target_path)
      query = URI.decode_query(uri.query)

      assert item.status == :attention
      assert item.target_label == "Add secret"
      assert uri.path == "/settings/secrets"
      assert query["key"] == "AGRENTING_API_KEY"
      assert query["scope"] == "company"
      assert query["description"] == "Agrenting API key for agent runtime"
    end)
  end

  test "for_issue links missing assigned-agent command to agent config" do
    {:ok, company} =
      Companies.create_company(%{name: "Preflight Command Co", slug: unique_slug()})

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Misconfigured Engineer",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "__missing_cympho_test_command__", "model" => "custom"},
        company_id: company.id
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Missing command issue",
        status: :todo,
        priority: :high,
        assigned_role: "engineer",
        assignee_id: agent.id,
        company_id: company.id
      })

    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: true)

    assert Enum.any?(
             preflight.items,
             &(&1.label == "Command" and &1.status == :blocked and
                 &1.target_path ==
                   "/agents/#{agent.id}?tab=configuration#agent-process-command" and
                 &1.target_label == "Edit command")
           )
  end

  test "for_issue reports paused company runtime before agent staffing blockers" do
    {:ok, company} =
      Companies.create_company(%{name: "Preflight Paused Co", slug: unique_slug()})

    {:ok, _paused} =
      Companies.execute_company_update(company, %{
        status: "paused",
        paused_at: DateTime.utc_now() |> DateTime.truncate(:second),
        paused_reason: "operator hold"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Paused runtime issue",
        status: :todo,
        priority: :high,
        assigned_role: "ceo",
        company_id: company.id
      })

    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: true)

    assert preflight.status == :blocked
    assert preflight.label == "Paused"
    assert preflight.summary =~ "Company runtime is paused"
    assert preflight.first_action.label == "Runtime paused"
    assert preflight.first_action.detail =~ "operator hold"
    assert preflight.first_action.target_path == "/dashboard"
    assert preflight.first_action.target_label == "Open runtime controls"
  end

  test "for_issue counts scoped secrets for assigned agent credentials" do
    {:ok, company} =
      Companies.create_company(%{name: "Preflight Secrets Co", slug: unique_slug()})

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Remote Engineer",
        role: :engineer,
        status: :idle,
        adapter: :agrenting,
        config: %{
          "agent_did" => "did:example:remote-engineer",
          "capability" => "implementation",
          "delivery_mode" => "push",
          "max_price" => "1.00"
        },
        company_id: company.id
      })

    {:ok, _secret} =
      Secrets.create_secret(%{
        company_id: company.id,
        scope: "company",
        key: "AGRENTING_API_KEY",
        value: "test-api-key",
        description: "Agrenting API key for agent runtime"
      })

    {:ok, _repo_secret} =
      Secrets.create_secret(%{
        company_id: company.id,
        scope: "company",
        key: "AGRENTING_REPO_ACCESS_TOKEN",
        value: "repo-token",
        description: "Agrenting repo access token"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Secret-backed issue",
        description: complete_delivery_brief(),
        status: :todo,
        priority: :high,
        assigned_role: "engineer",
        assignee_id: agent.id,
        company_id: company.id
      })

    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: true)

    assert preflight.status == :ready
    assert Enum.any?(preflight.items, &(&1.label == "Agrenting API key" and &1.status == :ok))
    assert Enum.any?(preflight.items, &(&1.label == "Delivery mode" and &1.status == :ok))
    refute inspect(preflight) =~ "test-api-key"
    refute inspect(preflight) =~ "repo-token"
  end

  test "for_issue warns when Agrenting output mode is assigned to repo delivery" do
    {:ok, company} =
      Companies.create_company(%{name: "Preflight Agrenting Output Co", slug: unique_slug()})

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Output Remote Engineer",
        role: :engineer,
        status: :idle,
        adapter: :agrenting,
        config: %{
          "agent_did" => "did:example:output-remote-engineer",
          "capability" => "implementation",
          "max_price" => "1.00"
        },
        company_id: company.id
      })

    {:ok, _secret} =
      Secrets.create_secret(%{
        company_id: company.id,
        scope: "company",
        key: "AGRENTING_API_KEY",
        value: "test-api-key",
        description: "Agrenting API key for agent runtime"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Remote repo delivery without push mode",
        description: complete_delivery_brief(),
        status: :todo,
        priority: :high,
        assigned_role: "engineer",
        assignee_id: agent.id,
        company_id: company.id
      })

    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: true)

    assert preflight.status == :attention
    assert preflight.first_action.label == "Repo-capable runtime"
    assert preflight.first_action.detail =~ "not configured for repo-delivery capability"

    assert Enum.any?(
             preflight.items,
             &(&1.label == "Delivery mode" and &1.status == :info and
                 &1.detail =~ "Output mode")
           )

    refute inspect(preflight) =~ "test-api-key"
  end

  test "for_issue warns when repo delivery is assigned to a text-only chat adapter" do
    {:ok, company} =
      Companies.create_company(%{name: "Preflight Text Only Repo Co", slug: unique_slug()})

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Chat Engineer",
        role: :engineer,
        status: :idle,
        adapter: :openai_chat,
        config: %{
          "endpoint" => "https://dashscope.example.com/compatible-mode/v1/chat/completions",
          "model" => "qwen3.6-flash"
        },
        company_id: company.id
      })

    {:ok, _secret} =
      Secrets.create_secret(%{
        company_id: company.id,
        scope: "company",
        key: "DASHSCOPE_API_KEY",
        value: "test-api-key",
        description: "DashScope key"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Implement owner-intake scaffold button",
        status: :todo,
        priority: :high,
        assigned_role: "engineer",
        assignee_id: agent.id,
        company_id: company.id
      })

    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: true)

    assert preflight.status == :attention
    assert preflight.agent_id == agent.id
    assert preflight.first_action.label == "Repo-capable runtime"
    assert preflight.first_action.detail =~ "not configured for repo-delivery capability"
    assert preflight.first_action.detail =~ "file changes, tests, branches, or PRs"

    assert preflight.first_action.target_path ==
             "/agents/#{agent.id}?tab=configuration#agent-runtime-profile"

    assert preflight.first_action.target_label == "Open runtime profile"

    assert Enum.any?(
             preflight.items,
             &(&1.label == "Chat completion key" and &1.status == :ok)
           )

    refute inspect(preflight) =~ "test-api-key"
  end

  test "for_issue falls back to CTO when engineer lane has only text-only capacity" do
    {:ok, company} =
      Companies.create_company(%{name: "Preflight CTO Fallback Co", slug: unique_slug()})

    {:ok, _chat_engineer} =
      Agents.create_agent(%{
        name: "Chat Engineer",
        role: :engineer,
        status: :idle,
        adapter: :openai_chat,
        config: %{
          "endpoint" => "https://dashscope.example.com/compatible-mode/v1/chat/completions",
          "model" => "qwen3.6-flash"
        },
        company_id: company.id
      })

    {:ok, cto} =
      Agents.create_agent(%{
        name: "Fallback CTO",
        role: :cto,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo", "model" => "custom"},
        company_id: company.id
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Implement fallback routing",
        description: complete_delivery_brief(),
        status: :todo,
        priority: :high,
        assigned_role: "engineer",
        company_id: company.id
      })

    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: true)

    assert preflight.agent_id == cto.id
    assert preflight.agent_name == "Fallback CTO"
    assert preflight.agent_role == :cto
    assert preflight.routed? == true
    assert preflight.summary =~ "Auto-route would choose Fallback CTO"
  end

  test "for_issue warns when repo delivery is assigned to a no-op custom process" do
    {:ok, company} =
      Companies.create_company(%{name: "Preflight Noop Process Co", slug: unique_slug()})

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Echo Process Engineer",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo", "model" => "custom"},
        company_id: company.id
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Implement owner-intake scaffold button",
        description: complete_delivery_brief(),
        status: :todo,
        priority: :high,
        assigned_role: "engineer",
        assignee_id: agent.id,
        company_id: company.id
      })

    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: true)

    assert preflight.status == :attention
    assert preflight.first_action.label == "Repo-capable runtime"
    assert preflight.first_action.detail =~ "not configured for repo-delivery capability"
    assert preflight.first_action.detail =~ "file changes, tests, branches, or PRs"

    assert preflight.first_action.target_path ==
             "/agents/#{agent.id}?tab=configuration#agent-runtime-profile"
  end

  test "for_issue warns when local repo delivery would use a shared project workspace" do
    {:ok, company} =
      Companies.create_company(%{name: "Preflight Shared Workspace Co", slug: unique_slug()})

    {:ok, project} =
      Projects.create_project(%{
        name: "Shared Workspace Project",
        prefix: unique_prefix(),
        company_id: company.id
      })

    {:ok, project_workspace} =
      Workspaces.create_project_workspace(%{
        name: "Primary shared checkout",
        cwd: "/tmp/cympho/shared-checkout-#{System.unique_integer([:positive])}",
        is_primary: true,
        project_id: project.id,
        company_id: company.id
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Workspace-aware Engineer",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo", "model" => "custom", "repo_capable" => true},
        company_id: company.id
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Parallel repo delivery",
        description: complete_delivery_brief(),
        status: :todo,
        priority: :high,
        assigned_role: "engineer",
        assignee_id: agent.id,
        company_id: company.id,
        project_id: project.id
      })

    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: true)
    item = Enum.find(preflight.items, &(&1.label == "Workspace isolation"))

    assert preflight.status == :attention
    assert preflight.first_action.label == "Workspace isolation"
    assert item.status == :attention
    assert item.detail =~ "shared project workspace"
    assert item.detail =~ "Primary shared checkout"
    assert item.detail =~ "execution workspace or worktree"
    assert item.target_path == "/workspaces/#{project_workspace.id}"
    assert item.target_label == "Open workspace"
  end

  test "for_issue accepts preloaded non-secret credential metadata" do
    {:ok, company} =
      Companies.create_company(%{name: "Preflight Cached Secrets Co", slug: unique_slug()})

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Cached Remote Engineer",
        role: :engineer,
        status: :idle,
        adapter: :agrenting,
        config: %{
          "agent_did" => "did:example:cached-remote-engineer",
          "capability" => "implementation",
          "delivery_mode" => "push",
          "max_price" => "1.00"
        },
        company_id: company.id
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Secret-cache-backed issue",
        description: complete_delivery_brief(),
        status: :todo,
        priority: :high,
        assigned_role: "engineer",
        assignee_id: agent.id,
        company_id: company.id
      })

    preflight =
      RuntimePreflight.for_issue(issue,
        autonomy_enabled?: true,
        secret_summary_by_agent: %{
          agent.id => %{count: 2, keys: ["AGRENTING_API_KEY", "AGRENTING_REPO_ACCESS_TOKEN"]}
        }
      )

    assert preflight.status == :ready
    assert Enum.any?(preflight.items, &(&1.label == "Agrenting API key" and &1.status == :ok))
    refute inspect(preflight) =~ "secret-cache"
  end

  test "for_issue warns when delegated repo work has a thin delivery brief" do
    {:ok, company} =
      Companies.create_company(%{name: "Preflight Thin Delivery Co", slug: unique_slug()})

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Thin Brief Engineer",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo", "model" => "custom", "repo_capable" => true},
        company_id: company.id
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Build vague thing",
        description: "Do it.",
        status: :todo,
        priority: :high,
        assigned_role: "engineer",
        assignee_id: agent.id,
        company_id: company.id
      })

    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: true)

    assert preflight.status == :attention
    assert preflight.first_action.label == "Delivery brief"
    assert preflight.first_action.detail =~ "Too thin for delivery (0/4 signals)"
    assert preflight.first_action.detail =~ "Acceptance criteria"
    assert preflight.first_action.target_path == "/issues/#{issue.id}#issue-description"
    assert preflight.first_action.target_label == "Edit issue brief"
  end

  test "for_issue ignores unrelated scoped secrets for provider credentials" do
    without_agrenting_env(fn ->
      {:ok, company} =
        Companies.create_company(%{name: "Preflight Wrong Secret Co", slug: unique_slug()})

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Remote Engineer Wrong Secret",
          role: :engineer,
          status: :idle,
          adapter: :agrenting,
          config: %{
            "agent_did" => "did:example:remote-engineer",
            "capability" => "implementation",
            "max_price" => "1.00"
          },
          company_id: company.id
        })

      {:ok, _secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "OPENAI_API_KEY",
          value: "wrong-provider-key",
          description: "Wrong provider key"
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Wrong secret issue",
          status: :todo,
          priority: :high,
          assigned_role: "engineer",
          assignee_id: agent.id,
          company_id: company.id
        })

      preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: true)
      item = Enum.find(preflight.items, &(&1.label == "Agrenting API key"))
      uri = URI.parse(item.target_path)
      query = URI.decode_query(uri.query)

      assert preflight.status == :attention
      assert item.status == :attention
      assert query["return_to"] == "/issues/#{issue.id}"
      refute inspect(preflight) =~ "wrong-provider-key"
    end)
  end

  test "for_issue blocks when the assigned agent is not dispatch-eligible" do
    {:ok, company} = Companies.create_company(%{name: "Preflight Co", slug: unique_slug()})

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Busy Engineer",
        role: :engineer,
        status: :running,
        adapter: :process,
        config: %{"command" => "echo", "model" => "custom"},
        company_id: company.id
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Busy assigned issue",
        status: :todo,
        priority: :high,
        assigned_role: "engineer",
        assignee_id: agent.id,
        company_id: company.id
      })

    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: true)

    assert preflight.status == :blocked
    assert preflight.label == "No agent"
    assert preflight.summary =~ "Busy Engineer is running"
    assert preflight.first_action.label == "Dispatch eligibility"
    assert preflight.first_action.detail =~ "return idle"
  end

  test "for_issue points CEO-lane work without a CEO agent to CEO setup" do
    {:ok, company} = Companies.create_company(%{name: "No CEO Co", slug: unique_slug()})

    {:ok, issue} =
      Issues.create_issue(%{
        title: "CEO lane without agent",
        status: :todo,
        priority: :high,
        assigned_role: "ceo",
        company_id: company.id
      })

    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: true)

    assert preflight.status == :blocked
    assert preflight.label == "No agent"
    assert preflight.agent_role == :ceo
    assert preflight.first_action.label == "Dispatch eligibility"
    assert preflight.first_action.detail =~ "eligible CEO"
    assert preflight.first_action.target_path == "/agents/new"
    assert preflight.first_action.target_label == "Add CEO agent"
  end

  defp unique_slug, do: "preflight-#{System.unique_integer([:positive])}"

  defp without_agrenting_env(fun), do: without_env(~w(AGRENTING_API_KEY), fun)

  defp without_chat_provider_env(fun) do
    keys = ~w(DASHSCOPE_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY LLMOTIONS_API_KEY)
    without_env(keys, fun)
  end

  defp without_process_provider_env(fun) do
    keys = ~w(OPENAI_API_KEY CODEX_API_KEY ANTHROPIC_API_KEY)
    without_env(keys, fun)
  end

  defp without_env(keys, fun) do
    original = Map.new(keys, &{&1, System.get_env(&1)})

    Enum.each(keys, &System.delete_env/1)

    try do
      fun.()
    after
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp unique_prefix do
    suffix =
      System.unique_integer([:positive])
      |> Integer.digits(26)
      |> Enum.map_join(fn digit -> <<?A + digit>> end)
      |> String.slice(0, 8)

    "P" <> suffix
  end

  defp complete_delivery_brief do
    """
    Acceptance criteria:
    - Scoped implementation satisfies the parent request.

    Evidence required:
    - Pull request or work product is linked.

    Verification required:
    - Focused test or manual smoke path is recorded.

    Definition of done:
    - Ready for review after evidence and verification are attached.
    """
  end
end
