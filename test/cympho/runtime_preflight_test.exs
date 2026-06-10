defmodule Cympho.RuntimePreflightTest do
  use Cympho.DataCase, async: true

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Issues
  alias Cympho.RuntimePreflight
  alias Cympho.Secrets

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
        "endpoint" => "https://dashscope.example.com/v1/chat/completions",
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
             &(&1.label == "Chat endpoint" and
                 &1.detail == "https://dashscope.example.com/v1/chat/completions")
           )

    assert Enum.any?(
             preflight.items,
             &(&1.label == "Chat completion key" and &1.status == :ok)
           )

    refute inspect(preflight) =~ "secret-key"
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

  test "links missing provider credentials to company secrets" do
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
                 &1.target_path == "/agents/#{agent.id}#agent-process-command" and
                 &1.target_label == "Edit command")
           )
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
        title: "Secret-backed issue",
        status: :todo,
        priority: :high,
        assigned_role: "engineer",
        assignee_id: agent.id,
        company_id: company.id
      })

    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: true)

    assert preflight.status == :ready
    assert Enum.any?(preflight.items, &(&1.label == "Agrenting API key" and &1.status == :ok))
    refute inspect(preflight) =~ "test-api-key"
  end

  test "for_issue ignores unrelated scoped secrets for provider credentials" do
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
end
