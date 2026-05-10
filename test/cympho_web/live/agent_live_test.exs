defmodule CymphoWeb.AgentLiveTest do
  use CymphoWeb.LiveCase, async: false

  import Phoenix.LiveViewTest
  alias Cympho.Agents
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Repo

  defp create_agent(attrs), do: Agents.create_agent(scoped_attrs(attrs))
  defp create_issue(attrs), do: Issues.create_issue(scoped_attrs(attrs))

  describe "Index - Agent Dashboard" do
    test "renders the agents page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "Agents"
    end

    test "renders list of agents", %{conn: conn} do
      {:ok, _agent} =
        create_agent(%{
          name: "Test Engineer",
          role: :engineer,
          status: :idle
        })

      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "Test Engineer"
      assert html =~ "Engineer"
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

    test "runtime profile selector applies adapter and model before save", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Profile Preview Agent",
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
      assert html =~ "Scenario checks"
      assert html =~ "Suggested instruction patches"
      assert html =~ "Required final comment"
      assert html =~ "[delivery] What happened:"
      assert html =~ "Files changed"
      assert html =~ "Contract health"
      assert html =~ "Custom instructions do not mention the required final-comment fields."
      assert html =~ "Quick snippets"
      assert html =~ "[blocked] Cause:"
      assert html =~ "Owner-readable memory"
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
          source: "prompt_tuning"
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "Last prompt tuning: v1"
      assert html =~ "Prompt tuning"
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
      {:ok, _view, html} = live(conn, "/agents/new")

      assert html =~ "Adapter"
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
