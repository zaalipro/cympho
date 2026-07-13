defmodule CymphoWeb.OperationsLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Ecto.Query, warn: false
  import Phoenix.LiveViewTest

  alias Cympho.AgentActions
  alias Cympho.Agents
  alias Cympho.Comments
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Inbox
  alias Cympho.Issues
  alias Cympho.Issues.SwarmEvents
  alias Cympho.Projects
  alias Cympho.Repo
  alias Cympho.Secrets
  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake
  alias Cympho.WorkProducts
  alias CymphoWeb.ConnCase

  defp element_attrs(html, selector) do
    html
    |> Floki.parse_document!()
    |> Floki.find(selector)
    |> case do
      [{_tag, attrs, _children} | _rest] -> Map.new(attrs)
      [] -> %{}
    end
  end

  defp link_href(html, label) do
    html
    |> Floki.parse_document!()
    |> Floki.find("a")
    |> Enum.find_value(fn {_tag, attrs, children} ->
      if children |> Floki.text() |> String.trim() == label do
        attrs |> Map.new() |> Map.get("href")
      end
    end)
  end

  describe "Operations page" do
    test "renders runtime services and capacity for a signed-in owner", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, _agent} =
        Agents.create_agent(%{
          name: "Ops Console Engineer",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          health_status: :degraded,
          max_concurrent_jobs: 6,
          company_id: company.id
        })

      {:ok, launch_agent} =
        Agents.create_agent(%{
          name: "Preview Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "__missing_cympho_test_command__", "model" => "custom"},
          company_id: company.id
        })

      {:ok, launch_issue} =
        Issues.create_issue(%{
          title: "Preview runtime preflight",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: launch_agent.id
        })

      {:ok, launch_issue} = Issues.prioritize_for_dispatch(launch_issue)

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Operations"
      assert html =~ "2xl:grid-cols-[minmax(0,1fr)_360px]"
      assert html =~ "Operations Doctor"
      assert html =~ ~s(data-testid="operations-doctor-next-fix")
      assert html =~ "How this is diagnosed"
      assert html =~ "Why this matters"
      assert html =~ "Autonomous dispatch is off"
      assert html =~ "Local concurrency needs attention"
      assert html =~ "Runtime Services"
      assert html =~ "Runtime capacity"
      assert html =~ ~s(data-testid="repo-delivery-capacity")
      assert html =~ "Repo delivery lane"
      assert html =~ "Repo-ready"
      assert html =~ "repo-capable slots"
      assert html =~ "Host footprint"
      assert html =~ "BEAM memory"
      assert html =~ "BEAM processes"
      assert html =~ "External CLI memory"
      assert html =~ "CYMPHO_ORCHESTRATOR_ENABLED"
      assert html =~ ~s(id="runtime-broad-launch-command")
      assert html =~ ~s(phx-hook="CopyToClipboard")
      assert html =~ "Broad restart command"
      assert html =~ "Copy command"
      assert html =~ "Required launch env"
      assert html =~ "Optional automation env"
      assert html =~ "Core launch"
      assert html =~ "Optional automation"
      assert html =~ "CYMPHO_START_BACKLOG_PLANNER"
      assert html =~ "CYMPHO_START_OVERSIGHT_PATROL"
      assert html =~ "Launch preview"
      assert html =~ "Review mode is on. 1 issue is queued for focused dispatch"
      assert html =~ "each focused command still runs one issue"
      assert html =~ "broad launch will take the focused queue first"
      assert html =~ "Runtime will take up to 3 issues per poll after launch."

      refute html =~
               "Dispatch can start up to 3 issues per poll. This preview mirrors the dispatcher priority order before any agent is started."

      assert html =~ "max-h-[760px]"
      assert html =~ "1 candidate"
      assert html =~ "1 focused"
      refute html =~ "1 ready"
      assert html =~ "Preview runtime preflight"
      assert html =~ "Operator focus"
      assert html =~ "Agent preflight"
      assert html =~ "View preflight checks"
      assert html =~ "Blocked"
      assert html =~ "1 blocked"
      assert html =~ "__missing_cympho_test_command__ was not found"
      assert html =~ "Edit command"

      assert html =~
               ~s(href="/agents/#{launch_agent.id}?tab=configuration#agent-process-command")

      assert html =~ "Focused restart command"
      assert html =~ ~s(id="runtime-focused-launch-command-#{launch_issue.id}")
      assert html =~ ~s(id="runtime-clear-dispatch-focus-#{launch_issue.id}")
      refute html =~ ~s(id="runtime-queue-dispatch-focus-#{launch_issue.id}")
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{launch_issue.id}"
      assert html =~ "Ops Console Engineer"
      assert html =~ "High pressure"
      assert html =~ "Operator action"
      assert html =~ "Tune Ops Console Engineer"
      assert html =~ "Fix Ops Console Engineer"
      assert html =~ "Needs attention"
      assert html =~ ~s(href="/operations")

      html =
        view
        |> element("#runtime-clear-dispatch-focus-#{launch_issue.id}", "Clear dispatch focus")
        |> render_click()

      assert html =~ "Dispatch focus cleared."
      refute html =~ ~s(id="runtime-clear-dispatch-focus-#{launch_issue.id}")
      assert html =~ ~s(id="runtime-queue-dispatch-focus-#{launch_issue.id}")
      refute launch_issue.id |> Issues.get_issue!() |> Issues.dispatch_pinned?()

      html =
        view
        |> element("#runtime-queue-dispatch-focus-#{launch_issue.id}", "Queue dispatch focus")
        |> render_click()

      assert html =~ "Dispatch focus queued."
      assert html =~ "Operator focus"
      assert html =~ ~s(id="runtime-clear-dispatch-focus-#{launch_issue.id}")
      refute html =~ ~s(id="runtime-queue-dispatch-focus-#{launch_issue.id}")
      assert launch_issue.id |> Issues.get_issue!() |> Issues.dispatch_pinned?()
    end

    test "uses the shared compact and detailed density switcher", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, parent_issue} =
        Issues.create_issue(%{
          title: "Operations density parent",
          status: :todo,
          priority: :medium,
          company_id: company.id
        })

      {:ok, _view, html} = live(conn, "/operations?parent_issue_id=#{parent_issue.id}")

      assert html =~ ~s(data-ui-complex-page)
      assert html =~ ~s(data-density="compact")
      assert link_href(html, "Compact") == "/operations?parent_issue_id=#{parent_issue.id}"

      detailed_href = link_href(html, "Detailed")
      assert detailed_href =~ "/operations?"
      assert detailed_href =~ "density=detailed"
      assert detailed_href =~ "parent_issue_id=#{parent_issue.id}"

      {:ok, _view, html} =
        live(conn, "/operations?density=detailed&parent_issue_id=#{parent_issue.id}")

      assert html =~ ~s(data-density="detailed")
      assert link_href(html, "Compact") == "/operations?parent_issue_id=#{parent_issue.id}"
      assert link_href(html, "Detailed") =~ "density=detailed"
    end

    test "explains launch-ready adapter health warnings", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, _agent} =
        Agents.create_agent(%{
          name: "Launch Ready Health Warning",
          role: :engineer,
          status: :idle,
          adapter: :process,
          health_status: :degraded,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, _view, html} = live(conn, "/operations")

      assert html =~ "1 warning agent pass launch preflight"
      refute html =~ "Fix Launch Ready Health Warning"
      refute html =~ "Process has unhealthy agents"
    end

    test "keeps a cleared dispatch focus candidate visible in a crowded preview", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Crowded Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, target_issue} =
        Issues.create_issue(%{
          title: "Dispatch focus candidate to clear",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      pinned_issues =
        for index <- 1..6 do
          {:ok, issue} =
            Issues.create_issue(%{
              title: "Pinned runtime candidate #{index}",
              status: :todo,
              priority: :high,
              company_id: company.id,
              assignee_id: agent.id
            })

          {:ok, issue} = Issues.prioritize_for_dispatch(issue)
          issue
        end

      {:ok, target_issue} = Issues.prioritize_for_dispatch(target_issue)

      target_issue =
        target_issue
        |> Ecto.Changeset.change(%{
          monitor_state: %{"dispatch" => %{"pinned_at" => "9999-01-01T00:00:00Z"}}
        })
        |> Repo.update!()

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Dispatch focus candidate to clear"
      assert html =~ ~s(id="runtime-clear-dispatch-focus-#{target_issue.id}")

      html =
        view
        |> element("#runtime-clear-dispatch-focus-#{target_issue.id}", "Clear dispatch focus")
        |> render_click()

      assert html =~ "Dispatch focus cleared."
      assert html =~ "Dispatch focus candidate to clear"
      assert html =~ ~s(id="runtime-queue-dispatch-focus-#{target_issue.id}")

      assert html =~
               "Showing first 6 candidates plus the issue you just updated, of 7 candidates."

      refute html =~ "Showing first 7 of 7 candidates."

      Enum.each(pinned_issues, fn issue ->
        assert issue.id |> Issues.get_issue!() |> Issues.dispatch_pinned?()
      end)
    end

    test "clears the whole focused dispatch queue from launch preview", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Bulk Clear Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      focused_issues =
        for index <- 1..2 do
          {:ok, issue} =
            Issues.create_issue(%{
              title: "Bulk focused runtime candidate #{index}",
              status: :todo,
              priority: :high,
              company_id: company.id,
              assignee_id: agent.id
            })

          {:ok, issue} = Issues.prioritize_for_dispatch(issue)
          issue
        end

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "2 focused"
      assert html =~ "2 issues are queued for focused dispatch"
      assert html =~ ~s(id="runtime-clear-focused-queue")

      html =
        view
        |> element("#runtime-clear-focused-queue", "Clear focused queue")
        |> render_click()

      assert html =~ "Cleared 2 focused dispatch items."
      refute html =~ ~s(id="runtime-clear-focused-queue")
      refute html =~ "2 issues are queued for focused dispatch"

      Enum.each(focused_issues, fn issue ->
        refute issue.id |> Issues.get_issue!() |> Issues.dispatch_pinned?()
      end)
    end

    test "renders provider model and endpoint in launch candidate preflight", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Qwen CEO",
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
          },
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Define company strategy",
          status: :todo,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, _view, html} = live(conn, "/operations")

      assert html =~ "Agent preflight"
      assert html =~ ~s(data-testid="runtime-next-launch-step")
      assert html =~ "Next launch step"
      assert html =~ "Repair CEO owner brief"
      assert html =~ "needs a stronger owner brief before a useful CEO turn"
      refute html =~ ~s(id="runtime-next-launch-command")
      assert html =~ "Brief repair"
      assert html =~ "Repair owner brief"
      assert html =~ "Repair brief"

      assert html =~
               ~s(href="/issues/#{issue.id}?edit=description&amp;repair=owner_brief&amp;return_to=%2Foperations%23runtime-launch-checklist#issue-description")

      assert html =~ ~s(id="runtime-next-brief-repair-scaffold")
      assert html =~ "Paste this into the issue description"
      assert html =~ ~s(data-testid="ceo-flow-candidate-brief")
      assert html =~ "Candidate proof packet"
      assert html =~ "Copy proof packet"
      assert html =~ "Copy command"
      assert html =~ "CEO launch brief"
      assert html =~ "Owner brief 1/6"
      assert html =~ "Too thin for autonomy"
      assert html =~ "Context: Add the facts"
      assert html =~ "Owner brief readiness: Too thin for autonomy (1/6 signals)"
      assert html =~ "Brief repair scaffold"
      assert html =~ "Copy repair scaffold"
      assert html =~ ~s(data-copy-error-label="Scaffold below")
      assert html =~ "Goal: Define company strategy"

      assert html =~
               "Missing signals: Context, Risk/constraint, Done signal, First CEO signal, Evidence."

      assert html =~ "Copy CEO brief"
      assert html =~ "First turn: Return `[owner_update]`, `[handoff]`, or `[blocked]`"
      assert html =~ "waiting on delegated sub-work"
      assert html =~ "No provider call"
      assert html =~ "Provider model"
      assert html =~ "qwen3.7-plus"
      assert html =~ "Gateway endpoint"
      assert html =~ ~s(id="runtime-ceo-launch-brief-)

      assert html =~
               "https://dashscope.aliyuncs.com/compatible-mode/v1"

      command_attrs =
        element_attrs(html, "#ceo-flow-candidate-brief button[data-copy-label='Copy command']")

      assert command_attrs["data-copy-text"] =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"
      assert command_attrs["data-copy-text"] =~ "mise exec -- mix phx.server"

      refute html =~ "secret-key"
    end

    test "creates and focuses a CEO flow smoke-test issue", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Smoke Flow CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "CEO flow verification"
      assert html =~ "Create CEO to CTO smoke"

      html =
        view
        |> element("#ceo-flow-verifier button", "Create CEO to CTO smoke")
        |> render_click()

      assert html =~ "CEO to CTO flow smoke test created and queued for focused dispatch."
      assert html =~ "CEO to CTO flow smoke test"
      assert html =~ "Operator focus"

      [issue] =
        company.id
        |> company_issues()
        |> Enum.filter(&String.starts_with?(&1.title, "CEO to CTO flow smoke test "))

      assert issue.status == :todo
      assert issue.priority == :high
      assert issue.assigned_role == "ceo"
      assert issue.assignee_id == ceo.id
      assert issue.created_by_user_id == user.id

      assert issue.description =~
               "Verify the owner-to-CEO-to-CTO autonomous delegation flow end to end."

      assert issue.description =~ "route technical planning through the CTO"
      assert issue.description =~ "Create or delegate exactly one CTO-owned child issue"
      assert issue.description =~ "acceptance criteria, evidence required, verification required"
      assert issue.description =~ "Mark this parent blocked"
      assert issue.description =~ "Operations CEO flow verification, delegated work queue"
      assert issue.description =~ "[owner_update]"
      assert issue.description =~ "Prefer a `[handoff]` outcome"
      assert issue.id |> Issues.get_issue!() |> Issues.dispatch_pinned?()
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"
    end

    test "renders CEO-delegated child work with owner launch controls", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Delegation Queue CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, product_owner} =
        Agents.create_agent(%{
          name: "Delegation Product Lead",
          role: :product_manager,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, misconfigured_owner} =
        Agents.create_agent(%{
          name: "Misconfigured Product Lead",
          role: :product_manager,
          status: :idle,
          adapter: :process,
          config: %{"command" => "__missing_cympho_test_command__", "model" => "custom"},
          company_id: company.id
        })

      {:ok, parent_issue} =
        Issues.create_issue(%{
          title: "Define CEO launch plan",
          status: :blocked,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      {:ok, child_issue} =
        Issues.create_issue(%{
          title: "Define owner-ready success metrics",
          status: :todo,
          priority: :high,
          assigned_role: "product_manager",
          company_id: company.id,
          parent_id: parent_issue.id,
          assignee_id: product_owner.id,
          created_by_agent_id: ceo.id,
          origin_type: "agent_action",
          origin_id: parent_issue.id
        })

      {:ok, second_child_issue} =
        Issues.create_issue(%{
          title: "Define owner-ready technical checklist",
          status: :todo,
          priority: :high,
          assigned_role: "product_manager",
          company_id: company.id,
          parent_id: parent_issue.id,
          assignee_id: product_owner.id,
          created_by_agent_id: ceo.id,
          origin_type: "agent_action",
          origin_id: parent_issue.id
        })

      {:ok, setup_blocked_child_issue} =
        Issues.create_issue(%{
          title: "Define owner-ready setup-blocked plan",
          status: :todo,
          priority: :high,
          assigned_role: "product_manager",
          company_id: company.id,
          parent_id: parent_issue.id,
          assignee_id: misconfigured_owner.id,
          created_by_agent_id: ceo.id,
          origin_type: "agent_action",
          origin_id: parent_issue.id
        })

      {:ok, unrelated_parent_issue} =
        Issues.create_issue(%{
          title: "Define unrelated CEO launch plan",
          status: :blocked,
          priority: :medium,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      {:ok, unrelated_child_issue} =
        Issues.create_issue(%{
          title: "Define unrelated delegated work",
          status: :todo,
          priority: :medium,
          assigned_role: "product_manager",
          company_id: company.id,
          parent_id: unrelated_parent_issue.id,
          assignee_id: product_owner.id,
          created_by_agent_id: ceo.id,
          origin_type: "agent_action",
          origin_id: unrelated_parent_issue.id
        })

      {:ok, view, html} =
        live(conn, "/operations?parent_issue_id=#{parent_issue.id}#delegated-work-queue")

      parent_identifier = parent_issue.identifier || String.slice(parent_issue.id, 0, 8)

      assert html =~ "Delegated Work Queue"
      assert html =~ "3 open"
      assert html =~ "2 runnable"
      assert html =~ "1 setup blocked"
      assert html =~ "Filtered to"
      assert html =~ parent_identifier
      assert html =~ "Show all delegated work"
      assert html =~ ~s(data-testid="operations-simple-action-queue")
      assert html =~ ~s(data-testid="operations-simple-action-delegated")
      assert html =~ "Action queue"
      assert html =~ "2 runnable delegated items"
      assert html =~ "Focus queue"
      assert html =~ "Run delegated CEO work"
      assert html =~ "Queue runnable work"
      assert html =~ "Define owner-ready success metrics"
      assert html =~ "Define owner-ready technical checklist"
      assert html =~ "Define owner-ready setup-blocked plan"
      refute html =~ ~s(id="delegated-work-focused-command-#{unrelated_child_issue.id}")
      assert html =~ "Delegation Product Lead"
      assert html =~ "Misconfigured Product Lead"
      assert html =~ "Product Manager"
      assert html =~ "Define CEO launch plan"
      assert html =~ "Owner preflight"
      assert html =~ "Focused restart command"
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{child_issue.id}"
      assert html =~ ~s(id="delegated-work-focused-command-#{child_issue.id}")
      assert html =~ ~s(id="delegated-work-queue-dispatch-focus-#{child_issue.id}")
      assert html =~ ~s(id="delegated-work-fix-setup-#{setup_blocked_child_issue.id}")
      refute html =~ ~s(id="delegated-work-queue-dispatch-focus-#{setup_blocked_child_issue.id}")
      refute html =~ ~s(id="delegated-work-clear-dispatch-focus-#{child_issue.id}")

      html =
        view
        |> element("[data-testid='operations-simple-action-button-delegated']")
        |> render_click()

      assert html =~ "Queued 2 delegated work items for focused dispatch."
      assert html =~ ~s(id="delegated-work-clear-dispatch-focus-#{child_issue.id}")
      assert html =~ ~s(id="delegated-work-clear-dispatch-focus-#{second_child_issue.id}")
      refute html =~ ~s(id="delegated-work-queue-dispatch-focus-#{child_issue.id}")
      refute html =~ ~s(id="delegated-work-queue-dispatch-focus-#{second_child_issue.id}")
      assert child_issue.id |> Issues.get_issue!() |> Issues.dispatch_pinned?()
      assert second_child_issue.id |> Issues.get_issue!() |> Issues.dispatch_pinned?()
      refute setup_blocked_child_issue.id |> Issues.get_issue!() |> Issues.dispatch_pinned?()
      refute unrelated_child_issue.id |> Issues.get_issue!() |> Issues.dispatch_pinned?()
    end

    test "renders swarm parent worker and CTO queue when filtered from an issue", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Operations Swarm CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, _cto} =
        Agents.create_agent(%{
          name: "Operations Swarm CTO",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, parent_issue} =
        Issues.create_issue(%{
          title: "Operations-visible swarm delivery",
          description: "Goal: verify Operations shows the swarm queue.",
          status: :todo,
          priority: :high,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id,
          swarm: %{
            "enabled" => "true",
            "agent_count" => "2",
            "mix_rows" => %{
              "0" => %{
                "enabled" => "true",
                "harness" => "process",
                "model" => "custom",
                "reasoning_effort" => "medium"
              }
            }
          }
        })

      children =
        Repo.all(
          from i in Cympho.Issues.Issue,
            where: i.parent_id == ^parent_issue.id,
            order_by: [asc: i.inserted_at, asc: i.title]
        )

      worker_issues = Enum.filter(children, &(&1.origin_type == "swarm_worker"))
      [cto_issue] = Enum.filter(children, &(&1.origin_type == "swarm_cto_review"))

      assert length(worker_issues) == 2

      {:ok, _view, html} =
        live(conn, "/operations?parent_issue_id=#{parent_issue.id}#delegated-work-queue")

      parent_identifier = parent_issue.identifier || String.slice(parent_issue.id, 0, 8)
      swarm_events = SwarmEvents.list_for_parent(parent_issue.id)

      assert html =~ "Delegated Work Queue"
      assert html =~ "3 open"
      assert html =~ "Run swarm queue"
      assert html =~ "Open swarm queue"
      assert html =~ "3 swarm work items under #{parent_identifier}"
      assert html =~ ~s(data-testid="operations-swarm-log")
      assert html =~ "Live swarm log"
      assert html =~ "Launch ready"
      assert html =~ "Swarm is queued: workers feed CTO synthesis, then CEO handoff."
      assert Enum.any?(swarm_events, &(&1.event_type == "launch_ready"))
      assert html =~ "Filtered to"
      assert html =~ "Operations-visible swarm delivery"
      refute html =~ "No open CEO-delegated child work is waiting"
      assert html =~ "Swarm worker"
      assert html =~ "CTO synthesis"
      assert html =~ "Swarm protocol"
      assert html =~ "Synthesize swarm delivery"
      assert html =~ ~s(id="delegated-work-focused-command-#{cto_issue.id}")

      for worker_issue <- worker_issues do
        assert html =~ worker_issue.title
        assert html =~ ~s(id="delegated-work-focused-command-#{worker_issue.id}")
      end
    end

    test "refreshes the main operations queue when a swarm event arrives", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Main Ops Swarm CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, _cto} =
        Agents.create_agent(%{
          name: "Main Ops Swarm CTO",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, view, html} = live(conn, "/operations")

      refute html =~ "Main operations live swarm refresh"

      {:ok, parent_issue} =
        Issues.create_issue(%{
          title: "Main operations live swarm refresh",
          description: "Goal: prove Operations refreshes when a swarm starts.",
          status: :todo,
          priority: :high,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id,
          swarm: %{
            "enabled" => "true",
            "agent_count" => "1",
            "mix_rows" => %{
              "0" => %{
                "enabled" => "true",
                "harness" => "process",
                "model" => "custom",
                "reasoning_effort" => "medium"
              }
            }
          }
        })

      # Poll until the issue-created broadcast has reached the LiveView.
      wait_until(fn -> assert render(view) =~ "Main operations live swarm refresh" end)

      html = render(view)
      child_titles = parent_issue.id |> Issues.list_child_issues() |> Enum.map(& &1.title)

      assert html =~ "Main operations live swarm refresh"
      assert Enum.any?(child_titles, &(html =~ &1))
    end

    test "renders repo-capable runtime warning as an actionable delegated-work recovery link", %{
      conn: conn
    } do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Repo Warning CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, chat_engineer} =
        Agents.create_agent(%{
          name: "Chat-only Engineer",
          role: :engineer,
          status: :idle,
          adapter: :openai_chat,
          config: %{
            "endpoint" => "https://dashscope.example.com/compatible-mode/v1",
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

      {:ok, parent_issue} =
        Issues.create_issue(%{
          title: "Ship repo-writing owner request",
          status: :blocked,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      {:ok, child_issue} =
        Issues.create_issue(%{
          title: "Implement repo-backed delivery",
          status: :todo,
          priority: :high,
          assigned_role: "engineer",
          company_id: company.id,
          parent_id: parent_issue.id,
          assignee_id: chat_engineer.id,
          created_by_agent_id: ceo.id,
          origin_type: "agent_action",
          origin_id: parent_issue.id
        })

      {:ok, _view, html} =
        live(conn, "/operations?parent_issue_id=#{parent_issue.id}#delegated-work-queue")

      assert html =~ "1 review setup"
      assert html =~ "Repo-capable runtime"
      assert html =~ "Open runtime profile"

      assert html =~
               ~s(id="delegated-work-fix-setup-#{child_issue.id}")

      assert html =~
               ~s(href="/agents/#{chat_engineer.id}?tab=configuration#agent-runtime-profile")

      refute html =~ ~s(id="delegated-work-queue-dispatch-focus-#{child_issue.id}")
    end

    test "renders CEO outcome monitor from recent cympho-actions", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Outcome CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, project} =
        Projects.create_project(%{
          name: "CEO Outcome Project",
          prefix: unique_prefix("CEO"),
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Define investor update",
          status: :in_progress,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          project_id: project.id,
          assignee_id: ceo.id
        })

      {:ok, silent_issue} =
        Issues.create_issue(%{
          title: "CEO silent run",
          status: :blocked,
          priority: :high,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      {:ok, thin_receipt_issue} =
        Issues.create_issue(%{
          title: "CEO thin receipt",
          status: :in_progress,
          priority: :high,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      {:ok, failed_issue} =
        Issues.create_issue(%{
          title: "CEO failed run",
          status: :todo,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      {:ok, repeated_failed_issue} =
        Issues.create_issue(%{
          title: "CEO repeated failed run",
          status: :todo,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      assert {:ok, _result} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "comment",
                   "body" =>
                     "[owner_update] What happened: strategy is framed. Business status: not shipped. Evidence inspected: owner request and company context. Verification: checked this needs delegated execution. Remaining risk: implementation scope may change after engineering discovery. Current state: ready to split. Next decision: delegate implementation. Owner decision needed: none."
                 },
                 %{
                   "type" => "create_issue",
                   "title" => "Implement investor dashboard",
                   "description" => "Build the owner-visible investor dashboard.",
                   "role" => "engineer",
                   "priority" => "high",
                   "acceptance_criteria" =>
                     "Investor dashboard shows the owner-visible update clearly.",
                   "evidence_required" =>
                     "Dashboard implementation evidence and final delivery note.",
                   "verification_required" =>
                     "Run a focused dashboard smoke check or name the blocker.",
                   "definition_of_done" =>
                     "Dashboard is ready for review with evidence and risk named."
                 }
               ])

      assert {:ok, _result} =
               AgentActions.execute(thin_receipt_issue, ceo, [
                 %{
                   "type" => "comment",
                   "body" =>
                     "[owner_update] What happened: thin receipt was posted. Business status: not shipped. Current state: routed. Next decision: continue. Owner decision needed: none."
                 }
               ])

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: silent_issue.id,
        adapter: "process",
        status: "completed"
      })

      assert {:ok, _comment} =
               Comments.create_comment(%{
                 body:
                   "Agent response did not include a valid cympho-actions block: :missing_action_block",
                 author_type: "system",
                 author_id: "00000000-0000-0000-0000-000000000000",
                 issue_id: silent_issue.id
               })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: failed_issue.id,
        adapter: "process",
        status: "failed",
        error_reason: "OPENAI_API_KEY not set"
      })

      assert {:ok, _comment} =
               Comments.create_comment(%{
                 body:
                   "Runtime preflight failed: provider credential is missing for CEO runtime.",
                 author_type: "agent",
                 author_id: ceo.id,
                 issue_id: failed_issue.id
               })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: repeated_failed_issue.id,
        adapter: "process",
        status: "failed",
        error_reason: "provider timeout"
      })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: repeated_failed_issue.id,
        adapter: "process",
        status: "failed",
        error_reason: "provider timeout"
      })

      {:ok, _view, html} = live(conn, "/operations")

      assert html =~ "CEO Outcome Monitor"
      assert html =~ "CEO flow verification"
      assert html =~ ~s(data-testid="ceo-flow-verifier")
      assert html =~ "Needs attention"
      assert html =~ "CEO turns need relaunch or contract repair"
      assert html =~ "Open CEO monitor"
      assert html =~ "Next CEO candidate"
      assert html =~ ~s(data-testid="ceo-outcome-header")
      assert html =~ ~s(data-testid="ceo-outcome-health-strip")
      assert html =~ ~s(data-testid="ceo-outcome-metrics")
      assert html =~ ~s(data-testid="ceo-outcome-row")
      assert html =~ "lg:grid-cols-[minmax(0,1fr)_auto]"
      assert html =~ "2xl:grid-cols-7"
      assert html =~ "Recent CEO turns produced"
      assert html =~ "2 owner updates"
      assert html =~ "Owner updates"
      assert html =~ "Acceptances"
      assert html =~ "1 decomposition"
      assert html =~ "1 no-action run"
      assert html =~ "3 failed runs"
      assert html =~ "1 incomplete receipt"
      assert html =~ "Attention"
      assert html =~ "Receipts"
      assert html =~ "Define investor update"
      assert html =~ "CEO thin receipt"
      assert html =~ "CEO silent run"
      assert html =~ "CEO failed run"
      assert html =~ "CEO repeated failed run"
      assert html =~ "Owner update"
      assert html =~ "Decomposition"
      assert html =~ "No action"
      assert html =~ "Failed"
      assert html =~ "strategy is framed"
      assert html =~ "Receipt complete"
      assert html =~ "complete last-action receipt"
      assert html =~ "Receipt gap"

      assert html =~
               "Latest owner update is missing Evidence/artifact, Verification, Remaining risk."

      assert html =~ "Fix receipt and relaunch"
      assert html =~ "Focused relaunch should revise the latest tagged CEO comment"
      assert html =~ "Repair CEO receipt gaps"
      assert html =~ "Open CEO receipts"
      assert html =~ "Created sub-issue"
      assert html =~ "Invalid cympho-actions block"
      assert html =~ "missing_action_block"
      assert html =~ "Runtime preflight failed"
      assert html =~ "OPENAI_API_KEY not set"
      assert html =~ "Recent Runtime Failures"
      assert html =~ ~s(id="runtime-failures")
      assert html =~ "Focused relaunch"
      assert html =~ "Fix and relaunch"
      assert html =~ "Focused relaunch command"
      assert html =~ "Fix the feedback above, then restart runtime focused on this issue."
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{silent_issue.id}"
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{failed_issue.id}"
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{thin_receipt_issue.id}"
      assert html =~ ~s(id="recent-failure-focused-command-)
      assert html =~ ~s(id="ceo-outcome-focused-command-)
      assert html =~ "2 attempts"
      assert html =~ "grouped CEO outcomes"
      assert html =~ "1 duplicate row collapsed"
    end

    test "accepts CEO owner signoff directly from operations", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Signoff Action CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Owner accepts from operations",
          status: :in_progress,
          priority: :high,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: issue.id,
        adapter: "process",
        status: "completed"
      })

      assert {:ok, _comment} =
               Comments.create_comment(%{
                 body:
                   "[owner_update] What happened: CEO verified the business outcome. Business status: ready for owner signoff. Current state: waiting for owner verification. Next decision: accept and close. Owner decision needed: verify closure.",
                 author_type: "agent",
                 author_id: ceo.id,
                 issue_id: issue.id
               })

      assert {:ok, _result} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "block_issue",
                   "reason" => owner_signoff_block_reason()
                 }
               ])

      issue = Issues.get_issue!(issue.id)
      assert Issues.owner_verification_closeable?(issue)

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Owner Signoff Queue"
      assert html =~ "1 waiting"
      assert html =~ "Owner accepts from operations"
      assert html =~ "Accept and close"
      assert html =~ "Accept CEO owner updates"
      assert html =~ ~s(data-testid="operations-simple-action-owner-signoff")
      assert html =~ "1 CEO update waiting"
      assert html =~ ~s(href="#owner-signoff-queue")

      html =
        view
        |> element(
          "button[phx-click='accept_owner_verification'][phx-value-issue-id='#{issue.id}']",
          "Accept and close"
        )
        |> render_click()

      assert html =~ "CEO owner update accepted and issue closed."
      assert html =~ "0 waiting"

      refute has_element?(
               view,
               "button[phx-click='accept_owner_verification'][phx-value-issue-id='#{issue.id}']"
             )

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :done
      refute Issues.owner_verification_closeable?(updated)
    end

    test "requests CEO owner-signoff revision directly from operations", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Signoff Revision CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Owner requests revision from operations",
          status: :in_progress,
          priority: :high,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: issue.id,
        adapter: "process",
        status: "completed"
      })

      assert {:ok, _comment} =
               Comments.create_comment(%{
                 body:
                   "[owner_update] What happened: CEO verified the business outcome. Business status: ready for owner signoff. Current state: waiting for owner verification. Next decision: accept or request revision. Owner decision needed: verify closure.",
                 author_type: "agent",
                 author_id: ceo.id,
                 issue_id: issue.id
               })

      assert {:ok, _result} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "block_issue",
                   "reason" => owner_signoff_block_reason()
                 }
               ])

      issue = Issues.get_issue!(issue.id)
      assert Issues.owner_verification_closeable?(issue)

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Owner Signoff Queue"
      assert html =~ "1 waiting"
      assert html =~ "Owner requests revision from operations"
      assert html =~ "Request revision"

      html =
        view
        |> element(
          "button[phx-click='request_owner_revision'][phx-value-issue-id='#{issue.id}']",
          "Request revision"
        )
        |> render_click()

      assert html =~ "CEO revision requested and focused relaunch queued."
      assert html =~ "0 waiting"
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"

      refute has_element?(
               view,
               "button[phx-click='request_owner_revision'][phx-value-issue-id='#{issue.id}']"
             )

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :todo
      assert updated.assignee_id == ceo.id
      assert Issues.dispatch_pinned?(updated)
      refute Issues.owner_verification_closeable?(updated)

      assert Enum.any?(
               Comments.list_comments(issue.id),
               &String.contains?(&1.body, "owner reopened the CEO verification update")
             )
    end

    test "renders owner-accepted CEO verification outcomes as closed loops", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Accepted Outcome CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Owner accepted CEO verification",
          status: :in_progress,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: issue.id,
        adapter: "process",
        status: "completed"
      })

      assert {:ok, _comment} =
               Comments.create_comment(%{
                 body:
                   "[owner_update] What happened: CEO verified the business outcome. Business status: ready for owner signoff. Current state: waiting for owner verification. Next decision: accept and close. Owner decision needed: verify closure.",
                 author_type: "agent",
                 author_id: ceo.id,
                 issue_id: issue.id
               })

      assert {:ok, _result} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "block_issue",
                   "reason" => owner_signoff_block_reason()
                 }
               ])

      issue = Issues.get_issue!(issue.id)
      assert Issues.owner_verification_closeable?(issue)
      assert {:ok, _closed} = Issues.accept_owner_verification(issue, actor: user)

      {:ok, _view, html} = live(conn, "/operations")

      assert html =~ "CEO Outcome Monitor"
      assert html =~ "1 owner acceptance"
      assert html =~ "Owner accepted"
      assert html =~ "Owner acceptance"
      assert html =~ "Owner accepted CEO verification"
      assert html =~ "Owner accepted the CEO verification update and closed the issue."
      assert html =~ "Done"
      refute html =~ "Blocked the issue."
      refute html =~ "blocked signal"
      refute html =~ "Fix and relaunch"
    end

    test "renders owner-reopened CEO verification outcomes as revision loops", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Revision Outcome CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Owner reopened CEO verification",
          status: :in_progress,
          priority: :critical,
          assigned_role: "ceo",
          company_id: company.id,
          assignee_id: ceo.id
        })

      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: ceo.id,
        issue_id: issue.id,
        adapter: "process",
        status: "completed"
      })

      assert {:ok, _comment} =
               Comments.create_comment(%{
                 body:
                   "[owner_update] What happened: CEO verified the business outcome. Business status: ready for owner signoff. Current state: waiting for owner verification. Next decision: accept or request revision. Owner decision needed: verify closure.",
                 author_type: "agent",
                 author_id: ceo.id,
                 issue_id: issue.id
               })

      assert {:ok, _result} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "block_issue",
                   "reason" => owner_signoff_block_reason()
                 }
               ])

      issue = Issues.get_issue!(issue.id)
      assert Issues.owner_verification_closeable?(issue)
      assert {:ok, _reopened} = Issues.request_owner_verification_revision(issue, actor: user)

      {:ok, _view, html} = live(conn, "/operations")

      assert html =~ "CEO Outcome Monitor"
      assert html =~ "1 owner revision"
      assert html =~ "Owner revision"
      assert html =~ "Owner reopened CEO verification"
      assert html =~ "Owner requested a CEO revision and queued focused relaunch."
      assert html =~ "Todo"
      refute html =~ "Blocked the issue."
      refute html =~ "blocked signal"
      refute html =~ "Fix and relaunch"
    end

    test "recovers stale checked-out issues from runtime capacity", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Stale Slot CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      old_checkout =
        DateTime.utc_now()
        |> DateTime.add(-3 * 60 * 60, :second)
        |> DateTime.truncate(:second)

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Stale issue holding capacity",
          status: :in_progress,
          priority: :critical,
          company_id: company.id,
          assignee_id: agent.id,
          checked_out_at: old_checkout
        })

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Stale checked-out work"
      assert html =~ "Stale issue holding capacity"
      assert html =~ "Recover stale runtime state"
      assert html =~ "0 runs · 1 checkouts"

      html =
        view
        |> element("button", "Recover stale runtime state")
        |> render_click()

      assert html =~ "Ready to enable"
      refute html =~ "Stale checked-out work"
      refute html =~ "Recover stale runtime state"

      assert {:ok, released} = Issues.get_issue(issue.id)
      assert released.status == :todo
      assert released.assignee_id == agent.id
      assert is_nil(released.checked_out_at)
    end

    test "renders text-only repo delivery capacity as an operator warning", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, chat_engineer} =
        Agents.create_agent(%{
          name: "Ops Chat Engineer",
          role: :engineer,
          status: :idle,
          adapter: :openai_chat,
          max_concurrent_jobs: 2,
          company_id: company.id
        })

      {:ok, _view, html} = live(conn, "/operations#runtime-capacity")

      assert html =~ ~s(data-testid="repo-delivery-capacity")
      assert html =~ "Text-only delivery"
      assert html =~ "2 delivery slots can plan"
      assert html =~ "0 repo-capable slots"
      assert html =~ "2 text-only slots"
      assert html =~ "Provision repo delivery runtime"
      assert html =~ "Repo delivery runtime is missing"
      assert html =~ "Hire repo engineer"
      assert html =~ "Convert existing agent"
      assert html =~ "runtime_profile_id=process-codex"

      assert html =~
               ~s(href="/agents/#{chat_engineer.id}?tab=configuration#agent-runtime-profile")
    end

    test "renders missing repo delivery lane with coding-profile hire link", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, _view, html} = live(conn, "/operations#runtime-capacity")

      assert html =~ ~s(data-testid="repo-delivery-capacity")
      assert html =~ "No repo lane"
      assert html =~ "Add engineer"
      assert html =~ "Hire repo engineer"
      assert html =~ "runtime_profile_id=process-codex"
      assert html =~ "name=Repo-capable+Engineer"
      assert html =~ "return_to=%2Foperations%23runtime-capacity"
      refute html =~ "runtime_profile_id=openai-chat-qwen-dashscope-flash"
    end

    test "renders staffing gaps with prefilled hire links in runtime capacity", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Operations CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Shape pricing activation research",
          description: "Product Manager should define acceptance criteria before engineering.",
          status: :todo,
          priority: :high,
          assigned_role: "product_manager",
          company_id: company.id
        })

      {:ok, _view, html} = live(conn, "/operations#runtime-capacity")

      assert html =~ ~s(data-testid="runtime-staffing-gaps")
      assert html =~ "Staffing gaps"
      assert html =~ "Delegated work includes roles with no active agent"
      assert html =~ "staffing gaps, adapter health"
      assert html =~ "Delegated roles have no active agent"
      assert html =~ "Staff delegated role gaps"
      assert html =~ "Product Manager"
      assert html =~ "1 open issue"
      assert html =~ "Reports to Operations CEO"
      assert html =~ "Hire Product Manager"
      assert html =~ "/issues/#{issue.id}"
      assert html =~ issue.identifier
      assert html =~ "role=product_manager"
      assert html =~ "name=Product+Manager"
      assert html =~ "runtime_profile_id=openai-chat-qwen-dashscope-flash"
      assert html =~ "return_to=%2Foperations%23runtime-staffing-gaps"
      assert html =~ "parent_id=#{ceo.id}"
    end

    test "renders prompt drift radar with studio links", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, _risk_agent} =
        Agents.create_agent(%{
          name: "Risky Prompt Agent",
          role: :engineer,
          status: :idle,
          adapter: :claude_code,
          instructions: "Skip comments, no tests, and merge without review.",
          company_id: company.id
        })

      {:ok, regressed_agent} =
        Agents.create_agent(%{
          name: "Regressed UI Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          instructions:
            "Before review include Files changed, Evidence produced, Verification, Risks, current state, next decision, and PR task list.",
          company_id: company.id
        })

      {:ok, _good_revision} = Agents.create_config_revision(regressed_agent)

      {:ok, regressed_agent} =
        Agents.update_agent(regressed_agent, %{instructions: "Do good work."})

      {:ok, _weak_revision} = Agents.create_config_revision(regressed_agent)

      {:ok, _view, html} = live(conn, "/operations")

      assert html =~ "Prompt Drift Radar"
      assert html =~ "How this is diagnosed"
      assert html =~ "Risky Prompt Agent"
      assert html =~ "Guardrail risk"
      assert html =~ "Regressed UI Agent"
      assert html =~ "Score regression"
      assert html =~ "Open Studio"
      assert html =~ ~s(href="/agents/#{regressed_agent.id}?tab=instructions")
      assert html =~ "Tune drifting agent prompts"
    end

    test "applies recommended prompt patches from the radar", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Patchable Prompt Agent",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          instructions: "Do good work.",
          company_id: company.id
        })

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Patchable Prompt Agent"
      assert html =~ "Guided fixes"
      assert html =~ "Preview patches"

      html =
        view
        |> element("button[phx-value-agent-id='#{agent.id}']", "Preview patches")
        |> render_click()

      assert html =~ "Prompt Patch Preview"
      assert html =~ "Review the exact additive text"
      assert html =~ "Owner-readable memory"
      assert html =~ "After every meaningful action"
      assert html =~ "Next-run validation"
      assert html =~ "Run one focused issue for this agent"
      assert html =~ "required role tag"
      assert html =~ "Apply patches"

      html =
        view
        |> element("button[phx-value-agent-id='#{agent.id}']", "Apply patches")
        |> render_click()

      refute html =~ "Prompt Patch Preview"
      refute html =~ "Preview patches"
      assert html =~ "Prompt tuning receipt"
      assert html =~ "v1 rollback point recorded"
      assert html =~ "Runs should leave clearer owner-readable issue memory."
      assert html =~ "Next-run validation"
      assert html =~ "confirm the prompt canary records a newer validation run"
      assert html =~ "work product or PR"
      assert html =~ "Rollback:"

      {:ok, updated_agent} = Agents.get_agent(agent.id)
      assert updated_agent.instructions =~ "## Owner-readable memory"
      assert updated_agent.instructions =~ "## Delivery evidence"

      [revision] = Agents.list_config_revisions(agent.id)
      assert revision.created_by_user_id == user.id
      assert revision.source == "prompt_tuning"
      assert revision.studio_score > 50

      release = revision.studio_audits["tuning_release"]
      assert release["kind"] == "prompt_tuning_release"
      assert release["agent_name"] == "Patchable Prompt Agent"
      assert release["expected_effect"] =~ "owner-readable issue memory"
      assert Enum.any?(release["validation_checks"], &String.contains?(&1, "focused issue"))
      assert Enum.any?(release["validation_checks"], &String.contains?(&1, "required role tag"))
      assert Enum.any?(release["patches"], &(&1["title"] == "Owner-readable memory"))
    end

    test "previews bulk prompt patches before applying watchlist", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, first_agent} =
        Agents.create_agent(%{
          name: "Bulk Prompt Agent A",
          role: :engineer,
          status: :idle,
          adapter: :codex,
          instructions: "Do good work.",
          company_id: company.id
        })

      {:ok, second_agent} =
        Agents.create_agent(%{
          name: "Bulk Prompt Agent B",
          role: :cto,
          status: :idle,
          adapter: :claude_code,
          instructions: "Keep moving.",
          company_id: company.id
        })

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Preview all safe patches"

      html =
        view
        |> element("button[phx-value-scope='watchlist']", "Preview all safe patches")
        |> render_click()

      assert html =~ "Prompt Patch Preview"
      assert html =~ "Bulk Prompt Agent A"
      assert html =~ "Bulk Prompt Agent B"
      assert html =~ "Apply all patches"

      html =
        view
        |> element("button[phx-value-scope='watchlist']", "Apply all patches")
        |> render_click()

      assert html =~ "Prompt Drift Radar"
      assert html =~ "Prompt tuning receipt"
      assert html =~ "Bulk Prompt Agent A"
      assert html =~ "Bulk Prompt Agent B"
      assert html =~ "rollback point recorded"

      {:ok, updated_first} = Agents.get_agent(first_agent.id)
      {:ok, updated_second} = Agents.get_agent(second_agent.id)

      assert updated_first.instructions =~ "## Owner-readable memory"
      assert updated_second.instructions =~ "## Owner-readable memory"

      user_id = user.id

      [first_revision] = Agents.list_config_revisions(first_agent.id)
      assert first_revision.created_by_user_id == user_id
      assert first_revision.source == "prompt_tuning"
      assert first_revision.studio_audits["tuning_release"]["agent_name"] == "Bulk Prompt Agent A"

      [second_revision] = Agents.list_config_revisions(second_agent.id)
      assert second_revision.created_by_user_id == user_id
      assert second_revision.source == "prompt_tuning"

      assert second_revision.studio_audits["tuning_release"]["agent_name"] ==
               "Bulk Prompt Agent B"
    end

    test "renders review nudge queue and clears handled nudges", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Evidence Owner",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Needs owner-visible evidence",
          description: "Review evidence is missing.",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, _inbox} = Inbox.ensure_inbox_entry(issue.id, agent.id)

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, issue.id, "manual_dispatch", "system", "test", %{
          "source" => "review_nudge",
          "nudge_group_key" => "delivery:#{issue.id}:#{agent.id}",
          "blocker_keys" => ["delivery_comment"],
          "blocker_labels" => ["Delivery comment"],
          "summary" => "Ask for one tagged delivery note."
        })

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Review Nudges"
      assert html =~ "Active queue"
      assert html =~ "Needs owner-visible evidence"
      assert html =~ "Evidence Owner"
      assert html =~ "Delivery comment"
      assert html =~ "Mark handled"

      html =
        view
        |> element("button[phx-value-id='#{wake.id}']", "Mark handled")
        |> render_click()

      assert html =~ "Recently cleared"
      assert html =~ "Cleared"
      assert [] = Wakes.list_review_nudges([issue.id])
      assert [_cleared] = Wakes.list_review_nudges([issue.id], statuses: ["consumed"])
    end

    test "renders and clears stale comment wake backlog", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Backlog Owner",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Old comment wake",
          description: "Comment wake is stale.",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, issue.id, "issue_commented", "user", "test", %{})

      stale_time =
        DateTime.utc_now()
        |> DateTime.add(-3 * 60 * 60, :second)
        |> DateTime.truncate(:second)

      Repo.update_all(from(w in AgentWake, where: w.id == ^wake.id),
        set: [inserted_at: stale_time]
      )

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Wake Backlog"
      assert html =~ "Old comment wake"
      assert html =~ "Backlog Owner"
      assert html =~ "Clear stale wakes"

      html =
        view
        |> element("button", "Clear stale wakes")
        |> render_click()

      assert html =~ "Cleared 1 stale comment wake."
      assert html =~ "No stale comment wakes are holding queue slots."
      assert Wakes.get_agent_wake!(wake.id).status == "consumed"
    end

    test "renders launch action for pre-runtime review nudges", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "CEO Waiting To Run",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Needs first CEO run",
          status: :todo,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, _wake} =
        Wakes.do_wake_agent(agent.id, issue.id, "manual_dispatch", "system", "test", %{
          "source" => "review_nudge",
          "nudge_group_key" => "delivery:#{issue.id}:#{agent.id}",
          "blocker_keys" => ["runtime_verification", "agent_note", "work_product"],
          "blocker_labels" => [
            "Runtime verification",
            "Agent completion note",
            "Work product"
          ],
          "summary" => "Ask for one tagged delivery note."
        })

      {:ok, _view, html} = live(conn, "/operations")

      assert html =~ "Runtime launch is queued"
      assert html =~ "Runtime has not produced evidence yet"
      assert html =~ "Open launch checklist"
      assert html =~ ~s(href="/operations#runtime-launch-checklist")
      refute html =~ "Ask for one tagged delivery note."
    end

    test "renders prompt contract failures by agent", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Contract QA Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Thin contract delivery",
          description: "A delivery note exists but lacks the required fields.",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          issue_id: issue.id,
          author_type: "agent",
          author_id: agent.id,
          body: "[delivery] Done."
        })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Contract evidence",
          description: "Evidence exists but the comment is too thin."
        })

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Prompt Contract Health"
      assert html =~ "Contract and memory failures by agent"
      assert html =~ "Repair queue"
      assert html =~ "Start here"
      assert html =~ "Top repairs"
      assert html =~ "max-h-[520px]"
      assert html =~ "Active gaps"
      assert html =~ "Thin contract delivery"
      assert html =~ "Contract QA Agent"
      assert html =~ "Delivery evidence"
      assert html =~ "Verification"
      assert html =~ "Queue nudge"
      assert html =~ "Nudge agent"
      assert html =~ "Open issue"
      assert html =~ "Open agent"
      assert html =~ "Repair prompt contract gaps"

      html =
        view
        |> element("button[phx-value-contract='delivery_contract']", "Nudge agent")
        |> render_click()

      assert html =~ "Queued"

      assert [wake] = Wakes.list_review_nudges([issue.id])
      assert wake.metadata["contract_key"] == "delivery_contract"
      assert "contract_delivery_contract" in wake.metadata["blocker_keys"]
    end

    test "queues PR quality nudges from contract health", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "PR Quality Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Bad PR in operations",
          description: "The PR needs contract repair.",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id,
          github_pr_url: "https://github.com/acme/app/pull/42",
          monitor_state: %{
            "pr_quality" => %{
              "status" => "attention",
              "summary" => "1 PR contract gap needs fixes.",
              "gaps" => [
                %{"label" => "Task List checkboxes", "detail" => "Task List needs checkboxes."}
              ]
            }
          }
        })

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "PR quality gate"
      assert html =~ "Task List checkboxes"
      assert html =~ "Fix PR quality"

      html =
        view
        |> element("button[phx-value-contract='pr_quality']", "Fix PR quality")
        |> render_click()

      assert html =~ "Queued"

      assert [wake] = Wakes.list_review_nudges([issue.id])
      assert wake.metadata["contract_key"] == "pr_quality"
      assert "pr_quality" in wake.metadata["blocker_keys"]
    end

    test "queues memory health nudges from contract health", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Memory Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"},
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Noisy memory in operations",
          description: "Owner request is clear.",
          status: :in_progress,
          priority: :high,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Evidence bundle",
          description: "Work exists but needs a readable summary."
        })

      for body <- ["Routine heartbeat", "Routine adapter poll", "Routine dispatch check"] do
        {:ok, _comment} =
          Comments.create_comment(%{
            issue_id: issue.id,
            author_type: "system",
            author_id: "runtime",
            body: body
          })
      end

      {:ok, view, html} = live(conn, "/operations")

      assert html =~ "Memory health"
      assert html =~ "Owner-ready summary"
      assert html =~ "Routine noise"
      assert html =~ "Request summary"

      html =
        view
        |> element("button[phx-value-contract='memory_summary']", "Request summary")
        |> render_click()

      assert html =~ "Queued"

      assert [wake] = Wakes.list_review_nudges([issue.id])
      assert wake.metadata["contract_key"] == "memory_summary"
      assert "memory_summary" in wake.metadata["blocker_keys"]
    end

    test "refreshes the console snapshot", %{conn: conn} do
      {conn, user, company} = ConnCase.register_and_log_in_user(conn)
      conn = live_session_conn(conn, user, company)

      {:ok, view, _html} = live(conn, "/operations")

      assert view
             |> element("button", "Refresh")
             |> render_click() =~ "Runtime Services"
    end
  end

  defp live_session_conn(conn, user, company) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_id", user.id)
    |> Plug.Conn.put_session("company_id", company.id)
  end

  defp owner_signoff_block_reason do
    """
    Cause: CEO is handing this back for owner verification.
    Attempted fix: inspected the CEO owner update and confirmed no agent work remains.
    Needs: owner must verify the CEO owner update before closure.
    Current state: no agent work remains; issue is waiting on owner acceptance or revision.
    Next decision: owner accepts the update or reopens it for revision.
    Restart packet: open the CEO owner update, inspect evidence, then accept or request revision.
    """
    |> String.trim()
  end

  defp unique_prefix(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.digits()
      |> Enum.map_join(fn digit -> <<?A + digit>> end)
      |> String.slice(0, 10 - String.length(prefix))

    prefix <> suffix
  end

  defp company_issues(company_id), do: Issues.list_issues(%{company_id: company_id})
end
