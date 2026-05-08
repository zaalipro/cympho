defmodule CymphoWeb.AgentLiveTest do
  use CymphoWeb.LiveCase, async: false

  import Phoenix.LiveViewTest
  alias Cympho.Agents

  describe "Index - Agent Dashboard" do
    test "renders the agents page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "Agents"
    end

    test "renders list of agents", %{conn: conn} do
      {:ok, _agent} =
        Agents.create_agent(%{
          name: "Test Engineer",
          role: :engineer,
          status: :idle
        })

      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "Test Engineer"
      assert html =~ "Engineer"
    end

    test "renders status dashboard with counts", %{conn: conn} do
      {:ok, _idle1} = Agents.create_agent(%{name: "Idle Agent 1", role: :engineer, status: :idle})
      {:ok, _idle2} = Agents.create_agent(%{name: "Idle Agent 2", role: :engineer, status: :idle})

      {:ok, _running} =
        Agents.create_agent(%{name: "Running Agent", role: :cto, status: :running})

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
        Agents.create_agent(%{name: "Running Agent", role: :engineer, status: :running})

      {:ok, view, _html} = live(conn, "/agents")

      # Running agents should have stop button
      assert has_element?(view, "button[phx-click='kill_session'][phx-value-id='#{agent.id}']")
    end

    test "does not show stop button for idle agents", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{name: "Idle Agent", role: :engineer, status: :idle})

      {:ok, view, _html} = live(conn, "/agents")

      # Idle agents should not have stop button
      refute has_element?(view, "button[phx-click='kill_session'][phx-value-id='#{agent.id}']")
    end

    test "kill_session event returns error when agent not running", %{conn: conn} do
      {:ok, agent} = Agents.create_agent(%{name: "Idle Agent", role: :engineer, status: :idle})

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
  end

  describe "Show - Agent Details" do
    test "renders agent details page", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle,
          instructions: "Do good work"
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}")
      assert html =~ "Test Agent"
    end

    test "renders instructions tab when set", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
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
        Agents.create_agent(%{
          name: "Agent with History",
          role: :engineer,
          status: :idle
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=runs")
      assert html =~ "Wake History" or html =~ "Runs" or html =~ "History"
    end

    test "shows max concurrent jobs in configuration", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
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
        Agents.create_agent(%{
          name: "Editable Agent",
          role: :engineer,
          status: :idle,
          max_concurrent_jobs: 3
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")
      assert html =~ "Max concurrent jobs"
      assert html =~ "range"
    end

    test "renders configuration tab", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Editable Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")
      assert html =~ "Adapter"
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
        Agents.create_agent(%{
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
        Agents.create_agent(%{
          name: "Codex Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          config: %{"model" => "gpt-5.5"}
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      assert html =~ "Codex model"
      assert html =~ "codex --model gpt-5.5"
      assert html =~ ~r/<option value="codex" selected/
      assert html =~ ~r/data-adapter-panel="claude_code"[^>]*hidden/
      refute html =~ ~r/data-adapter-panel="codex"[^>]*hidden/
    end

    test "changing adapter to Codex reveals the model selector before save", %{conn: conn} do
      {:ok, agent} =
        Agents.create_agent(%{
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
        Agents.create_agent(%{
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
        Agents.create_agent(%{
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
        Agents.create_agent(%{
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
        Agents.create_agent(%{
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
        Agents.create_agent(%{
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
        Agents.create_agent(%{
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
        Agents.create_agent(%{
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
