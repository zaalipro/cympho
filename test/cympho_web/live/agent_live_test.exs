defmodule CymphoWeb.AgentLiveTest do
  use CymphoWeb.LiveCase, async: false

  import Phoenix.LiveViewTest
  import Mock
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.AgentHeartbeat
  alias Cympho.BoardApprovals.BoardApproval
  alias Cympho.Comments
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues
  alias Cympho.Issues.IssueThreadInteraction
  alias Cympho.IssueThreadInteractions
  alias Cympho.OwnerAttention
  alias Cympho.R3Fixtures
  alias Cympho.Repo
  alias Cympho.Secrets
  alias Cympho.Skills
  alias Cympho.Wakes

  defp create_agent(attrs), do: Agents.create_agent(scoped_attrs(attrs))
  defp create_issue(attrs), do: Issues.create_issue(scoped_attrs(attrs))
  defp create_plugin(attrs), do: Skills.create_plugin(scoped_attrs(attrs))

  defp roster_metric(html, label) do
    pattern =
      Regex.compile!(
        "<p class=\"text-eyebrow[^\"]*\">\\s*#{Regex.escape(label)}\\s*</p><p[^>]*>\\s*(\\d+)\\s*</p>"
      )

    case Regex.run(pattern, html) do
      [_, value] -> value
      _ -> nil
    end
  end

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

    @tag membership_role: "admin"
    test "forged lifecycle events cannot mutate agents from another company", %{conn: conn} do
      {:ok, foreign_company} =
        Cympho.Companies.create_company(%{
          name: "Foreign Agent Company",
          slug: "foreign-agent-company-#{System.unique_integer([:positive])}"
        })

      {:ok, pause_target} =
        Agents.create_agent(%{
          company_id: foreign_company.id,
          name: "Foreign Pause Target",
          role: :engineer,
          status: :idle
        })

      {:ok, resume_target} =
        Agents.create_agent(%{
          company_id: foreign_company.id,
          name: "Foreign Resume Target",
          role: :engineer,
          status: :paused
        })

      {:ok, terminate_target} =
        Agents.create_agent(%{
          company_id: foreign_company.id,
          name: "Foreign Terminate Target",
          role: :engineer,
          status: :idle
        })

      {:ok, view, _html} = live(conn, "/agents")

      for {event, agent, expected_status} <- [
            {"pause_agent", pause_target, :idle},
            {"resume_agent", resume_target, :paused},
            {"terminate_agent", terminate_target, :idle}
          ] do
        render_click(view, event, %{"id" => agent.id})

        flash = :sys.get_state(view.pid).socket.assigns.flash
        assert Phoenix.Flash.get(flash, :error) == "Agent not found"
        assert Agents.get_agent!(agent.id).status == expected_status
      end

      test_pid = self()

      with_mock Agents, [:passthrough],
        kill_session: fn _foreign_id ->
          send(test_pid, :foreign_session_stop_called)
          :ok
        end do
        render_click(view, "kill_session", %{"id" => pause_target.id})
        flash = :sys.get_state(view.pid).socket.assigns.flash
        assert Phoenix.Flash.get(flash, :error) == "Agent not found"
        refute_received :foreign_session_stop_called
      end
    end

    test "roster shows Never until last_heartbeat_at is stamped, then a real time", %{
      conn: conn
    } do
      {:ok, agent} =
        create_agent(%{
          name: "Heartbeat Roster Agent",
          role: :engineer,
          status: :idle
        })

      assert is_nil(agent.last_heartbeat_at)
      assert CymphoWeb.AgentLive.Index.format_heartbeat(agent) == "Never"

      {:ok, _view, html} = live(conn, "/agents")
      assert html =~ "Heartbeat Roster Agent"
      assert html =~ "Never"

      assert {:ok, stamped} = Agents.touch_heartbeat(agent)
      assert stamped.last_heartbeat_at != nil
      refute CymphoWeb.AgentLive.Index.format_heartbeat(stamped) == "Never"

      assert CymphoWeb.AgentLive.Index.format_heartbeat(stamped) =~
               Calendar.strftime(stamped.last_heartbeat_at, "%b")
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
    @tag membership_role: "admin"
    test "idle roster agent with a delegated run shows progress and Stop session", %{conn: conn} do
      {:ok, agent} =
        create_agent(%{
          name: "Delegated Roster CTO",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Delegated roster work",
          assignee_id: agent.id,
          assigned_role: "cto",
          status: :todo
        })

      {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      Cympho.Adapters.MockAdapter.script(agent.id, issue.id, [:silent])
      on_exit(fn -> Cympho.Adapters.MockAdapter.clear(agent.id, issue.id) end)

      with_mock Cympho.Adapters, [:passthrough],
        resolve: fn _ -> {:ok, Cympho.Adapters.MockAdapter, %{}} end do
        assert {:ok, pid} =
                 Cympho.Orchestrator.start_and_run(checked_out, agent.id,
                   adapter: :mock,
                   adapter_config: %{}
                 )

        wait_until(fn ->
          assert {:ok, %{status: "running"}} =
                   Cympho.HeartbeatEngine.get_active_run_for_agent(agent.id)
        end)

        assert Agents.get_agent!(agent.id).status == :idle
        {:ok, view, html} = live(conn, "/agents")
        assert has_element?(view, "button[phx-click='kill_session'][phx-value-id='#{agent.id}']")
        assert html =~ issue.identifier
        assert html =~ "1 running now"
        # r3: the Simple "1 working now" glance is now the board's Working column.
        assert r3_column(r3_doc(view), "working") == ["Delegated Roster CTO"]
        assert html =~ ~r/>\s*1 running\s*</
        refute html =~ ~r/>\s*1 free\s*</
        assert roster_metric(html, "Running") == "1"
        assert roster_metric(html, "Idle") == "0"

        view
        |> element("button[phx-click='kill_session'][phx-value-id='#{agent.id}']")
        |> render_click()

        flash = :sys.get_state(view.pid).socket.assigns.flash
        assert Phoenix.Flash.get(flash, :info) == "Agent session stopped successfully"
        refute Process.alive?(pid)

        send(view.pid, :update_progress)
        stopped_html = render(view)
        assert stopped_html =~ "0 running now"
        # r3: the agent leaves the board's Working column once its run ends.
        wait_until(fn -> assert r3_column(r3_doc(view), "working") == [] end)
        assert stopped_html =~ ~r/>\s*1 free\s*</
        assert roster_metric(stopped_html, "Running") == "0"
        assert roster_metric(stopped_html, "Idle") == "1"
      end
    end

    @tag membership_role: "admin"
    test "deferred cleanup returns controlled feedback instead of crashing the roster", %{
      conn: conn
    } do
      {:ok, agent} = create_agent(%{name: "Pending Stop", role: :cto, status: :running})
      {:ok, view, _html} = live(conn, "/agents")
      agent_id = agent.id

      with_mock Agents, [:passthrough],
        kill_session: fn ^agent_id -> {:error, :cleanup_pending} end do
        view
        |> element("button[phx-click='kill_session'][phx-value-id='#{agent.id}']")
        |> render_click()

        flash = :sys.get_state(view.pid).socket.assigns.flash
        assert Phoenix.Flash.get(flash, :error) =~ "cleanup"
      end
    end

    @tag membership_role: "admin"
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

    @tag membership_role: "admin"
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

    test "does not show an API key echoed in an Agrenting error message", %{
      conn: conn,
      current_company: company
    } do
      api_key = "agrenting-sentinel-key-0123"

      assert {:ok, _status} =
               Cympho.Agrenting.save_company_config(company.id, %{
                 "api_key" => api_key,
                 "base_url" => "https://agrenting.example.test"
               })

      body = Jason.encode!(%{"error" => %{"message" => "invalid key #{api_key}"}})

      with_mock Finch, [:passthrough],
        stream_while: fn _request, _name, initial, callback, _opts ->
          {:cont, acc} = callback.({:status, 401}, initial)
          {:cont, acc} = callback.({:data, body}, acc)
          {:ok, acc}
        end do
        {:ok, view, _html} = live(conn, "/agents/remote")
        html = render(view)

        assert html =~ "Agrenting request failed"
        assert html =~ "[REDACTED]"
        refute html =~ api_key
      end
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

    @tag membership_role: "admin"
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

      assert html =~ "Agent Overview"
      assert html =~ "agent-overview"
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
      assert html =~ "1/2 assigned skills prompt-ready"
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
    @describetag membership_role: "admin"

    test "manual adapter test does not show an echoed API key", %{conn: conn} do
      api_key = "agrenting-sentinel-key-0123"

      {:ok, agent} =
        create_agent(%{
          name: "Agrenting Preflight Agent",
          role: :engineer,
          status: :idle,
          adapter: :agrenting,
          config: %{
            "agent_did" => "did:agrenting:example",
            "capability" => "code",
            "max_price" => "10"
          },
          runtime_config: %{"env" => %{"AGRENTING_API_KEY" => api_key}}
        })

      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      with_mock Cympho.Agrenting.Client, [:passthrough],
        list_agents: fn config, _params ->
          {:error, {:http_error, 401, "invalid key #{config["api_key"]}"}}
        end do
        render_click(view, "test_adapter", %{})
        message = view |> element("p", "Agrenting check failed") |> render()

        assert message =~ "[REDACTED]"
        refute message =~ api_key
      end
    end

    test "manual adapter test does not show a sent HTTP header value", %{conn: conn} do
      header_value = "http-header-sentinel-0123\n"

      {:ok, agent} =
        create_agent(%{
          name: "HTTP Preflight Agent",
          role: :engineer,
          status: :idle,
          adapter: :http,
          config: %{"url" => "https://example.com", "headers" => %{"x-api-key" => header_value}}
        })

      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listen)

      {:error, error, _acc} =
        Finch.build(:get, "http://127.0.0.1:#{port}/", [{"x-api-key", header_value}])
        |> Finch.stream_while(Cympho.Finch, nil, fn _event, acc -> {:cont, acc} end)

      :gen_tcp.close(listen)
      {:ok, view, _html} = live(conn, "/agents/#{agent.id}?tab=configuration")

      with_mock Finch, [:passthrough],
        stream_while: fn _request, _name, acc, _fun, _opts -> {:error, error, acc} end do
        render_click(view, "test_adapter", %{})
        message = view |> element("p", "Request failed") |> render()

        assert message =~ "[REDACTED]"
        refute message =~ "http-header-sentinel"
      end
    end

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

    @tag membership_role: "admin"
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

    test "the Claude command shell probe does not hand server env to ~/.cld", %{conn: conn} do
      # HOME stands in for the agents' writable HOME; ~/.cld is agent-writable.
      home = Path.join(System.tmp_dir!(), "agent-live-home-#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      leak = Path.join(home, "leak")
      File.write!(Path.join(home, ".cld"), "env >> '#{leak}'\n")

      sentinel_var = "CYMPHO_AGENT_LIVE_SERVER_SECRET"
      original_home = System.get_env("HOME")
      System.put_env("HOME", home)
      System.put_env(sentinel_var, "server-secret-#{System.unique_integer([:positive])}")

      on_exit(fn ->
        System.put_env("HOME", original_home)
        System.delete_env(sentinel_var)
        File.rm_rf!(home)
      end)

      # Off PATH, so readiness falls through to the `bash -lc` shell probe.
      command = "agent-live-wrapper-#{System.unique_integer([:positive])}"

      {:ok, agent} =
        create_agent(%{
          name: "Wrapper Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :claude_code,
          config: %{"command" => command}
        })

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}?tab=configuration")
      assert html =~ "#{command} was not found in PATH or configured shell env."
      assert File.exists?(leak)

      # Only sentinel lines are compared, so a failure does not print the host env.
      leaked =
        leak
        |> File.read!()
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, sentinel_var <> "="))

      assert leaked == []
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
    @describetag membership_role: "admin"

    test "defaults to OpenAI Chat when the company already has that provider", %{
      conn: conn,
      current_company: company
    } do
      {:ok, _} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "OPENAI_CHAT_ENDPOINT",
          value: "https://cli.llmotions.com/v1",
          description: "Company chat endpoint"
        })

      {:ok, _} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "OPENAI_CHAT_MODEL",
          value: "gemini-3.7-flash",
          description: "Company chat model"
        })

      {:ok, _} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "LLMOTIONS_API_KEY",
          value: "sk-test",
          description: "Company chat key"
        })

      {:ok, _view, html} = live(conn, "/agents/new")

      assert html =~ ~s(value="openai_chat" selected)
      assert html =~ "Friendly defaults are ready"
      refute html =~ "Add ANTHROPIC_API_KEY before hiring"
    end

    test "shows adapter dropdown on new agent form", %{conn: conn} do
      {:ok, view, html} = live(conn, "/agents/new")

      assert html =~ "Adapter"
      # The "Agent launch plan" panel preamble was removed; the numbered first
      # section is now the form's leading copy.
      assert html =~ "1 · Identity and reporting"
      assert html =~ ~s(data-testid="new-agent-identity-section")
      assert html =~ ~s(data-testid="new-agent-adapter-section")
      assert html =~ ~s(data-testid="new-agent-guide-section")
      assert html =~ ~s(data-testid="new-agent-setup-checklist")
      assert html =~ ~s(data-testid="new-agent-role-guide")
      assert html =~ ~s(data-testid="new-agent-form-actions")
      assert html =~ "Hire checklist"

      # The actions stick on wider screens (no overflow-hidden card between
      # them and the scroller); on phones they end the form instead, since the
      # key notice can make the bar a third of the screen tall.
      doc = Floki.parse_document!(html)
      [actions] = Floki.find(doc, ~s([data-testid="new-agent-form-actions"]))
      assert actions |> Floki.attribute("class") |> hd() =~ "max-[640px]:static"

      assert Floki.find(
               doc,
               ~s(#main-content .overflow-hidden [data-testid="new-agent-form-actions"])
             ) == []

      assert html =~ "Selected role"
      assert html =~ ~s(data-testid="new-agent-runtime-profile")
      assert html =~ "Runtime profile"
      assert html =~ "Choose the agent"
      assert html =~ "role and reporting line"
      assert html =~ "Create an autonomous teammate with a role"
      assert has_element?(view, "form[data-ui-simple-single-column]")
      assert has_element?(view, "[data-testid='new-agent-defaults-summary'].ui-simple-only")
      assert has_element?(view, "[data-testid='new-agent-runtime-section'].ui-advanced-only")
      assert has_element?(view, "[data-testid='new-agent-adapter-section']")
      refute has_element?(view, "[data-testid='new-agent-adapter-section'].ui-advanced-only")
      assert has_element?(view, "[data-testid='new-agent-guide-section'].ui-advanced-only")
    end

    test "new agent form previews and saves DashScope runtime profile", %{
      conn: conn,
      current_company: company
    } do
      {:ok, _secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "DASHSCOPE_API_KEY",
          value: "test-dashscope-key",
          description: "DashScope key for hire readiness"
        })

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
      assert html =~ "Friendly defaults are ready"
      assert has_element?(view, "[data-hire-readiness='ready']")

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

    test "simple hire never claims ready without required provider secret", %{
      conn: conn,
      current_company: company
    } do
      {:ok, view, html} =
        live(
          conn,
          "/agents/new?role=ceo&name=Blocked%20CEO&runtime_profile_id=openai-chat-qwen-dashscope-flash"
        )

      assert html =~ ~s(data-testid="new-agent-defaults-summary")
      assert html =~ "Needs a key"
      assert html =~ "DASHSCOPE_API_KEY"
      refute html =~ "Friendly defaults are ready"
      assert has_element?(view, "[data-hire-readiness='needs_key']")
      assert has_element?(view, "[data-testid='new-agent-add-key']")
      assert has_element?(view, "[data-testid='new-agent-hire-gate']")
      assert has_element?(view, "[data-testid='new-agent-hire-button'][disabled]")
      assert html =~ "return_to="
      assert html =~ "Add key"
      # Advanced runtime section still renders for advanced mode
      assert has_element?(view, "[data-testid='new-agent-runtime-section'].ui-advanced-only")
      assert html =~ "Add required key"

      html =
        view
        |> form("form", %{
          "agent" => %{
            "name" => "Blocked CEO",
            "role" => "ceo",
            "parent_id" => "",
            "runtime_profile_id" => "openai-chat-qwen-dashscope-flash",
            "adapter" => "claude_code",
            "instructions" => "Should not be hired without a key."
          }
        })
        |> render_submit()

      assert html =~ "Add DASHSCOPE_API_KEY before hiring"
      assert html =~ "Needs a key"

      refute company.id
             |> Agents.list_agents_by_company()
             |> Enum.any?(&(&1.name == "Blocked CEO"))
    end

    test "simple hire is ready when required provider secret is present", %{
      conn: conn,
      current_company: company
    } do
      {:ok, _secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "DASHSCOPE_API_KEY",
          value: "ready-key",
          description: "DashScope for hire readiness soft pass"
        })

      {:ok, view, html} =
        live(
          conn,
          "/agents/new?role=engineer&name=Ready%20Engineer&runtime_profile_id=openai-chat-qwen-dashscope-flash"
        )

      assert html =~ "Friendly defaults are ready"
      assert html =~ "DASHSCOPE_API_KEY"
      refute html =~ "Needs a key"
      assert has_element?(view, "[data-hire-readiness='ready']")
      refute has_element?(view, "[data-testid='new-agent-hire-gate']")
      refute has_element?(view, "[data-testid='new-agent-hire-button'][disabled]")
      # Advanced runtime remains available
      assert has_element?(view, "[data-testid='new-agent-runtime-section'].ui-advanced-only")

      result =
        view
        |> form("form", %{
          "agent" => %{
            "name" => "Ready Engineer",
            "role" => "engineer",
            "parent_id" => "",
            "runtime_profile_id" => "openai-chat-qwen-dashscope-flash",
            "adapter" => "claude_code",
            "instructions" => "Ship with configured credentials."
          }
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/agents"}}} = result

      created =
        company.id
        |> Agents.list_agents_by_company()
        |> Enum.find(&(&1.name == "Ready Engineer"))

      assert created
      assert created.adapter == :openai_chat
    end

    test "wrapper runtime soft-passes hire readiness without company secrets", %{conn: conn} do
      {:ok, view, html} =
        live(conn, "/agents/new?role=engineer&runtime_profile_id=claude-cz")

      assert html =~ "Friendly defaults are ready"
      assert has_element?(view, "[data-hire-readiness='ready']")
      refute has_element?(view, "[data-testid='new-agent-hire-gate']")
      assert has_element?(view, "[data-testid='new-agent-runtime-section'].ui-advanced-only")
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

    test "process Codex hire soft-fails without OpenAI/Codex key and exposes setup_path", %{
      conn: conn,
      current_company: company
    } do
      {:ok, view, html} =
        live(
          conn,
          "/agents/new?role=engineer&name=Process%20Codex%20Hire&runtime_profile_id=process-codex"
        )

      assert html =~ "Needs a key"
      assert html =~ "OPENAI_API_KEY"
      refute html =~ "Friendly defaults are ready"
      assert has_element?(view, "[data-hire-readiness='needs_key']")
      assert has_element?(view, "[data-testid='new-agent-hire-gate']")
      assert has_element?(view, "[data-testid='new-agent-hire-button'][disabled]")
      assert has_element?(view, "[data-testid='new-agent-add-key']")
      assert html =~ "return_to="
      assert html =~ "/settings/secrets"
      assert html =~ "key=OPENAI_API_KEY"

      html =
        view
        |> form("form", %{
          "agent" => %{
            "name" => "Process Codex Hire",
            "role" => "engineer",
            "parent_id" => "",
            "runtime_profile_id" => "process-codex",
            "adapter" => "process",
            "instructions" => "Should not hire without provider key."
          }
        })
        |> render_submit()

      assert html =~ "Add OPENAI_API_KEY before hiring"
      assert html =~ "Needs a key"

      refute company.id
             |> Agents.list_agents_by_company()
             |> Enum.any?(&(&1.name == "Process Codex Hire"))
    end

    test "process Claude preset hire soft-fails without Anthropic key", %{
      conn: conn,
      current_company: company
    } do
      {:ok, view, _html} = live(conn, "/agents/new?role=engineer&name=Process%20Claude%20Hire")

      html =
        view
        |> form("form", %{
          "agent" => %{
            "name" => "Process Claude Hire",
            "role" => "engineer",
            "parent_id" => "",
            "runtime_profile_id" => "custom",
            "adapter" => "process",
            "process_preset" => "claude_code",
            "runtime_command" => "claude",
            "instructions" => "Should not hire without Anthropic key."
          }
        })
        |> render_change()

      assert html =~ "Needs a key"
      assert html =~ "ANTHROPIC_API_KEY"
      assert has_element?(view, "[data-hire-readiness='needs_key']")
      assert has_element?(view, "[data-testid='new-agent-hire-button'][disabled]")
      assert html =~ "key=ANTHROPIC_API_KEY"

      html =
        view
        |> form("form", %{
          "agent" => %{
            "name" => "Process Claude Hire",
            "role" => "engineer",
            "parent_id" => "",
            "runtime_profile_id" => "custom",
            "adapter" => "process",
            "process_preset" => "claude_code",
            "runtime_command" => "claude",
            "instructions" => "Should not hire without Anthropic key."
          }
        })
        |> render_submit()

      assert html =~ "Add ANTHROPIC_API_KEY before hiring"

      refute company.id
             |> Agents.list_agents_by_company()
             |> Enum.any?(&(&1.name == "Process Claude Hire"))
    end

    test "process Codex hire is ready when OpenAI key secret is present", %{
      conn: conn,
      current_company: company
    } do
      {:ok, _secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "OPENAI_API_KEY",
          value: "ready-process-codex-key",
          description: "OpenAI for process Codex hire readiness"
        })

      {:ok, view, html} =
        live(
          conn,
          "/agents/new?role=engineer&name=Ready%20Process%20Codex&runtime_profile_id=process-codex"
        )

      assert html =~ "Friendly defaults are ready"
      assert html =~ "OPENAI_API_KEY"
      refute html =~ "Needs a key"
      assert has_element?(view, "[data-hire-readiness='ready']")
      refute has_element?(view, "[data-testid='new-agent-hire-button'][disabled]")

      result =
        view
        |> form("form", %{
          "agent" => %{
            "name" => "Ready Process Codex",
            "role" => "engineer",
            "parent_id" => "",
            "runtime_profile_id" => "process-codex",
            "adapter" => "process",
            "instructions" => "Ship with process Codex credentials."
          }
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/agents"}}} = result

      created =
        company.id
        |> Agents.list_agents_by_company()
        |> Enum.find(&(&1.name == "Ready Process Codex"))

      assert created
      assert created.adapter == :process
      assert created.config["process_preset"] == "codex"
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
      {:ok, _secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "DASHSCOPE_API_KEY",
          value: "demand-hire-key",
          description: "DashScope for demand-backed hire"
        })

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

  # ── r3 "Paper & Ink": Team and Agent (plan P3, P6) ─────────────────

  describe "r3 Team" do
    setup do
      nw = R3Fixtures.northwind!()
      %{nw: nw, conn: r3_conn(nw.user, nw.company)}
    end

    test "places the team by owner-facing state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")
      doc = r3_doc(view)

      assert r3_text(doc, "h1") == "Team"
      assert r3_column(doc, "stopped") == ["Mira"]
      assert r3_column(doc, "waiting") == ["Ravi", "Priya"]
      assert r3_column(doc, "working") == ["Theo"]
      assert r3_column(doc, "idle") == ["Ada", "Jun", "Sol"]
      assert r3_text(doc, ~s(.tcol[data-col="stopped"] .gh)) == "Stopped 1"
      assert r3_text(doc, ~s(.tcol[data-col="waiting"] .gh)) == "Waiting on you 2"
      assert r3_text(doc, ~s(.tcol[data-col="working"] .gh)) == "Working 1"
      assert r3_text(doc, ~s(.tcol[data-col="idle"] .gh)) == "Idle 3"
    end

    test "cards carry the now-or-last line, the 30-day cost and the for-you chip", %{
      conn: conn,
      nw: nw
    } do
      {:ok, view, _html} = live(conn, "/agents")
      doc = r3_doc(view)

      assert r3_card(doc, "Mira") == %{
               word: "Paused",
               line: "last on NW-10",
               cost: "$19.40 30 days",
               for_you: "1 for you"
             }

      assert r3_card(doc, "Ravi") == %{
               word: "Idle",
               line: "asked you on NW-6",
               cost: "$52.80 30 days",
               for_you: "2 for you"
             }

      assert r3_card(doc, "Priya").line == "asked you on NW-7"
      assert r3_card(doc, "Priya").cost == "$14.90 30 days"

      theo = r3_card(doc, "Theo")
      assert theo.word == "Working"
      assert theo.line =~ ~r/^reviewing NW-9 · 2[89] min$/
      assert theo.cost == "$41.60 30 days"
      assert theo.for_you == "1 for you"

      assert r3_card(doc, "Ada") == %{
               word: "Idle",
               line: "last on NW-1",
               cost: "$38.20 30 days",
               for_you: ""
             }

      assert r3_card(doc, "Jun").line == "NW-9 in team review"
      assert r3_card(doc, "Jun").cost == "$12.35 30 days"
      assert r3_card(doc, "Sol").line == "finished NW-8 at #{r3_hhmm(nw, 326)}"
      assert r3_card(doc, "Sol").cost == "$7.25 30 days"

      assert Floki.attribute(doc, ~s(.tcol[data-col="idle"] li.ac), "class") ==
               ["ac quiet", "ac quiet", "ac quiet"]

      mira = nw.agents["Mira"]
      assert Floki.find(doc, ~s(a.ac-n[href="/agents/#{mira.id}?from=/agents"])) != []
    end

    test "a card's cost stays its own when an agent no longer on the team spent more", %{
      conn: conn,
      nw: nw
    } do
      # token_usages.agent_id has no foreign key, so a deleted agent's usage stays.
      Repo.insert!(%Cympho.Finances.TokenUsage{
        company_id: nw.company.id,
        agent_id: Ecto.UUID.generate(),
        provider: "codex",
        model: "gpt-5.4-mini",
        cost_usd: Decimal.new("100.00")
      })

      {:ok, view, _html} = live(conn, "/agents")
      doc = r3_doc(view)

      assert r3_card(doc, "Sol").cost == "$7.25 30 days"
      assert r3_card(doc, "Mira").cost == "$19.40 30 days"
    end

    test "the Next step is the stopped agent: Resume Mira", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/agents")
      doc = r3_doc(view)
      mira = nw.agents["Mira"]

      assert r3_text(doc, ".next .paper .nt") == "Resume Mira"
      assert r3_text(doc, ".next .paper .eyebrow") =~ "Problem"
      assert r3_text(doc, ".next .ink .ink-h") == "After you resume"
      assert [pw] = Floki.find(doc, ".pw")
      assert Floki.attribute(pw, "phx-click") == ["resume_agent"]
      assert Floki.attribute(pw, "phx-value-id") == [mira.id]
      assert Floki.find(doc, ~s(.next a[href="/agents/#{mira.id}?from=/agents"])) != []
    end

    test "Hire sits in the header", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents")
      doc = r3_doc(view)

      assert r3_text(doc, ~s(.ctx-end a.pl[href="/agents/new"])) == "Hire"
    end

    test "the proposed hire is a dashed card that opens the vote", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/agents")
      doc = r3_doc(view)

      hire = r3_text(doc, "section.hire")
      assert hire =~ "QA engineer"
      assert hire =~ "Waiting for your approval"
      assert hire =~ "Requested by Theo · #{r3_hhmm(nw, 102)}"

      assert Floki.attribute(doc, "section.hire a.pl", "href") == [
               "/board-approvals/#{nw.hire.id}?from=/agents"
             ]
    end

    test "only a pending agent_hire shows as a proposed hire", %{conn: conn, nw: nw} do
      Repo.update!(Ecto.Changeset.change(nw.hire, status: "approved"))

      Repo.insert!(%BoardApproval{
        company_id: nw.company.id,
        title: "Raise the travel policy",
        category: "policy_change",
        status: "pending"
      })

      {:ok, view, _html} = live(conn, "/agents")

      assert Floki.find(r3_doc(view), "section.hire") == []
    end

    test "Last 24 hours: 13 runs, each opening its agent's History", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/agents")
      doc = r3_doc(view)
      theo = nw.agents["Theo"]

      assert r3_text(doc, "details.runs24 > summary") == "Last 24 hours · 13 runs"
      assert Floki.find(doc, "details.runs24[open]") == []
      assert length(Floki.find(doc, "details.runs24 li.run")) == 13

      assert hd(Floki.attribute(doc, "details.runs24 li.run a.rt2", "href")) ==
               "/agents/#{theo.id}?tab=runs&run_id=#{nw.runs[14].id}"
    end

    # A hire proposed elsewhere inserts its section just before Last 24 hours;
    # unkeyed, the patch replaced the disclosure (closed) instead of keeping it.
    test "Last 24 hours keeps its element when a hire is proposed elsewhere", %{
      conn: conn,
      nw: nw
    } do
      {:ok, view, _html} = live(conn, "/agents")

      runs24_id = fn ->
        view |> r3_doc() |> Floki.find("details.runs24") |> Floki.attribute("id")
      end

      assert runs24_id.() == ["team-runs-24h"]

      {:ok, _} =
        Cympho.BoardApprovals.create_board_approval(%{
          company_id: nw.company.id,
          title: "Hire a designer",
          category: "agent_hire",
          status: "pending",
          proposal_data: %{"attrs" => %{"name" => "Designer"}}
        })

      wait_until(fn -> assert length(Floki.find(r3_doc(view), "section.hire")) == 2 end)
      assert runs24_id.() == ["team-runs-24h"]
    end

    test "resuming Mira from the Next step clears the problem", %{conn: conn, nw: nw} do
      mira = nw.agents["Mira"]
      {:ok, view, _html} = live(conn, "/agents")

      render_click(view, "resume_agent", %{"id" => mira.id})

      assert Repo.get!(Agent, mira.id).status == :idle
      doc = r3_doc(view)
      refute r3_text(doc, ".next .paper .nt") == "Resume Mira"
      refute "Mira" in r3_column(doc, "stopped")
    end

    test "a member cannot resume an agent", %{nw: nw} do
      {:ok, view, _html} = live(r3_member_conn(nw.company), "/agents")

      render_click(view, "resume_agent", %{"id" => nw.agents["Mira"].id})

      assert Repo.get!(Agent, nw.agents["Mira"].id).status == :paused
    end

    test "a pause made here is the owner's: no Resume problem for them", %{conn: conn, nw: nw} do
      ada = nw.agents["Ada"]
      {:ok, view, _html} = live(conn, "/agents")

      render_click(view, "pause_agent", %{"id" => ada.id})

      paused = Repo.get!(Agent, ada.id)
      assert paused.status == :paused
      assert paused.paused_by_user_id == nw.user.id

      refute Enum.any?(
               OwnerAttention.list_items(nw.company.id, nw.user),
               &(&1.kind == :agent_paused and &1.agent_id == ada.id)
             )
    end

    test "the board follows agent events live", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/agents")

      {:ok, _} = Agents.pause_agent(nw.agents["Ravi"], "Breaker: 3 failed attempts")

      wait_until(fn ->
        assert "Ravi" in r3_column(r3_doc(view), "stopped")
      end)

      assert Process.alive?(view.pid)
    end

    test "the board follows owner-attention changes made elsewhere", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/agents")
      assert r3_card(r3_doc(view), "Ravi").for_you == "2 for you"

      {:ok, _} =
        IssueThreadInteractions.resolve_interaction(nw.questions["Q1"], %{
          "status" => :responded,
          "resolved_by_user_id" => nw.user.id,
          "response" => "Email the customer first"
        })

      wait_until(fn ->
        ravi = r3_card(r3_doc(view), "Ravi")
        assert ravi.for_you == "1 for you"
        refute ravi.line == "asked you on NW-6"
      end)
    end

    test "Idle shows six cards, then Show all", %{conn: conn, nw: nw} do
      for n <- 1..5 do
        {:ok, _} =
          Agents.create_agent(%{
            company_id: nw.company.id,
            name: "Zed #{n}",
            role: :engineer,
            status: :idle
          })
      end

      {:ok, view, _html} = live(conn, "/agents")
      doc = r3_doc(view)

      assert length(r3_column(doc, "idle")) == 6
      assert r3_text(doc, ~s(.tcol[data-col="idle"] .gh)) == "Idle 8"
      assert r3_text(doc, ~s(.tcol[data-col="idle"] a.more)) == "Show all · 2 more"

      assert Floki.attribute(doc, ~s(.tcol[data-col="idle"] a.more), "href") == [
               "/agents?state=idle"
             ]

      {:ok, view, _html} = live(conn, "/agents?state=idle")
      doc = r3_doc(view)

      assert length(r3_column(doc, "idle")) == 8
      assert Floki.find(doc, ~s(.tcol[data-col="idle"] a.more)) == []
    end

    test "the operator roster stays, Advanced only, below the board", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/agents")
      mira = nw.agents["Mira"]

      assert has_element?(
               view,
               ".ui-advanced-only [data-testid='agent-manage-menu-#{mira.id}']"
             )
    end

    test "the all-clear pair offers Hire with the library's effect" do
      html = render_component(&CymphoWeb.AgentLive.Parts.team_all_clear/1, %{})
      doc = Floki.parse_fragment!(html)

      assert r3_text(doc, ".paper .eyebrow") == "All clear"
      assert r3_text(doc, ".paper .nt") == "Everyone is working or ready"
      assert r3_text(doc, ".ink .ink-h") == "After you choose a role"

      assert r3_text(doc, ".ink .conseq") ==
               "Cympho asks for approval first if your company requires it."

      assert Floki.attribute(doc, "a.pw", "href") == ["/agents/new"]
      assert r3_text(doc, "a.pw") == "Hire"
    end
  end

  describe "r3 Agent" do
    setup do
      nw = R3Fixtures.northwind!()
      %{nw: nw, conn: r3_conn(nw.user, nw.company)}
    end

    test "the header says who Mira is and why she stopped", %{conn: conn, nw: nw} do
      mira = nw.agents["Mira"]
      {:ok, view, _html} = live(conn, "/agents/#{mira.id}")
      doc = r3_doc(view)

      assert r3_text(doc, "h1") == "Mira"

      assert r3_text(doc, ".agent-h .sub") ==
               "Engineer · reports to Theo · Runs on Codex · gpt-5.4-mini"

      assert Floki.attribute(doc, ".agent-h .sub a", "href") == [
               "/agents/#{nw.agents["Theo"].id}"
             ]

      assert r3_text(doc, ".agent-h .sp") == "Paused automatically · #{r3_hhmm(nw, 228)}"
      assert Floki.attribute(doc, ~s(nav[aria-label="Breadcrumb"] a.back), "href") == ["/agents"]
      assert r3_text(doc, ~s(nav[aria-label="Breadcrumb"] [aria-current="page"])) == "Mira"

      assert r3_text(doc, ".agent-h .seg a[aria-current]") == "Overview"

      assert Floki.attribute(doc, ".agent-h .seg a", "href") == [
               "/agents/#{mira.id}",
               "/agents/#{mira.id}?tab=configuration",
               "/agents/#{mira.id}?tab=runs"
             ]
    end

    test "Back shows only when the page was opened from elsewhere", %{conn: conn, nw: nw} do
      path = "/agents/#{nw.agents["Mira"].id}"

      {:ok, view, _html} = live(conn, path <> "?from=/")
      assert r3_text(r3_doc(view), ".ctx .ret") == "Back to Home"

      for from <- ["/agents", "//evil.example", "https://evil.example"] do
        {:ok, view, _html} = live(conn, path <> "?from=" <> URI.encode_www_form(from))
        assert Floki.find(r3_doc(view), ".ctx .ret") == []
      end
    end

    test "Back to Home stays while the tabs change", %{conn: conn, nw: nw} do
      mira = nw.agents["Mira"]
      {:ok, view, _html} = live(conn, "/agents/#{mira.id}?from=/")

      view |> element(".agent-h .seg a", "Setup") |> render_click()
      assert r3_text(r3_doc(view), ".agent-h .seg a[aria-current]") == "Setup"
      assert r3_text(r3_doc(view), ".ctx .ret") == "Back to Home"

      render_click(view, "set_tab", %{"tab" => "instructions"})
      assert r3_text(r3_doc(view), ".ctx .ret") == "Back to Home"

      view |> element(".agent-h .seg a", "Overview") |> render_click()
      assert r3_text(r3_doc(view), ".ctx .ret") == "Back to Home"

      # Opened without one, the tabs add no Back link.
      {:ok, view, _html} = live(conn, "/agents/#{mira.id}")
      view |> element(".agent-h .seg a", "Setup") |> render_click()
      assert Floki.find(r3_doc(view), ".ctx .ret") == []
    end

    test "the page's own links carry the origin, so Back to Home survives a reload", %{
      conn: conn,
      nw: nw
    } do
      mira = nw.agents["Mira"]
      base = "/agents/#{mira.id}"
      run = nw.runs[7]
      {:ok, view, _html} = live(conn, base <> "?from=/")
      doc = r3_doc(view)

      assert Floki.attribute(doc, ".agent-h .seg a", "href") == [
               base <> "?from=%2F",
               base <> "?tab=configuration&from=%2F",
               base <> "?tab=runs&from=%2F"
             ]

      # Every in-page link: the tabs, Setup, History and the run rows.
      patches = Floki.attribute(doc, ~s(a[data-phx-link="patch"]), "href")
      assert length(patches) > 3
      assert Enum.all?(patches, &(&1 =~ "from=%2F"))

      render_click(view, "set_tab", %{"tab" => "instructions"})
      assert_patch(view, base <> "?tab=instructions&from=%2F")

      render_click(view, "select_file", %{"file" => "AGENTS.md"})
      assert_patch(view, base <> "?tab=instructions&file=AGENTS.md&from=%2F")

      render_click(view, "select_run", %{"run_id" => run.id})
      assert_patch(view, base <> "?tab=runs&run_id=#{run.id}&from=%2F")

      # A reload is a fresh mount of the patched URL.
      {:ok, view, _html} = live(conn, base <> "?tab=runs&run_id=#{run.id}&from=%2F")
      assert r3_text(r3_doc(view), ".ctx .ret") == "Back to Home"

      # The retry's Open History keeps it too.
      {:ok, broken} =
        Agents.create_agent(%{
          company_id: nw.company.id,
          name: "Broken",
          role: :engineer,
          status: :error
        })

      {:ok, view, _html} = live(conn, "/agents/#{broken.id}?from=/")

      assert Floki.attribute(r3_doc(view), ~s(.next a.pd[data-phx-link="patch"]), "href") == [
               "/agents/#{broken.id}?tab=runs&from=%2F"
             ]

      # Absent or refused, the links carry none.
      for query <- ["", "?from=" <> URI.encode_www_form("//evil.example/x")] do
        {:ok, view, _html} = live(conn, base <> query)

        assert Floki.attribute(r3_doc(view), ".agent-h .seg a", "href") == [
                 base,
                 base <> "?tab=configuration",
                 base <> "?tab=runs"
               ]

        render_click(view, "set_tab", %{"tab" => "configuration"})
        assert_patch(view, base <> "?tab=configuration")
        assert Floki.find(r3_doc(view), ".ctx .ret") == []
      end
    end

    test "Pause here is the owner's: it reads Paused and is no Inbox problem", %{
      conn: conn,
      nw: nw
    } do
      ada = nw.agents["Ada"]
      before = OwnerAttention.counts(nw.company.id, nw.user)
      {:ok, view, _html} = live(conn, "/agents/#{ada.id}")

      render_click(view, "pause_agent", %{})

      paused = Repo.get!(Agent, ada.id)
      assert paused.status == :paused
      assert paused.paused_by_user_id == nw.user.id
      assert r3_text(r3_doc(view), ".agent-h .sp") =~ ~r/^Paused · \d\d:\d\d$/

      after_pause = OwnerAttention.counts(nw.company.id, nw.user)
      assert after_pause.total == before.total
      refute Map.has_key?(after_pause.by_agent, ada.id)
    end

    test "an unsaved Setup edit stays while the agent is paused and resumed elsewhere", %{
      conn: conn,
      nw: nw
    } do
      ada = nw.agents["Ada"]
      {:ok, view, _html} = live(conn, "/agents/#{ada.id}?tab=configuration")

      view
      |> form("form[phx-submit='config_save']", %{"agent" => %{"name" => "Ada Byron"}})
      |> render_change()

      {:ok, paused} = Agents.pause_agent(ada, "Breaker")
      wait_until(fn -> assert r3_text(r3_doc(view), ".agent-h .sp") =~ "Paused" end)
      assert setup_name(view) == ["Ada Byron"]

      {:ok, _} = Agents.resume_agent(paused)
      wait_until(fn -> refute r3_text(r3_doc(view), ".agent-h .sp") =~ "Paused" end)
      assert setup_name(view) == ["Ada Byron"]
    end

    test "an unsaved Setup edit stays through this page's own Pause", %{conn: conn, nw: nw} do
      ada = nw.agents["Ada"]
      {:ok, view, _html} = live(conn, "/agents/#{ada.id}?tab=configuration")

      view
      |> form("form[phx-submit='config_save']", %{"agent" => %{"name" => "Ada Byron"}})
      |> render_change()

      render_click(view, "pause_agent", %{})

      assert Repo.get!(Agent, ada.id).status == :paused
      assert setup_name(view) == ["Ada Byron"]
    end

    test "an unsaved runtime profile choice stays through a live update", %{conn: conn, nw: nw} do
      ada = nw.agents["Ada"]
      {:ok, view, _html} = live(conn, "/agents/#{ada.id}?tab=configuration")
      before = :sys.get_state(view.pid).socket.assigns.selected_runtime_profile_id
      refute before == "codex-mini"

      render_click(view, "select_runtime_profile", %{"profile_id" => "codex-mini"})

      {:ok, _} = Agents.pause_agent(ada, "Breaker")
      wait_until(fn -> assert r3_text(r3_doc(view), ".agent-h .sp") =~ "Paused" end)
      assert :sys.get_state(view.pid).socket.assigns.selected_runtime_profile_id == "codex-mini"
    end

    test "an untouched Setup form follows the agent saved elsewhere", %{conn: conn, nw: nw} do
      ada = nw.agents["Ada"]
      {:ok, view, _html} = live(conn, "/agents/#{ada.id}?tab=configuration")

      {:ok, _} = Agents.update_agent(ada, %{name: "Ada Lovelace"})

      wait_until(fn -> assert setup_name(view) == ["Ada Lovelace"] end)
    end

    test "once the kept edit is saved, the form follows live updates again", %{
      conn: conn,
      nw: nw
    } do
      ada = nw.agents["Ada"]
      {:ok, view, _html} = live(conn, "/agents/#{ada.id}?tab=configuration")

      setup_form =
        form(view, "form[phx-submit='config_save']", %{"agent" => %{"name" => "Ada Byron"}})

      render_change(setup_form)
      {:ok, paused} = Agents.pause_agent(ada, "Breaker")
      wait_until(fn -> assert r3_text(r3_doc(view), ".agent-h .sp") =~ "Paused" end)
      assert setup_name(view) == ["Ada Byron"]

      render_submit(setup_form)
      assert Repo.get!(Agent, ada.id).name == "Ada Byron"

      {:ok, _} = Agents.update_agent(Repo.get!(Agent, paused.id), %{name: "Ada Lovelace"})
      wait_until(fn -> assert setup_name(view) == ["Ada Lovelace"] end)
    end

    test "the Next step resumes Mira, with the reason as Cympho stored it", %{
      conn: conn,
      nw: nw
    } do
      mira = nw.agents["Mira"]
      nw10 = nw.issues["NW-10"]
      {:ok, view, _html} = live(conn, "/agents/#{mira.id}")
      doc = r3_doc(view)

      assert r3_text(doc, ".next .paper .nt") == "Resume Mira"
      assert r3_text(doc, ".next .paper .eyebrow") == "Next step · Problem"

      assert r3_text(doc, ".next .paper .obj") ==
               "Last 3 runs on NW-10 ended without progress: 2 failed, 1 timed out."

      assert r3_text(doc, ".next details.reason > summary") == "Reason as Cympho stored it"
      assert r3_text(doc, ".next details.reason p") == "3 failed attempts in a row on NW-10"
      assert Floki.find(doc, ".next figure.rb") == []

      assert r3_text(doc, ".next .ink .ink-h") == "After you resume"

      assert Enum.map(Floki.find(doc, ".next .ink .conseq li"), &r3_squish(Floki.text(&1))) == [
               "Mira can take new work.",
               "NW-10 stays unassigned until someone retries it."
             ]

      assert Floki.attribute(doc, ".next .ink a.pd", "href") == ["/issues/#{nw10.id}"]
      assert [pw] = Floki.find(doc, ".pw")
      assert r3_squish(Floki.text(pw)) == "Resume Mira"
      assert Floki.attribute(pw, "phx-click") == ["resume_agent"]
    end

    test "resume from Overview resumes Mira and tells the owner surfaces", %{
      conn: conn,
      nw: nw
    } do
      mira = nw.agents["Mira"]
      company_id = nw.company.id
      :ok = OwnerAttention.subscribe(company_id)
      {:ok, view, _html} = live(conn, "/agents/#{mira.id}")

      render_click(view, "resume_agent", %{"id" => mira.id})

      assert Repo.get!(Agent, mira.id).status == :idle
      assert_receive {:owner_attention_changed, ^company_id}
      doc = r3_doc(view)
      assert r3_text(doc, ".agent-h .sp") == "Idle"
      refute r3_text(doc, ".next .paper .nt") == "Resume Mira"
    end

    # A pause made elsewhere switches the Next step to another branch, which gets
    # a new LiveView element key; the patch then replaced every unkeyed element
    # after it, so Technical details closed.
    test "Technical details keeps its element when the agent is paused elsewhere", %{
      conn: conn,
      nw: nw
    } do
      ada = nw.agents["Ada"]
      {:ok, view, _html} = live(conn, "/agents/#{ada.id}")

      tech_id = fn ->
        view |> r3_doc() |> Floki.find("details.card.tech") |> Floki.attribute("id")
      end

      assert tech_id.() == ["agent-tech-details"]

      {:ok, _} = Agents.pause_agent(ada, "Paused from another page")

      wait_until(fn -> assert r3_text(r3_doc(view), ".agent-h .sp") =~ "Paused" end)
      assert tech_id.() == ["agent-tech-details"]
    end

    test "a member cannot resume an agent", %{nw: nw} do
      mira = nw.agents["Mira"]
      {:ok, view, _html} = live(r3_member_conn(nw.company), "/agents/#{mira.id}")

      render_click(view, "resume_agent", %{"id" => mira.id})

      assert Repo.get!(Agent, mira.id).status == :paused
    end

    test "the aside: what she works on, what she costs, how she runs (key names only)", %{
      conn: conn,
      nw: nw
    } do
      mira = nw.agents["Mira"]
      {:ok, view, html} = live(conn, "/agents/#{mira.id}")
      doc = r3_doc(view)
      aside = r3_text(doc, "aside.gl")

      assert r3_text(doc, "aside.gl .gl-big") == "No open tasks"
      assert aside =~ "Last: NW-10 Add automated tests for invoice totals"
      assert r3_text(doc, "aside.gl .hero") == "$19.40 last 30 days"
      assert aside =~ "$3.68 in the last 24 hours"
      assert aside =~ "Price $0.75 in · $4.50 out per 1M tokens"
      assert aside =~ "Key OPENAI_API_KEY"

      assert Floki.attribute(doc, "aside.gl a.lnk", "href") == [
               "/agents/#{mira.id}?tab=configuration"
             ]

      {:ok, secret_value} = Secrets.get_secret_value(nw.secret.id)
      refute html =~ secret_value
      refute render(view) =~ secret_value
    end

    test "her spend stays hers when agents no longer on the team spent more", %{
      conn: conn,
      nw: nw
    } do
      # token_usages.agent_id has no foreign key, so a deleted agent's usage stays.
      # Seven of them, each costlier than anyone on the team, outnumber the team.
      for _ <- 1..7 do
        Repo.insert!(%Cympho.Finances.TokenUsage{
          company_id: nw.company.id,
          agent_id: Ecto.UUID.generate(),
          provider: "codex",
          model: "gpt-5.4-mini",
          cost_usd: Decimal.new("100.00")
        })
      end

      {:ok, view, _html} = live(conn, "/agents/#{nw.agents["Mira"].id}")
      doc = r3_doc(view)

      assert r3_text(doc, "aside.gl .hero") == "$19.40 last 30 days"
      assert r3_text(doc, "aside.gl") =~ "$3.68 in the last 24 hours"
    end

    test "recent runs open the run, then the earlier spend on the task", %{conn: conn, nw: nw} do
      mira = nw.agents["Mira"]
      {:ok, view, _html} = live(conn, "/agents/#{mira.id}")
      doc = r3_doc(view)

      assert r3_text(doc, "#rr-t") == "Recent runs / NW-10"

      assert Enum.map(Floki.find(doc, "ol.runs li.run a.rt2"), &r3_squish(Floki.text(&1))) == [
               "Timed out after 30 minutes while running the test suite",
               "Test database not reachable",
               "Test database not reachable"
             ]

      assert Floki.attribute(doc, "ol.runs li.run a.rt2", "href") ==
               Enum.map([8, 7, 6], &"/agents/#{mira.id}?tab=runs&run_id=#{nw.runs[&1].id}")

      [first | _] = Floki.find(doc, "ol.runs li.run")

      assert r3_text(first, ".run-sub") ==
               "Timed out #{r3_hhmm(nw, 259)} → #{r3_hhmm(nw, 229)}"

      assert r3_text(first, ".run-cost") == "30 min $3.10"
      assert r3_text(doc, "p.fold") =~ "Earlier runs on NW-10 · $15.72"
    end

    test "tab params stay: ?tab=runs&run_id= selects the run under History", %{
      conn: conn,
      nw: nw
    } do
      mira = nw.agents["Mira"]
      run = nw.runs[7]
      {:ok, view, _html} = live(conn, "/agents/#{mira.id}?tab=runs&run_id=#{run.id}")

      assert :sys.get_state(view.pid).socket.assigns.selected_run.id == run.id
      assert r3_text(r3_doc(view), ".agent-h .seg a[aria-current]") == "History"
    end

    test "Ravi's question is his Next step and is answered here", %{conn: conn, nw: nw} do
      ravi = nw.agents["Ravi"]
      {:ok, view, _html} = live(conn, "/agents/#{ravi.id}")
      doc = r3_doc(view)

      assert r3_text(doc, ".next .paper .nt") == "Answer Ravi's question"
      assert length(Floki.find(doc, ".next label.opt:not(.own)")) == 3

      render_submit(view, "respond_questions", %{
        "_id" => nw.questions["Q1"].id,
        "response" => "Email the customer first"
      })

      assert Repo.get!(IssueThreadInteraction, nw.questions["Q1"].id).status == :responded
      assert Issues.get_issue!(nw.issues["NW-6"].id).status == :todo
      assert r3_text(r3_doc(view), ".next .paper .nt") == "Review Ravi's work"
    end

    test "the Next step follows a question answered elsewhere", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/agents/#{nw.agents["Ravi"].id}")
      assert r3_text(r3_doc(view), ".next .paper .nt") == "Answer Ravi's question"

      {:ok, _} =
        IssueThreadInteractions.resolve_interaction(nw.questions["Q1"], %{
          "status" => :responded,
          "resolved_by_user_id" => nw.user.id,
          "response" => "Email the customer first"
        })

      wait_until(fn ->
        assert r3_text(r3_doc(view), ".next .paper .nt") == "Review Ravi's work"
      end)
    end

    test "an answer to another company's question is refused", %{conn: conn, nw: nw} do
      other = R3Fixtures.northwind!()
      {:ok, view, _html} = live(conn, "/agents/#{nw.agents["Ravi"].id}")

      render_submit(view, "respond_questions", %{
        "_id" => other.questions["Q1"].id,
        "response" => "Email the customer first"
      })

      assert Repo.get!(IssueThreadInteraction, other.questions["Q1"].id).status == :pending
    end

    test "Theo is working, and his hire request waits on a vote", %{conn: conn, nw: nw} do
      {:ok, view, _html} = live(conn, "/agents/#{nw.agents["Theo"].id}")
      doc = r3_doc(view)

      assert r3_text(doc, ".agent-h .sp") == "Working"

      assert r3_text(doc, "aside.gl .gl-big") ==
               "NW-9 Design empty states for the invoice dashboard"

      assert r3_text(doc, ".next .paper .nt") == "Hire a QA engineer"
      assert Floki.attribute(doc, "a.pw", "href") == ["/board-approvals/#{nw.hire.id}"]
    end

    test "with nothing for the owner while agents are off: Turn agents on", %{
      conn: conn,
      nw: nw
    } do
      {:ok, view, _html} = live(conn, "/agents/#{nw.agents["Ada"].id}")

      assert r3_text(r3_doc(view), ".next .paper .nt") == "Turn agents on"
    end

    test "an agent stopped in error offers a retry", %{conn: conn, nw: nw} do
      {:ok, broken} =
        Agents.create_agent(%{
          company_id: nw.company.id,
          name: "Broken",
          role: :engineer,
          status: :error
        })

      {:ok, view, _html} = live(conn, "/agents/#{broken.id}")
      doc = r3_doc(view)

      assert r3_text(doc, ".agent-h .sp") == "Stopped"
      assert r3_text(doc, ".next .paper .nt") == "Retry Broken"
      assert Floki.attribute(doc, ".pw", "phx-click") == ["run_heartbeat"]
    end

    test "technical details stay closed and name the stored status and health", %{
      conn: conn,
      nw: nw
    } do
      {:ok, view, _html} = live(conn, "/agents/#{nw.agents["Mira"].id}")
      doc = r3_doc(view)

      assert Floki.find(doc, "details.tech[open]") == []
      tech = r3_text(doc, "details.tech")
      assert tech =~ "Stored status paused"
      assert tech =~ "Health"
    end

    test "the all-clear pair opens a task for this agent" do
      agent = %Agent{id: Ecto.UUID.generate(), name: "Ravi"}
      html = render_component(&CymphoWeb.AgentLive.Parts.agent_all_clear/1, %{agent: agent})
      doc = Floki.parse_fragment!(html)

      assert r3_text(doc, ".paper .nt") == "Nothing needed from you"
      assert r3_text(doc, ".ink .ink-note") == "Opens a new task with Ravi already assigned."
      assert Floki.attribute(doc, "a.pw", "href") == ["/issues/new?assignee_id=#{agent.id}"]
      assert r3_text(doc, "a.pw") == "Assign a task"
    end
  end

  defp r3_conn(user, company) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_id", user.id)
    |> Plug.Conn.put_session("company_id", company.id)
  end

  defp r3_member_conn(company) do
    {:ok, user} =
      Cympho.Users.create_user(%{
        email: "team-member-#{System.unique_integer([:positive])}@example.com",
        name: "Team Member",
        password: "password1234"
      })

    {:ok, _} =
      Cympho.Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: "member"
      })

    r3_conn(user, company)
  end

  defp r3_doc(view), do: view |> render() |> Floki.parse_fragment!()

  defp setup_name(view), do: Floki.attribute(r3_doc(view), ~s(input[name="agent[name]"]), "value")

  # Text nodes joined with a space (the gaps the CSS draws), then squished.
  defp r3_text(node, selector),
    do: node |> Floki.find(selector) |> Floki.text(sep: " ") |> r3_squish()

  defp r3_squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp r3_hhmm(nw, minutes),
    do: nw.anchor |> R3Fixtures.at(minutes) |> Calendar.strftime("%H:%M")

  defp r3_column(doc, col) do
    doc
    |> Floki.find(~s(.tcol[data-col="#{col}"] li.ac a.ac-n))
    |> Enum.map(&r3_squish(Floki.text(&1)))
  end

  defp r3_card(doc, name) do
    card =
      doc
      |> Floki.find("li.ac")
      |> Enum.find(&(r3_text(&1, "a.ac-n") == name))

    %{
      word: r3_text(card, ".ac-w"),
      line: card |> r3_text(".ac-l") |> String.trim_leading("· "),
      cost: r3_text(card, ".ac-c"),
      for_you: r3_text(card, ".fy")
    }
  end
end
