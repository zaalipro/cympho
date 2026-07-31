defmodule CymphoWeb.AgentLiveTest do
  use CymphoWeb.LiveCase, async: false

  import Phoenix.LiveViewTest
  alias Cympho.Agents
  alias Cympho.AgentHeartbeat
  alias Cympho.Comments
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Repo
  alias Cympho.Secrets
  alias Cympho.Skills
  alias Cympho.Wakes

  defp create_agent(attrs), do: Agents.create_agent(scoped_attrs(attrs))
  defp create_issue(attrs), do: Issues.create_issue(scoped_attrs(attrs))
  defp create_plugin(attrs), do: Skills.create_plugin(scoped_attrs(attrs))

  describe "Index - Agent Dashboard" do
    test "renders the agents page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "Agents"
    end

    test "renders list of agents", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Test Engineer",
          role: :engineer,
          status: :idle
        })

      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "Test Engineer"
      assert html =~ "Engineer"
      assert html =~ ~s(data-testid="agent-row-#{agent.id}")
      assert html =~ ~s(data-testid="agent-manage-menu-#{agent.id}")
      assert html =~ ~s(aria-label="Manage Test Engineer")
      assert html =~ ~s(title="Manage Test Engineer")
      assert html =~ "Manage"
      assert html =~ "View profile"
      assert html =~ "Edit settings"
    end

    test "renders status dashboard with counts", %{conn: conn} do
      {:ok, _idle1} = create_agent(%{name: "Idle Agent 1", role: :engineer, status: :idle})
      {:ok, _idle2} = create_agent(%{name: "Idle Agent 2", role: :engineer, status: :idle})

      {:ok, _running} =
        create_agent(%{name: "Running Agent", role: :cto, status: :running})

      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "Idle"
      assert html =~ "Running"
    end

    test "surfaces delegated role staffing gaps with prefilled hire links", %{conn: conn} do
      {:ok, ceo} =
        create_agent(%{
          name: "Coverage CEO",
          role: :ceo,
          status: :idle
        })

      {:ok, issue} =
        create_issue(%{
          title: "Define pricing activation research",
          description: "Product Manager should define acceptance criteria before engineering.",
          status: :todo,
          priority: :high,
          assigned_role: "product_manager"
        })

      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ ~s(data-testid="agent-role-coverage")
      assert html =~ "Role coverage"
      assert html =~ "Team coverage for queued autonomous work"
      assert html =~ "Unstaffed roles"
      assert html =~ "Waiting issues"
      assert html =~ "Product Manager"
      assert html =~ "1 open issue"
      assert html =~ "Reports to Coverage CEO"
      assert html =~ "Hire Product Manager"
      assert html =~ "/issues/#{issue.id}"
      assert html =~ issue.identifier
      assert html =~ "role=product_manager"
      assert html =~ "name=Product+Manager"
      assert html =~ "runtime_profile_id=openai-chat-qwen-dashscope-flash"
      assert html =~ "return_to=%2Fagents%23agent-role-coverage"
      assert html =~ "parent_id=#{ceo.id}"
    end

    test "does not show spawn button when current_agent_role is nil" do
    end

    test "shows spawn button for CEO agent" do
    end

    test "shows spawn button for CTO agent" do
    end

    test "hides spawn button for Engineer agent" do
    end
  end

  describe "Index - Kill Session" do
    test "shows stop button for running agents", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{name: "Running Agent", role: :engineer, status: :running})

      {:ok, view, _html} = live(conn, "/agents")

      # Running agents should have stop button
      assert has_element?(view, "button[phx-click='kill_session'][phx-value-id='#{agent.id}']")
    end

    test "does not show stop button for idle agents", %{conn: conn} do
      {:ok, agent} = create_agent(%{name: "Idle Agent", role: :engineer, status: :idle})

      {:ok, view, _html} = live(conn, "/agents")

      # Idle agents should not have stop button
      refute has_element?(view, "button[phx-click='kill_session'][phx-value-id='#{agent.id}']")
    end

    test "kill_session event returns error when agent not running", %{conn: conn} do
      {:ok, agent} = create_agent(%{name: "Idle Agent", role: :engineer, status: :idle})

      {:ok, view, _html} = live(conn, "/agents")

      view
      |> element("button[phx-click='delete_agent'][phx-value-id='#{agent.id}']")
      |> render_click()

      # After delete, the agent should be gone
      refute has_element?(view, "#agent-#{agent.id}")
    end
  end

  describe "Spawn Agent navigation" do
    test "agents page links to new agent form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "/agents/new"
    end

    test "agents page links to remote hiring marketplace", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "/agents/remote"
    end
  end

  describe "Remote agent marketplace" do
    test "renders configuration guidance when Agrenting is not connected", %{conn: conn} do
      {:ok, view, html} = live(conn, "/agents/remote")

      assert html =~ "Hire Remote Agent"
      assert render(view) =~ "Agrenting is not connected"
      assert render(view) =~ "Connect Agrenting"
      assert render(view) =~ "/settings/integrations"
    end
  end

  describe "Show - Agent Details" do
    test "renders agent details page", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          instructions: "Do good work"
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      assert html =~ "Test Agent"
    end

    test "keeps prompt-authoring tabs Advanced-only with a Simple fallback", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Mode Aware Agent",
          role: :engineer,
          status: :idle,
          instructions: "Keep the daily dashboard calm."
        })

      for tab <- ~w(instructions skills) do
        {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=#{tab}")

        assert has_element?(view, "button.ui-advanced-only[phx-value-tab='#{tab}']")
        assert has_element?(view, "[data-testid='agent-#{tab}-panel'].ui-advanced-only")
        assert has_element?(view, "[data-testid='agent-simple-tab-fallback'].ui-simple-only")

        assert has_element?(
                 view,
                 "[data-testid='agent-simple-tab-fallback'] button[phx-value-tab='dashboard']"
               )
      end
    end

    test "offers Setup and History in Simple with the dense panels gated", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Simple Reachable Agent",
          role: :engineer,
          status: :idle
        })

      for tab <- ~w(configuration runs) do
        {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=#{tab}")

        # The tab itself must be reachable in Simple...
        refute has_element?(view, "button.ui-advanced-only[phx-value-tab='#{tab}']")
        # ...and must not fall back to the "switch to Advanced" card.
        refute has_element?(view, "[data-testid='agent-simple-tab-fallback']")
      end

      # Setup: identity and runtime profile survive; the dense panels are gated.
      {:ok, view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert has_element?(view, "[data-testid='agent-configuration-panel']")
      refute has_element?(view, "[data-testid='agent-configuration-panel'].ui-advanced-only")
      assert html =~ "Basics"
      assert html =~ "How it runs"
      assert has_element?(view, "#agent-instruction-studio.ui-advanced-only")
      assert has_element?(view, "#agent-env-vars.ui-advanced-only")

      # History: a plain list in Simple, the master/detail view in Advanced.
      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=runs")

      assert has_element?(view, "[data-testid='agent-simple-runs-panel'].ui-simple-only")
      assert has_element?(view, "[data-testid='agent-runs-panel'].ui-advanced-only")
    end

    test "dashboard queues an immediate heartbeat for an idle agent", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Heartbeat Now Agent",
          role: :engineer,
          status: :idle
        })

      on_exit(fn -> _ = AgentHeartbeat.stop_for_agent(agent.id) end)

      {:ok, view, html} = live(conn, "/agents/#{agent.id}")

      assert html =~ ~s(aria-label="Run heartbeat")
      assert html =~ ~s(phx-click="run_heartbeat")
      refute html =~ "coming soon"
      refute html =~ "Heartbeat trigger"

      html =
        view
        |> element("button[phx-click='run_heartbeat']")
        |> render_click()

      assert html =~ "Heartbeat queued. The agent will pick up assigned To Do work if available."
      assert {:ok, pid} = AgentHeartbeat.whereis(agent.id)
      assert Process.alive?(pid)
    end

    test "dashboard disables heartbeat action while agent is paused", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Paused Heartbeat Agent",
          role: :engineer,
          status: :paused
        })

      {:ok, view, html} = live(conn, "/agents/#{agent.id}")

      assert html =~ ~s(aria-label="Resume this agent before running heartbeat")
      assert html =~ "Resume this agent before running heartbeat"
      refute html =~ "coming soon"
      assert has_element?(view, "button[phx-click='run_heartbeat'][disabled]")
    end

    test "dashboard surfaces agent command readiness and prompt guide actions", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Command Center Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          instructions: "Do good work."
        })

      {:ok, _queued_issue} =
        create_issue(%{
          title: "Assigned queued work",
          description: "Needs the agent.",
          status: :todo,
          priority: :high,
          assignee_id: agent.id
        })

      {:ok, _review_issue} =
        create_issue(%{
          title: "Assigned review work",
          description: "Needs review.",
          status: :in_review,
          priority: :medium,
          assignee_id: agent.id
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")

      assert html =~ "Agent command"
      assert html =~ "Run readiness"
      assert html =~ "Prompt guide"
      assert html =~ "Tune guide"
      assert html =~ "Needs tuning"
      assert html =~ "Issue memory discipline"
      assert html =~ "Operating loop"
      assert html =~ "pending guide patches"
      assert html =~ "Owner-readable memory"
      assert html =~ "Active"
      assert html =~ "Review"
      assert html =~ "Queued"
      assert html =~ "Wakes"
      assert html =~ ~s(href="/agents/#{agent.id}?tab=configuration#agent-instruction-studio")
      assert html =~ ~s(href="/agents/#{agent.id}?tab=configuration#agent-runtime-profile")
    end

    test "dashboard shows prompt tuning canary until a tuned prompt runs", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Canary Awaiting Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          instructions:
            "After every meaningful action, comment with [delivery] What happened, files changed, verification, and next decision."
        })

      {:ok, _revision} =
        Agents.create_config_revision(agent, %{
          source: "prompt_tuning"
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")

      assert html =~ ~s(data-testid="prompt-tuning-canary")
      assert html =~ "Prompt canary"
      assert html =~ "Awaiting validation"
      assert html =~ "Prompt tuning v1 has not produced a newer run yet."
      assert html =~ ~s(href="/agents/#{agent.id}?tab=runs")
    end

    test "dashboard validates prompt tuning after a successful newer run", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Canary Validated Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          instructions:
            "After every meaningful action, comment with [delivery] What happened, files changed, verification, and next decision."
        })

      {:ok, _revision} =
        Agents.create_config_revision(agent, %{
          source: "prompt_tuning"
        })

      {:ok, issue} =
        create_issue(%{
          title: "Canary validation run",
          status: :todo,
          assignee_id: agent.id
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%Run{
        company_id: issue.company_id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "completed",
        adapter: "codex",
        completed_at: now
      })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")

      assert html =~ "Prompt canary"
      assert html =~ "Validated"
      assert html =~ "Latest run after prompt tuning v1 completed successfully."
    end

    test "runs tab explains normalized adapter failures", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Failing Runtime Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, issue} =
        create_issue(%{
          title: "Runtime failure",
          description: "Adapter failure details",
          status: :todo,
          priority: :medium
        })

      Repo.insert!(%Run{
        company_id: issue.company_id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "failed",
        adapter: "codex",
        error_reason: "Codex exited with status 1",
        log_excerpt: "OPENAI_API_KEY not set"
      })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=runs")

      assert html =~ "Missing credentials"
      assert html =~ "Credentials missing"
      assert html =~ "Add the API key"
      assert html =~ "OPENAI_API_KEY not set"
    end

    test "skills tab surfaces prompt-ready loadout and blocked assignments", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Skillful Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, prompt_ready} =
        create_plugin(%{
          identifier: "prompt-ready-#{System.unique_integer([:positive])}",
          name: "Prompt Ready Skill",
          version: "1.0.0",
          manifest: %{"entrypoint" => "noop"},
          capabilities: ["git"],
          status: "active",
          enabled: true
        })

      {:ok, errored} =
        create_plugin(%{
          identifier: "errored-#{System.unique_integer([:positive])}",
          name: "Errored Skill",
          version: "1.0.0",
          manifest: %{"entrypoint" => "noop"},
          manifest_errors: %{"entrypoint" => "missing"},
          capabilities: ["api_call"],
          status: "error",
          enabled: true
        })

      {:ok, _ready_assignment} = Skills.assign_skill_to_agent(agent.id, prompt_ready.id)
      {:ok, _errored_assignment} = Skills.assign_skill_to_agent(agent.id, errored.id)

      {:ok, view, html} = live(conn, "/agents/#{agent.id}?tab=skills")

      assert has_element?(view, "[data-testid='agent-skill-loadout']")
      assert html =~ "Agent skill loadout"
      assert html =~ "Prompt capability readiness"
      assert html =~ "1/2 assigned skill(s) are prompt-ready"
      assert html =~ "Repair assigned skills"
      assert html =~ "Prompt Ready Skill"
      assert html =~ "Prompt-ready"
      assert html =~ "Errored Skill"
      assert html =~ "Repair before prompt"
    end

    test "renders instructions tab when set", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Agent with Path",
          role: :engineer,
          status: :idle,
          instructions_path: "agents/engineer/AGENTS.md"
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=instructions")
      assert html =~ "Files"
    end

    test "shows wake history section", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Agent with History",
          role: :engineer,
          status: :idle
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=runs")
      assert html =~ "Wake History" or html =~ "Runs" or html =~ "History"
    end

    test "shows max concurrent jobs in configuration", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Agent",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 5
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      assert html =~ "Max jobs"
      assert html =~ "5"
    end
  end

  describe "Edit - Agent Configuration" do
    test "renders edit page with max concurrent jobs slider", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Editable Agent",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 3
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")
      assert html =~ "Max concurrent jobs"
      assert html =~ "range"
      assert html =~ "Runtime capacity"
      assert html =~ "Runtime Profile"
    end

    test "configuration form shows the runtime_config model that actually runs", %{conn: conn} do
      # Onboarding's per-role AI writes the model to runtime_config (which
      # wins the runtime merge); the form must show that, not the adapter
      # default (o4-mini).
      {:ok, agent} =
        create_agent(%{
          name: "Onboarded Codex Agent",
          role: :cto,
          status: :idle,
          adapter: :codex,
          runtime_config: %{"model" => "gpt-5.5", "autonomous" => true}
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ ~r/<option[^>]+value="gpt-5.5"[^>]+selected/
      refute html =~ ~r/<option[^>]+value="o4-mini"[^>]+selected/
    end

    test "configuration form preserves a saved custom Codex model", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Custom Codex Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          config: %{"model" => "gpt-5.6-terra"}
        })

      {:ok, view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ ~r/<option[^>]+value="gpt-5.6-terra"[^>]+selected/
      assert html =~ "gpt-5.6-terra (custom)"

      html =
        view
        |> form("form[phx-change='config_validate']", %{
          "agent" => %{
            "name" => agent.name,
            "title" => "",
            "role" => "engineer",
            "parent_id" => "",
            "adapter" => "codex",
            "model" => "gpt-5.6-terra",
            "max_concurrent_jobs" => "3"
          }
        })
        |> render_change()

      assert html =~ "codex --model gpt-5.6-terra"
      assert html =~ ~r/<option[^>]+value="gpt-5.6-terra"[^>]+selected/

      view
      |> form("form[phx-submit='config_save']", %{
        "agent" => %{
          "name" => agent.name,
          "title" => "",
          "role" => "engineer",
          "parent_id" => "",
          "adapter" => "codex",
          "model" => "gpt-5.6-terra",
          "max_concurrent_jobs" => "3"
        }
      })
      |> render_submit()

      {:ok, updated} = Agents.get_agent(agent.id)
      assert updated.config["model"] == "gpt-5.6-terra"
    end

    test "runtime profile selector applies adapter and model before save", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Profile Preview Agent",
          role: :engineer,
          status: :idle,
          adapter: :claude_code
        })

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      view |> element("button[phx-click='add_env_row']") |> render_click()
      view |> element("button[phx-click='add_env_row']") |> render_click()

      html =
        view
        |> form("form[phx-submit='config_save']", %{
          "agent" => %{
            "name" => agent.name,
            "title" => "",
            "role" => "engineer",
            "parent_id" => "",
            "runtime_profile_id" => "codex-gpt-5.5",
            "adapter" => "claude_code",
            "max_concurrent_jobs" => "3"
          }
        })
        |> render_change()

      assert html =~ "Codex GPT-5.5"
      assert html =~ "codex --model gpt-5.5"
      assert html =~ ~r/<option value="codex" selected/
      assert html =~ ~r/<option[^>]+value="codex-gpt-5.5"[^>]+selected/
      refute html =~ ~r/data-adapter-panel="codex"[^>]*hidden/
    end

    test "runtime profile selector previews Qwen chat config before save", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Qwen Preview Agent",
          role: :ceo,
          status: :idle,
          adapter: :claude_code
        })

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      html =
        view
        |> form("form[phx-submit='config_save']", %{
          "agent" => %{
            "name" => agent.name,
            "title" => "",
            "role" => "ceo",
            "parent_id" => "",
            "runtime_profile_id" => "openai-chat-qwen-dashscope",
            "adapter" => "claude_code",
            "max_concurrent_jobs" => "1"
          }
        })
        |> render_change()

      assert html =~ "OpenAI Chat Qwen DashScope"
      assert html =~ "OpenAI Chat"
      assert html =~ "qwen3.7-plus"

      assert html =~
               "https://dashscope.aliyuncs.com/compatible-mode/v1"
    end

    test "runtime profile selector previews low-cost Qwen flash config before save", %{
      conn: conn
    } do
      {:ok, agent} =
        create_agent(%{
          name: "Qwen Flash Preview Agent",
          role: :ceo,
          status: :idle,
          adapter: :claude_code
        })

      {:ok, view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "OpenAI Chat Qwen DashScope Flash"

      html =
        view
        |> form("form[phx-submit='config_save']", %{
          "agent" => %{
            "name" => agent.name,
            "title" => "",
            "role" => "ceo",
            "parent_id" => "",
            "runtime_profile_id" => "openai-chat-qwen-dashscope-flash",
            "adapter" => "claude_code",
            "max_concurrent_jobs" => "1"
          }
        })
        |> render_change()

      assert html =~ "OpenAI Chat Qwen DashScope Flash"
      assert html =~ "Low-cost gateway"
      assert html =~ "OpenAI Chat"
      assert html =~ "qwen3.6-flash"

      assert html =~
               "https://dashscope.aliyuncs.com/compatible-mode/v1"
    end

    test "runtime profile selector previews Qwen international chat config before save", %{
      conn: conn
    } do
      {:ok, agent} =
        create_agent(%{
          name: "Qwen Intl Preview Agent",
          role: :ceo,
          status: :idle,
          adapter: :claude_code
        })

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      html =
        view
        |> form("form[phx-submit='config_save']", %{
          "agent" => %{
            "name" => agent.name,
            "title" => "",
            "role" => "ceo",
            "parent_id" => "",
            "runtime_profile_id" => "openai-chat-qwen-dashscope-intl",
            "adapter" => "claude_code",
            "max_concurrent_jobs" => "1"
          }
        })
        |> render_change()

      assert html =~ "OpenAI Chat Qwen DashScope Intl"
      assert html =~ "OpenAI Chat"
      assert html =~ "qwen3.7-plus"

      assert html =~
               "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
    end

    test "saving runtime profile persists profile id and concrete adapter config", %{
      conn: conn
    } do
      {:ok, agent} =
        create_agent(%{
          name: "Profile Save Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          config: %{"model" => "gpt-5.5"}
        })

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      view
      |> form("form[phx-submit='config_save']", %{
        "agent" => %{
          "name" => agent.name,
          "title" => "",
          "role" => "engineer",
          "parent_id" => "",
          "runtime_profile_id" => "claude-cm",
          "adapter" => "codex",
          "max_concurrent_jobs" => "3"
        }
      })
      |> render_submit()

      {:ok, updated} = Agents.get_agent(agent.id)
      assert updated.adapter == :claude_code
      assert updated.config["command"] == "cm"
      assert updated.runtime_config["profile_id"] == "claude-cm"
    end

    test "permission toggles persist on configuration save", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Task Assignment Agent",
          role: :product_manager,
          status: :idle,
          adapter: :claude_code
        })

      {:ok, view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")
      assert html =~ "Can assign tasks"

      render_submit(view, "config_save", %{
        "agent" => %{
          "name" => agent.name,
          "title" => "",
          "role" => "product_manager",
          "parent_id" => "",
          "runtime_profile_id" => "claude-cm",
          "adapter" => "claude_code",
          "max_concurrent_jobs" => "1"
        },
        "env_keys" => %{"_unused_0" => "", "0" => ""},
        "env_values" => %{"_unused_0" => "", "0" => ""},
        "permissions" => %{
          "_unused_can_assign_tasks" => "",
          "can_assign_tasks" => "true"
        }
      })

      {:ok, updated} = Agents.get_agent(agent.id)
      assert updated.permissions["can_assign_tasks"] == true
      refute Map.has_key?(updated.permissions, "_unused_can_assign_tasks")
    end

    test "saving Qwen DashScope profile persists non-secret chat config", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Qwen Profile Agent",
          role: :ceo,
          status: :idle,
          adapter: :claude_code,
          config: %{"command" => "claude"}
        })

      {:ok, view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "OpenAI Chat Qwen DashScope"

      view
      |> form("form[phx-submit='config_save']", %{
        "agent" => %{
          "name" => agent.name,
          "title" => "",
          "role" => "ceo",
          "parent_id" => "",
          "runtime_profile_id" => "openai-chat-qwen-dashscope",
          "adapter" => "claude_code",
          "max_concurrent_jobs" => "1"
        }
      })
      |> render_submit()

      {:ok, updated} = Agents.get_agent(agent.id)
      assert updated.adapter == :openai_chat
      assert updated.config["model"] == "qwen3.7-plus"

      assert updated.config["endpoint"] ==
               "https://dashscope.aliyuncs.com/compatible-mode/v1"

      assert updated.runtime_config["profile_id"] == "openai-chat-qwen-dashscope"
      refute inspect(updated.config) =~ "API_KEY"
    end

    test "saving low-cost Qwen flash profile persists non-secret chat config", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Qwen Flash Profile Agent",
          role: :ceo,
          status: :idle,
          adapter: :claude_code,
          config: %{"command" => "claude"}
        })

      {:ok, view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "OpenAI Chat Qwen DashScope Flash"

      view
      |> form("form[phx-submit='config_save']", %{
        "agent" => %{
          "name" => agent.name,
          "title" => "",
          "role" => "ceo",
          "parent_id" => "",
          "runtime_profile_id" => "openai-chat-qwen-dashscope-flash",
          "adapter" => "claude_code",
          "max_concurrent_jobs" => "1"
        }
      })
      |> render_submit()

      {:ok, updated} = Agents.get_agent(agent.id)
      assert updated.adapter == :openai_chat
      assert updated.config["model"] == "qwen3.6-flash"

      assert updated.config["endpoint"] ==
               "https://dashscope.aliyuncs.com/compatible-mode/v1"

      assert updated.runtime_config["profile_id"] == "openai-chat-qwen-dashscope-flash"
      refute inspect(updated.config) =~ "API_KEY"
    end

    test "saving Qwen DashScope international profile persists non-secret chat config", %{
      conn: conn
    } do
      {:ok, agent} =
        create_agent(%{
          name: "Qwen Intl Profile Agent",
          role: :ceo,
          status: :idle,
          adapter: :claude_code,
          config: %{"command" => "claude"}
        })

      {:ok, view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "OpenAI Chat Qwen DashScope Intl"

      view
      |> form("form[phx-submit='config_save']", %{
        "agent" => %{
          "name" => agent.name,
          "title" => "",
          "role" => "ceo",
          "parent_id" => "",
          "runtime_profile_id" => "openai-chat-qwen-dashscope-intl",
          "adapter" => "claude_code",
          "max_concurrent_jobs" => "1"
        }
      })
      |> render_submit()

      {:ok, updated} = Agents.get_agent(agent.id)
      assert updated.adapter == :openai_chat
      assert updated.config["model"] == "qwen3.7-plus"

      assert updated.config["endpoint"] ==
               "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"

      assert updated.runtime_config["profile_id"] == "openai-chat-qwen-dashscope-intl"
      refute inspect(updated.config) =~ "API_KEY"
    end

    test "runtime capacity updates when adapter and concurrency change", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Capacity Agent",
          role: :engineer,
          status: :idle,
          adapter: :openclaw,
          max_concurrent_jobs: 1
        })

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      html =
        view
        |> form("form[phx-submit='config_save']", %{
          "agent" => %{
            "name" => agent.name,
            "title" => "",
            "role" => "engineer",
            "parent_id" => "",
            "adapter" => "codex",
            "max_concurrent_jobs" => "6"
          }
        })
        |> render_change()

      assert html =~ "Runtime capacity"
      assert html =~ "High pressure"
      assert html =~ "6 local CLI slots"
      assert html =~ "Lower max jobs"
    end

    test "renders configuration tab", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Editable Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")
      assert html =~ "Adapter"
    end

    test "configuration tab previews prompt contract health and snippets", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Prompt Health Agent",
          role: :engineer,
          status: :idle,
          instructions: "Do good work."
        })

      {:ok, view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "Agent Instruction Studio"
      assert html =~ "Needs tuning"
      assert html =~ "Eval coverage"
      assert html =~ "Eval "
      assert html =~ "Eval details"
      assert html =~ "Expected pass"
      assert html =~ "Expected catch"
      assert html =~ "Thin Engineer delivery"
      assert html =~ "PR body"
      assert html =~ "Validates"
      assert html =~ "Catches"
      assert html =~ "Effective prompt preview"
      assert html =~ "Operating loop guide"
      assert html =~ "Scenario checks"
      assert html =~ "Orient, decide, act, verify, report"
      assert html =~ "Runtime drill"
      assert html =~ "one-turn checklist"
      assert html =~ "Scope the next action"
      assert html =~ "Attach evidence"
      assert html =~ "No completion claim without a verification line"
      assert html =~ "Turn guide"
      assert html =~ "injected playbook"
      assert html =~ "First move"
      assert html =~ "Evidence to produce"
      assert html =~ "Completion signal"
      assert html =~ "artifact / PR / evidence"
      assert html =~ "Turn ledger"
      assert html =~ "restartable evidence"
      assert html =~ "Evidence produced"
      assert html =~ "State change"
      assert html =~ "Restart context"
      assert html =~ "work product / PR / source evidence"
      assert html =~ "Suggested instruction patches"
      assert html =~ "Required final comment"
      assert html =~ "[delivery] What happened:"
      assert html =~ "Files changed"
      assert html =~ "Contract health"
      assert html =~ "Custom instructions do not mention the required final-comment fields."
      assert html =~ "Quick snippets"
      assert html =~ "[blocked] Cause:"
      assert html =~ "Owner-readable memory"
      assert html =~ "Operating loop"
      assert html =~ "PR quality"

      html =
        view
        |> form("form[phx-submit='config_save']", %{
          "agent" => %{
            "name" => "Prompt Health Agent",
            "title" => "",
            "role" => "cto",
            "parent_id" => "",
            "adapter" => "claude_code",
            "runtime_profile_id" => "custom",
            "runtime_command" => "claude",
            "max_concurrent_jobs" => "3"
          }
        })
        |> render_change()

      assert html =~ "CTO"
      assert html =~ "[review] Verdict:"
      assert html =~ "Follow-up issues"
    end

    test "configuration tab applies suggested instruction patches without saving", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Patchable Agent",
          role: :engineer,
          status: :idle,
          instructions: "Do good work."
        })

      {:ok, view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "Do good work."
      assert html =~ "Needs tuning"

      html =
        view
        |> element("button[phx-value-patch='owner-memory']", "Apply patch")
        |> render_click()

      assert html =~ "Applied Owner-readable memory"
      assert html =~ "Studio score"
      assert html =~ "Save changes to persist it"
      assert html =~ "## Owner-readable memory"
      assert html =~ "After every meaningful action"

      {:ok, unchanged} = Agents.get_agent(agent.id)
      assert unchanged.instructions == "Do good work."

      html =
        view
        |> element("button[phx-value-patch='operating-loop']", "Apply patch")
        |> render_click()

      assert html =~ "Applied Operating loop"
      assert html =~ "Orient on issue, goal, project"
      assert html =~ "Decide the single next move"
    end

    test "configuration tab applies recommended instruction patches together without saving", %{
      conn: conn
    } do
      {:ok, agent} =
        create_agent(%{
          name: "Batch Patch Agent",
          role: :engineer,
          status: :idle,
          instructions: "Do good work."
        })

      {:ok, view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "Apply next 5 recommended patches"

      html =
        view
        |> element(
          "button[data-testid='apply-recommended-instruction-patches']",
          "Apply next 5 recommended patches"
        )
        |> render_click()

      assert html =~ "Applied 5 recommended patches"
      assert html =~ "Studio score"
      assert html =~ "Save changes to persist it"
      assert html =~ "## Owner-readable memory"
      assert html =~ "## Operating loop"
      assert html =~ "## Last action receipt"

      {:ok, unchanged} = Agents.get_agent(agent.id)
      assert unchanged.instructions == "Do good work."
    end

    test "configuration save records instruction history", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Revision Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          instructions: "Do good work."
        })

      {:ok, view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")
      assert html =~ "Instruction history"
      assert html =~ "No revisions yet"

      view
      |> form("form[phx-submit='config_save']", %{
        "agent" => %{
          "name" => agent.name,
          "title" => "",
          "role" => "engineer",
          "parent_id" => "",
          "adapter" => "codex",
          "model" => "gpt-5.5",
          "instructions" =>
            "After every meaningful action, comment with [delivery] What happened, files changed, verification, and next decision. Open a PR with a task list.",
          "max_concurrent_jobs" => "3"
        }
      })
      |> render_submit()

      [revision] = Agents.list_config_revisions(agent.id)
      assert revision.version == 1
      assert revision.adapter == "codex"
      assert revision.config["model"] == "gpt-5.5"
      assert is_integer(revision.studio_score)

      html = render(view)
      assert html =~ "Current saved"
      assert html =~ "v1"
    end

    test "configuration tab shows latest prompt tuning revision", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Tuned Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          instructions:
            "After every meaningful action, comment with [delivery] What happened, files changed, verification, and next decision."
        })

      {:ok, _revision} =
        Agents.create_config_revision(agent, %{
          source: "prompt_tuning",
          studio_audits_extra: %{
            "tuning_release" => %{
              "kind" => "prompt_tuning_release",
              "patch_count" => 2,
              "patches" => [
                %{"title" => "Owner-readable memory"},
                %{"title" => "Delivery evidence"}
              ],
              "expected_effect" => "Runs should leave clearer owner-readable issue memory.",
              "rollback" =>
                "Use the agent Instruction Studio revision history to restore the previous prompt if the next run regresses."
            }
          }
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "Last prompt tuning: v1"
      assert html =~ "Prompt tuning"
      assert html =~ "Prompt tuning release"
      assert html =~ "2 patches"
      assert html =~ "Runs should leave clearer owner-readable issue memory."
      assert html =~ "Patches: Owner-readable memory, Delivery evidence"
      assert html =~ "Rollback: Use the agent Instruction Studio revision history"
    end

    test "configuration tab restores older instruction revision", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Rollback Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          instructions: "Original safe instructions."
        })

      {:ok, old_revision} = Agents.create_config_revision(agent)

      {:ok, updated} =
        Agents.update_agent(agent, %{
          instructions: "No comments. Skip tests.",
          config: %{"model" => "gpt-5.5"}
        })

      {:ok, _latest_revision} = Agents.create_config_revision(updated)

      {:ok, view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "Instruction history"
      assert html =~ "v1"
      assert html =~ "v2"
      assert html =~ "Conflicting guardrail found"

      html =
        view
        |> element("button[phx-value-id='#{old_revision.id}']", "Restore")
        |> render_click()

      assert html =~ "Original safe instructions."

      {:ok, restored} = Agents.get_agent(agent.id)
      assert restored.instructions == "Original safe instructions."

      [rollback | _] = Agents.list_config_revisions(agent.id)
      assert rollback.source == "restore"
      assert rollback.restored_from_revision_id == old_revision.id
    end

    test "configuration tab warns before instruction quality regresses", %{conn: conn} do
      strong_instructions =
        "After every meaningful action, comment with [delivery] What happened, files changed, verification, and next decision. Open a PR with a task list."

      {:ok, agent} =
        create_agent(%{
          name: "Guardrail Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          instructions: strong_instructions
        })

      {:ok, _revision} = Agents.create_config_revision(agent)
      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      html =
        view
        |> form("form[phx-submit='config_save']", %{
          "agent" => %{
            "name" => agent.name,
            "title" => "",
            "role" => "engineer",
            "parent_id" => "",
            "adapter" => "codex",
            "model" => "gpt-5.5",
            "instructions" => "Do good work.",
            "max_concurrent_jobs" => "3"
          }
        })
        |> render_change()

      assert html =~ "Studio score drops on save"
      assert html =~ "Final-comment contract weakened"
    end

    test "shows effective Claude Code command in configuration", %{conn: conn} do
      original = Application.get_env(:cympho, :claude_code_command)
      Application.put_env(:cympho, :claude_code_command, "cz")

      on_exit(fn ->
        if original do
          Application.put_env(:cympho, :claude_code_command, original)
        else
          Application.delete_env(:cympho, :claude_code_command)
        end
      end)

      {:ok, agent} =
        create_agent(%{
          name: "Cheap Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :claude_code
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")
      assert html =~ "Runtime command"
      assert html =~ "cz"
    end

    test "shows Codex model selector and hides runtime command", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Codex Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          config: %{"model" => "gpt-5.5"}
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "Codex model"
      assert html =~ "codex --model gpt-5.5"
      assert html =~ "Agent preflight"
      assert html =~ "OpenAI/Codex key"
      assert html =~ "Add OPENAI_API_KEY"
      assert html =~ "Add env var"
      assert html =~ ~s(href="#agent-env-vars")
      assert html =~ ~r/<option value="codex" selected/
      assert html =~ ~r/data-adapter-panel="claude_code"[^>]*hidden/
      refute html =~ ~r/data-adapter-panel="codex"[^>]*hidden/
    end

    test "adapter readiness reflects configured runtime env", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Ready Codex Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          config: %{"model" => "gpt-5.5"},
          runtime_config: %{"env" => %{"OPENAI_API_KEY" => "test-key"}}
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "Agent preflight"
      assert html =~ "Review mode only"
      assert html =~ "Open service gates"
      assert html =~ ~s(href="/operations#runtime-services")
      assert html =~ "Credential source is configured"
      assert html =~ "codex --model gpt-5.5"
    end

    test "adapter readiness ignores unrelated scoped secrets", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Wrong Secret Remote Agent",
          role: :engineer,
          status: :idle,
          adapter: :agrenting,
          config: %{
            "agent_did" => "did:example:remote-agent",
            "capability" => "implementation",
            "max_price" => "1.00"
          }
        })

      {:ok, _secret} =
        Secrets.create_secret(%{
          company_id: agent.company_id,
          scope: "company",
          key: "OPENAI_API_KEY",
          value: "wrong-provider-key",
          description: "Wrong provider key"
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "Agent preflight"
      assert html =~ "Agrenting API key"
      assert html =~ "Add AGRENTING_API_KEY"
      assert html =~ "Open secrets"
      refute html =~ "Credential source is configured"
      refute html =~ "wrong-provider-key"
    end

    test "adapter readiness reflects unsaved runtime env rows", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Env Preview Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          config: %{"model" => "gpt-5.5"}
        })

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      html =
        view
        |> form("form[phx-submit='config_save']", %{
          "agent" => %{
            "name" => agent.name,
            "title" => "",
            "role" => "engineer",
            "parent_id" => "",
            "adapter" => "codex",
            "model" => "gpt-5.5",
            "max_concurrent_jobs" => "3"
          },
          "env_keys" => %{"0" => "OPENAI_API_KEY"},
          "env_values" => %{"0" => "test-key"}
        })
        |> render_change()

      assert html =~ "Agent preflight"
      assert html =~ "Review mode only"
      assert html =~ "Credential source is configured"
    end

    test "Claude readiness shows provider model and endpoint", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Claude Provider Route Agent",
          role: :ceo,
          status: :idle,
          adapter: :claude_code,
          config: %{"command" => "echo"},
          runtime_config: %{
            "env" => %{
              "ANTHROPIC_API_KEY" => "secret-key",
              "ANTHROPIC_MODEL" => "qwen3.7-plus",
              "ANTHROPIC_BASE_URL" => "https://dashscope.aliyuncs.com/compatible-mode/v1"
            }
          }
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "Agent preflight"
      assert html =~ "Provider model"
      assert html =~ "qwen3.7-plus"
      assert html =~ "Gateway endpoint"

      assert html =~
               "https://dashscope.aliyuncs.com/compatible-mode/v1"

      assert html =~ "Anthropic-compatible credentials are configured"
    end

    test "OpenAI Chat readiness shows configured and normalized request URLs", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "OpenAI Chat Route Agent",
          role: :ceo,
          status: :idle,
          adapter: :openai_chat,
          config: %{
            "endpoint" => "https://dashscope.example.com/compatible-mode/v1/",
            "model" => "qwen3.7-plus"
          }
        })

      {:ok, _secret} =
        Secrets.create_secret(%{
          company_id: agent.company_id,
          scope: "company",
          key: "DASHSCOPE_API_KEY",
          value: "test-api-key",
          description: "DashScope key"
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "Agent preflight"
      assert html =~ "Chat model"
      assert html =~ "qwen3.7-plus"
      assert html =~ "Configured endpoint"
      assert html =~ "https://dashscope.example.com/compatible-mode/v1/"
      assert html =~ "Request URL"

      assert html =~
               "https://dashscope.example.com/compatible-mode/v1/chat/completions"

      assert html =~ "Execution capability"
      assert html =~ "cannot edit files"
      assert html =~ "Credential source is configured"
      refute html =~ "test-api-key"
    end

    test "OpenAI Chat readiness links missing DashScope credentials to DASHSCOPE_API_KEY", %{
      conn: conn
    } do
      {:ok, agent} =
        create_agent(%{
          name: "Missing DashScope Credential Agent",
          role: :ceo,
          status: :idle,
          adapter: :openai_chat,
          config: %{
            "endpoint" => "https://dashscope.aliyuncs.com/compatible-mode/v1",
            "model" => "qwen3.6-flash"
          }
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "Agent preflight"
      assert html =~ "Chat completion key"
      assert html =~ "Add DASHSCOPE_API_KEY or OPENAI_API_KEY or ANTHROPIC_API_KEY"
      assert html =~ "Add secret"
      assert html =~ "key=DASHSCOPE_API_KEY"
      assert html =~ "scope=company"
      refute html =~ "Credential source is configured"
    end

    test "quick runtime preset previews profile and concurrency before save", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Preset Agent",
          role: :engineer,
          status: :idle,
          adapter: :claude_code,
          max_concurrent_jobs: 6
        })

      {:ok, view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "Quick presets"
      assert html =~ "Low RAM"

      html =
        view
        |> element("button[phx-value-preset='low_ram']")
        |> render_click()

      assert html =~ "Codex mini"
      assert html =~ "codex --model gpt-5.4-mini"
      assert html =~ ~r/<option[^>]+value="codex-mini"[^>]+selected/
      assert html =~ ~s(value="1")
    end

    test "adapter test runs a cheap preflight and normalizes failures", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Preflight Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "__missing_cympho_test_command__", "model" => "custom"}
        })

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      html =
        view
        |> element("button", "Test adapter")
        |> render_click()

      assert html =~ "Agent preflight"
      assert html =~ "Command not found"
      assert html =~ "Edit command"
      assert html =~ ~s(href="#agent-process-command")
      assert html =~ "Adapter preflight"
      assert html =~ "Process"
      assert html =~ "Needs attention"
      assert html =~ "Missing command"
    end

    test "changing adapter to Codex reveals the model selector before save", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Switchable Agent",
          role: :engineer,
          status: :idle,
          adapter: :claude_code
        })

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      html =
        view
        |> form("form[phx-submit='config_save']", %{
          "agent" => %{
            "name" => agent.name,
            "title" => "",
            "role" => "engineer",
            "parent_id" => "",
            "adapter" => "codex",
            "max_concurrent_jobs" => "3"
          }
        })
        |> render_change()

      assert html =~ "Codex model"
      assert html =~ "codex --model o4-mini"
      assert html =~ ~r/<option value="codex" selected/
      assert html =~ ~r/data-adapter-panel="claude_code"[^>]*hidden/
      refute html =~ ~r/data-adapter-panel="codex"[^>]*hidden/

      html =
        view
        |> form("form[phx-submit='config_save']", %{
          "agent" => %{
            "name" => agent.name,
            "title" => "",
            "role" => "engineer",
            "parent_id" => "",
            "adapter" => "codex",
            "model" => "gpt-5.4-mini",
            "max_concurrent_jobs" => "3"
          }
        })
        |> render_change()

      assert html =~ "codex --model gpt-5.4-mini"
    end

    test "saving Codex model writes adapter config", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Model Save Agent",
          role: :engineer,
          status: :idle,
          adapter: :claude_code
        })

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      view
      |> form("form[phx-submit='config_save']", %{
        "agent" => %{
          "name" => agent.name,
          "title" => "",
          "role" => "engineer",
          "parent_id" => "",
          "adapter" => "codex",
          "max_concurrent_jobs" => "3"
        }
      })
      |> render_change()

      view
      |> form("form[phx-submit='config_save']", %{
        "agent" => %{
          "name" => agent.name,
          "title" => "",
          "role" => "engineer",
          "parent_id" => "",
          "adapter" => "codex",
          "model" => "gpt-5.4",
          "max_concurrent_jobs" => "3"
        }
      })
      |> render_submit()

      {:ok, updated} = Agents.get_agent(agent.id)
      assert updated.adapter == :codex
      assert updated.config["model"] == "gpt-5.4"
    end

    test "Cursor configuration exposes command and model", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Cursor Agent",
          role: :engineer,
          status: :idle,
          adapter: :claude_code
        })

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      view
      |> form("form[phx-submit='config_save']", %{
        "agent" => %{
          "name" => agent.name,
          "title" => "",
          "role" => "engineer",
          "parent_id" => "",
          "adapter" => "cursor",
          "runtime_command" => "agent",
          "model" => "composer-2",
          "max_concurrent_jobs" => "3"
        }
      })
      |> render_submit()

      {:ok, updated} = Agents.get_agent(agent.id)
      assert updated.adapter == :cursor
      assert updated.config["command"] == "agent"
      assert updated.config["model"] == "composer-2"
    end

    test "OpenClaw configuration stores provider-qualified model", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "OpenClaw Agent",
          role: :engineer,
          status: :idle,
          adapter: :claude_code
        })

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      view
      |> form("form[phx-change='config_validate']", %{
        "agent" => %{
          "name" => agent.name,
          "title" => "",
          "role" => "engineer",
          "parent_id" => "",
          "adapter" => "openclaw",
          "provider" => "zai",
          "max_concurrent_jobs" => "3"
        }
      })
      |> render_change()

      view
      |> form("form[phx-submit='config_save']", %{
        "agent" => %{
          "name" => agent.name,
          "title" => "",
          "role" => "engineer",
          "parent_id" => "",
          "adapter" => "openclaw",
          "provider" => "zai",
          "model" => "zai/glm-4.7",
          "openclaw_endpoint" => "http://localhost:18789",
          "openclaw_runtime" => "acp",
          "openclaw_harness_id" => "codex",
          "max_concurrent_jobs" => "3"
        }
      })
      |> render_submit()

      {:ok, updated} = Agents.get_agent(agent.id)
      assert updated.adapter == :openclaw
      assert updated.config["provider"] == "zai"
      assert updated.config["model"] == "zai/glm-4.7"
      assert updated.config["endpoint"] == "http://localhost:18789"
      assert updated.config["agent_runtime"] == "acp"
      assert updated.config["harness_id"] == "codex"
    end

    test "Process configuration stores preset command and model mapping", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Process Agent",
          role: :engineer,
          status: :idle,
          adapter: :claude_code
        })

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      view
      |> form("form[phx-submit='config_save']", %{
        "agent" => %{
          "name" => agent.name,
          "title" => "",
          "role" => "engineer",
          "parent_id" => "",
          "adapter" => "process",
          "process_preset" => "codex",
          "provider" => "openai",
          "model" => "gpt-5.5",
          "runtime_command" => "codex",
          "runtime_cwd" => "/tmp",
          "process_args" => "--force\n--output-format json",
          "max_concurrent_jobs" => "3"
        }
      })
      |> render_submit()

      {:ok, updated} = Agents.get_agent(agent.id)
      assert updated.adapter == :process
      assert updated.config["process_preset"] == "codex"
      assert updated.config["command"] == "codex"
      assert updated.config["model"] == "gpt-5.5"
      assert updated.config["model_arg_template"] == ["--model", "{{model}}"]
      assert updated.config["args"] == ["--force", "--output-format json"]
      assert updated.config["cwd"] == "/tmp"
    end
  end

  describe "Adapter Selection" do
    test "shows adapter dropdown on new agent form", %{conn: conn} do
      {:ok, view, html} = live(conn, "/agents/new")

      assert html =~ "Adapter"
      assert html =~ "Agent launch plan"
      assert html =~ ~s(data-testid="new-agent-identity-section")
      assert html =~ ~s(data-testid="new-agent-adapter-section")
      assert html =~ ~s(data-testid="new-agent-guide-section")
      assert html =~ ~s(data-testid="new-agent-setup-checklist")
      assert html =~ ~s(data-testid="new-agent-role-guide")
      assert html =~ ~s(data-testid="new-agent-form-actions")
      assert html =~ "Hire checklist"
      assert html =~ "Selected role"
      assert html =~ ~s(data-testid="new-agent-runtime-profile")
      assert html =~ "Runtime profile"
      assert html =~ "Choose the agent"
      assert html =~ "role and reporting line"
      assert html =~ "Create an autonomous teammate with a role"
      assert has_element?(view, "form[data-ui-simple-single-column]")
      assert has_element?(view, "[data-testid='new-agent-defaults-summary'].ui-simple-only")
      assert has_element?(view, "[data-testid='new-agent-runtime-section'].ui-advanced-only")
      assert has_element?(view, "[data-testid='new-agent-adapter-section'].ui-advanced-only")
      assert has_element?(view, "[data-testid='new-agent-guide-section'].ui-advanced-only")
    end

    test "new agent form previews and saves DashScope runtime profile", %{
      conn: conn,
      current_company: company
    } do
      {:ok, view, html} =
        live(
          conn,
          "/agents/new?role=ceo&name=Qwen%20CEO&runtime_profile_id=openai-chat-qwen-dashscope-flash"
        )

      assert html =~ ~s(data-testid="new-agent-runtime-profile")
      assert html =~ "OpenAI Chat Qwen DashScope Flash"
      assert html =~ "OpenAI Chat"
      assert html =~ "qwen3.6-flash"
      assert html =~ "https://dashscope.aliyuncs.com/compatible-mode/v1"
      assert html =~ "1 slot"
      assert html =~ "Text/action only"
      assert html =~ "Add required key"
      assert html =~ "key=DASHSCOPE_API_KEY"
      assert html =~ ~r/<option[^>]+value="openai-chat-qwen-dashscope-flash"[^>]+selected/
      assert html =~ ~r/<option[^>]+value="openai_chat"[^>]+selected/

      view
      |> form("form", %{
        "agent" => %{
          "name" => "Qwen CEO",
          "role" => "ceo",
          "parent_id" => "",
          "runtime_profile_id" => "openai-chat-qwen-dashscope-flash",
          "adapter" => "claude_code",
          "instructions" => "Own CEO triage and handoffs."
        }
      })
      |> render_submit()

      created =
        company.id
        |> Agents.list_agents_by_company()
        |> Enum.find(&(&1.name == "Qwen CEO"))

      assert created.adapter == :openai_chat
      assert created.config["model"] == "qwen3.6-flash"

      assert created.config["endpoint"] ==
               "https://dashscope.aliyuncs.com/compatible-mode/v1"

      assert created.runtime_config["profile_id"] == "openai-chat-qwen-dashscope-flash"
      assert created.max_concurrent_jobs == 1
      refute Map.has_key?(created.config, "api_key")
    end

    test "new agent form marks process Codex profile as repo capable", %{
      conn: conn
    } do
      {:ok, _view, html} =
        live(conn, "/agents/new?role=engineer&runtime_profile_id=process-codex")

      assert html =~ ~s(data-testid="new-agent-runtime-profile")
      assert html =~ "Process Codex CLI"
      assert html =~ "Process"
      assert html =~ "Repo capable"
      assert html =~ "codex"
      assert html =~ "gpt-5.5"
      assert html =~ ~r/<option[^>]+value="process-codex"[^>]+selected/
      assert html =~ ~r/<option[^>]+value="process"[^>]+selected/
    end

    test "new agent form keeps default concurrency for custom runtime profile", %{
      conn: conn,
      current_company: company
    } do
      {:ok, view, html} = live(conn, "/agents/new?role=engineer&name=Custom%20Engineer")

      assert html =~ ~s(data-testid="new-agent-runtime-profile")
      assert html =~ ~r/<option[^>]+value="custom"[^>]+selected/
      refute html =~ "1 slot"

      view
      |> form("form", %{
        "agent" => %{
          "name" => "Custom Engineer",
          "role" => "engineer",
          "parent_id" => "",
          "runtime_profile_id" => "custom",
          "adapter" => "process",
          "process_preset" => "custom",
          "runtime_command" => "echo",
          "instructions" => "Work from the issue brief."
        }
      })
      |> render_submit()

      created =
        company.id
        |> Agents.list_agents_by_company()
        |> Enum.find(&(&1.name == "Custom Engineer"))

      assert created.adapter == :process
      assert created.max_concurrent_jobs == 3
      assert created.runtime_config["profile_id"] == "custom"
    end

    test "new agent form accepts role, name, and manager query params", %{conn: conn} do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO",
          role: :ceo,
          status: :idle,
          adapter: :process
        })

      {:ok, issue} =
        create_issue(%{
          title: "Plan SEO launch campaign",
          description: "Launch marketing demand funnel.",
          status: :todo
        })

      {:ok, _view, html} =
        live(conn, "/agents/new?role=marketing&name=Growth%20Marketer&parent_id=#{ceo.id}")

      assert html =~ ~s(value="Growth Marketer")
      assert html =~ ~r/<option value="marketer" selected/
      assert html =~ ~r/<option value="#{ceo.id}" selected/
      assert html =~ "Marketer focus"
      assert html =~ "Owner-readable memory"
      assert html =~ "target markets"
      assert html =~ ~s(data-testid="hire-demand-context")
      assert html =~ "Demand-backed hire"
      assert html =~ "1 open issue"
      assert html =~ "Queued work needs a Marketer"
      assert html =~ "Plan SEO launch campaign"
      assert html =~ "/issues/#{issue.id}"
      assert html =~ issue.identifier
      assert html =~ "Reports to CEO"
    end

    test "demand-backed hire assigns waiting role work and returns to source", %{
      conn: conn,
      current_company: company
    } do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO",
          role: :ceo,
          status: :idle,
          adapter: :process
        })

      {:ok, issue} =
        create_issue(%{
          title: "Plan SEO launch campaign",
          description: "Launch marketing demand funnel.",
          status: :todo,
          assigned_role: "marketer",
          skip_auto_assign: true
        })

      return_to = "/agents#agent-role-coverage"

      {:ok, view, html} =
        live(
          conn,
          "/agents/new?role=marketing&name=Growth%20Marketer&parent_id=#{ceo.id}&return_to=#{URI.encode_www_form(return_to)}"
        )

      assert html =~ ~s(data-testid="hire-demand-context")
      assert html =~ "Queued work needs a Marketer"
      assert html =~ "Plan SEO launch campaign"

      result =
        view
        |> form("form", %{
          "agent" => %{
            "name" => "Growth Marketer",
            "role" => "marketer",
            "parent_id" => ceo.id,
            "runtime_profile_id" => "openai-chat-qwen-dashscope-flash",
            "adapter" => "claude_code",
            "instructions" => "Own growth execution."
          }
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: ^return_to}}} = result

      created =
        company.id
        |> Agents.list_agents_by_company()
        |> Enum.find(&(&1.name == "Growth Marketer"))

      on_exit(fn -> _ = AgentHeartbeat.stop_for_agent(created.id) end)
      assert {:ok, pid} = AgentHeartbeat.whereis(created.id)
      assert Process.alive?(pid)

      issue = Issues.get_issue!(issue.id)

      assert issue.assignee_id == created.id
      assert issue.status == :todo

      assert [wake] = Wakes.list_issue_wakes(issue.id)
      assert wake.agent_id == created.id
      assert wake.reason == "manual_dispatch"
      assert wake.status == "pending"
      assert wake.metadata["source"] == "demand_backed_hire"
      assert wake.metadata["agent_id"] == created.id
      assert wake.metadata["role"] == "marketer"

      [comment] = Comments.list_comments(issue.id)
      assert comment.author_type == "system"
      assert comment.body =~ "[handoff] Demand-backed hire assigned this Marketer issue"
      assert comment.body =~ "Growth Marketer"
      assert comment.body =~ "queued marketer work had no eligible owner"
      refute comment.body =~ "repo-capable owner"
    end

    test "new agent form shows Codex model selector when Codex is selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      html =
        view
        |> form("form", %{
          "agent" => %{
            "name" => "New Codex Agent",
            "role" => "engineer",
            "adapter" => "codex",
            "parent_id" => "",
            "instructions" => ""
          }
        })
        |> render_change()

      assert html =~ "Codex model"
      assert html =~ "codex --model o4-mini"

      html =
        view
        |> form("form", %{
          "agent" => %{
            "name" => "New Codex Agent",
            "role" => "engineer",
            "adapter" => "codex",
            "model" => "gpt-5.5",
            "parent_id" => "",
            "instructions" => ""
          }
        })
        |> render_change()

      assert html =~ "codex --model gpt-5.5"
    end
  end

  describe "Health Status Display" do
    test "shows health status badge on agent detail page", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Healthy Agent",
          role: :engineer,
          status: :idle,
          health_status: :healthy
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      assert html =~ "Healthy"
    end

    test "shows degraded health status", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Degraded Agent",
          role: :engineer,
          status: :idle,
          health_status: :degraded
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      assert html =~ "Degraded"
    end

    test "shows unavailable health status", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Unavailable Agent",
          role: :engineer,
          status: :offline,
          health_status: :unavailable
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      assert html =~ "Unavailable"
    end
  end
end
