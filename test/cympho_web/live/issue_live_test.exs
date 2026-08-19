defmodule CymphoWeb.IssueLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Issues
  alias Cympho.Comments
  alias Cympho.Agents
  alias Cympho.AuditTrail
  alias Cympho.Companies
  alias Cympho.Documents
  alias Cympho.Goals
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Inbox
  alias Cympho.Proxies
  alias Cympho.Issues.SwarmEvents
  alias Cympho.Projects
  alias Cympho.Repo
  alias Cympho.Users
  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake
  alias Cympho.WorkProducts
  alias Cympho.Workspaces

  defp create_agent(attrs), do: Agents.create_agent(scoped_attrs(attrs))
  defp create_goal(attrs), do: Goals.create_goal(scoped_attrs(attrs))
  defp create_issue(attrs), do: Issues.create_issue(scoped_attrs(attrs))
  defp create_project(attrs), do: Projects.create_project(scoped_attrs(attrs))

  defp textarea_value(html, selector) do
    html
    |> Floki.parse_document!()
    |> Floki.find(selector)
    |> Floki.text()
  end

  defp element_attrs(html, selector) do
    html
    |> Floki.parse_document!()
    |> Floki.find(selector)
    |> case do
      [{_tag, attrs, _children} | _rest] -> Map.new(attrs)
      [] -> %{}
    end
  end

  defp unique_project_prefix do
    suffix =
      System.unique_integer([:positive])
      |> Integer.digits(26)
      |> Enum.map_join(fn digit -> <<?A + digit>> end)
      |> String.slice(0, 8)

    "Q" <> suffix
  end

  setup do
    {:ok, issue} =
      create_issue(%{
        title: "Test Issue",
        description: "Test description for the issue",
        status: :backlog,
        priority: :high
      })

    %{issue: issue}
  end

  describe "Index - Issue List" do
    test "renders all issues", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues?density=detailed")

      assert html =~ "All Issues"
      assert html =~ issue.title
    end

    test "shows mission context on issue rows" do
      {:ok, mission} =
        create_goal(%{
          title: "Raise activation quality",
          goal_type: :mission
        })

      {:ok, _issue} =
        create_issue(%{
          title: "Aligned list row",
          description: "Owner needs this tied to the activation mission.",
          status: :todo,
          priority: :high,
          goal_id: mission.id
        })

      {:ok, _view, html} = live(conn(), "/issues?density=detailed")

      assert html =~ "Aligned list row"
      assert html =~ "Mission: Raise activation quality"
    end

    test "shows issue status badges", %{issue: _issue} do
      {:ok, _view, html} = live(conn(), "/issues?density=detailed")

      assert html =~ "backlog"
      assert html =~ "high"
    end

    test "shows comment count", %{issue: _issue} do
      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "0 comments"
    end

    test "shows compact owner-flow digest on CEO-owned rows" do
      {:ok, ceo} =
        create_agent(%{
          name: "List CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, _issue} =
        create_issue(%{
          title: "List owner request",
          description: "CEO should produce the first owner signal.",
          status: :todo,
          priority: :high,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "List owner request"
      assert html =~ "List CEO"
      refute html =~ "Assigned, but runtime has not started yet."
    end

    test "shows launch readiness on dispatchable rows" do
      {:ok, _agent} =
        create_agent(%{
          name: "List Launch Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom", "repo_capable" => true}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Implement list row code path",
          description: """
          Acceptance criteria: the list row shows the runtime state.
          Evidence required: issue page link and visible target agent.
          Verification required: render the issue list.
          Definition of done: the row is complete.
          """,
          status: :todo,
          priority: :high,
          assigned_role: "engineer"
        })

      {:ok, _view, html} = live(conn(), "/issues?density=detailed")

      assert html =~ "Launch"
      assert html =~ "Implement list row code path"
      assert html =~ "List Launch Engineer"
      assert html =~ ~s(href="/issues/#{issue.id}#issue-agent-panel")

      launch_text =
        html
        |> Floki.parse_document!()
        |> Floki.find("a[href='/issues/#{issue.id}#issue-agent-panel']")
        |> Floki.text()

      assert launch_text =~ "List Launch Engineer"
      assert launch_text =~ ~r/(Ready|Review mode|Needs setup|Blocked|No agent)/
    end

    test "shows an attention queue with concrete next actions", %{current_company: company} do
      {:ok, ceo} =
        create_agent(%{
          name: "Queue CEO",
          role: :ceo,
          status: :idle,
          company_id: company.id
        })

      {:ok, _ceo_issue} =
        create_issue(%{
          title: "Queue CEO launch",
          description: "CEO should provide owner signal.",
          status: :todo,
          priority: :high,
          assignee_id: ceo.id,
          assigned_role: "ceo",
          company_id: company.id
        })

      {:ok, _blocked_issue} =
        create_issue(%{
          title: "Queue blocked release",
          description: "Needs owner intervention before agents continue.",
          status: :blocked,
          priority: :critical,
          company_id: company.id
        })

      {:ok, _unassigned_issue} =
        create_issue(%{
          title: "Queue missing owner",
          description: "Needs someone to own the next move.",
          status: :todo,
          priority: :medium,
          company_id: company.id
        })

      {:ok, _view, html} = live(conn(), "/issues?density=detailed")

      assert html =~ "Attention queue"
      assert html =~ "First concrete moves from the issues currently in view."
      assert html =~ "Queue blocked release"
      assert html =~ "Unblock"
      assert html =~ "Queue CEO launch"
      assert html =~ "Launch CEO"
      assert html =~ "Queue missing owner"
      assert html =~ "Assign owner"
      assert html =~ "Open"
    end

    test "shows owner triage lanes and filters the CEO lane", %{current_company: company} do
      {:ok, _ceo_issue} =
        create_issue(%{
          title: "CEO triage lane request",
          description: "Owner work should stay easy to find.",
          status: :todo,
          priority: :high,
          assigned_role: "ceo",
          company_id: company.id
        })

      {:ok, _engineer_issue} =
        create_issue(%{
          title: "Engineer triage lane request",
          description: "Implementation work should not appear in the CEO lane.",
          status: :todo,
          priority: :medium,
          assigned_role: "engineer",
          company_id: company.id
        })

      {:ok, view, html} = live(conn(), "/issues?density=detailed")

      assert html =~ "3 issues"
      assert html =~ "Jump straight to the queue that needs you next."
      assert html =~ "CEO lane"
      assert html =~ "Ready"
      assert html =~ "Blocked"
      assert html =~ "Unassigned"

      view
      |> element("[data-testid='issue-triage-lane-ceo']", "CEO lane")
      |> render_click()

      patch_uri = assert_patch(view) |> URI.parse()
      assert patch_uri.path == "/issues"

      assert URI.decode_query(patch_uri.query || "") == %{
               "density" => "detailed",
               "triage" => "ceo"
             }

      html = render(view)
      assert html =~ "CEO triage lane request"
      refute html =~ "Engineer triage lane request"
      assert html =~ "Show all issues"
    end
  end

  describe "New - Owner request routing" do
    test "renders a live-updating document title on first load" do
      html =
        conn()
        |> get("/issues/new")
        |> html_response(200)

      assert html =~ ~s(<title data-suffix=" · Cympho">New Issue · Cympho</title>)
    end

    test "creates authenticated company issues as CEO-owned todo work" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Owner Route Co",
          slug: "owner-route-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        create_project(%{
          name: "Operating Project",
          prefix: "OR",
          company_id: company.id
        })

      {:ok, launch_project} =
        create_project(%{
          name: "Launch Project",
          prefix: "LP",
          company_id: company.id
        })

      {:ok, mission} =
        create_goal(%{
          title: "Launch Mission",
          goal_type: :mission,
          status: "active",
          company_id: company.id,
          project_id: launch_project.id
        })

      {:ok, user} =
        Users.create_user(%{
          email: "owner-route-#{System.unique_integer([:positive])}@example.com",
          name: "Owner"
        })

      {:ok, _membership} =
        Companies.create_membership(%{
          user_id: user.id,
          company_id: company.id,
          role: "owner",
          is_board_member: true
        })

      {:ok, ceo} =
        create_agent(%{
          name: "CEO",
          role: :ceo,
          status: :idle,
          company_id: company.id,
          project_id: project.id
        })

      conn =
        conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)

      {:ok, view, html} = live(conn, "/issues/new")

      assert html =~ "New issue"
      assert html =~ "What should the team do?"
      assert html =~ ~s(placeholder="What outcome do you want?")
      assert html =~ "Options"
      assert html =~ "Use a structured template"
      assert html =~ "Too thin for autonomy"
      assert html =~ "0/6"
      assert html =~ "Outcome: Name the owner-visible result"
      assert html =~ "Add enough detail to make the brief ready."
      assert html =~ "Create issue"
      queue_attrs = element_attrs(html, "input#queue-dispatch-focus")
      assert Map.has_key?(queue_attrs, "disabled")
      refute Map.has_key?(queue_attrs, "checked")
      assert html =~ "Project"
      assert html =~ "Operating Project"
      assert html =~ "Launch Project"
      assert html =~ "Mission: Launch Mission"
      refute html =~ "Owner intake"
      refute html =~ "Routing lock"
      refute html =~ "Before you launch"

      html =
        view
        |> element("button[phx-click='use_launch_scaffold']")
        |> render_click()

      assert textarea_value(html, "textarea[name='issue[description]']") =~
               "Goal: &lt;the business outcome the owner wants&gt;"

      launch_ready_description = """
      Goal: improve onboarding conversion.
      Context: activation drops after workspace setup.
      Constraints / risks: must not slow first workspace creation.
      Definition of done: CEO has split the work or produced a decision.
      CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`): start with a handoff if execution is needed.
      Evidence to inspect after the run: scoped sub-issues and acceptance criteria.
      """

      html =
        view
        |> form("form", %{
          "queue_dispatch_focus" => "false",
          "issue" => %{
            "title" => "Owner asks for onboarding",
            "description" => launch_ready_description,
            "project_id" => launch_project.id
          }
        })
        |> render_change()

      assert html =~ "Ready for CEO launch"
      assert html =~ "6/6"
      assert html =~ "Queue after creating"
      assert html =~ "Create &amp; queue"
      queue_attrs = element_attrs(html, "input#queue-dispatch-focus")
      assert Map.has_key?(queue_attrs, "checked")
      refute Map.has_key?(queue_attrs, "disabled")

      result =
        view
        |> form("form", %{
          "queue_dispatch_focus" => "true",
          "issue" => %{
            "title" => "Owner asks for onboarding",
            "description" => launch_ready_description,
            "project_id" => launch_project.id
          }
        })
        |> render_submit()

      [created] = Issues.list_issues(%{company_id: company.id})
      assert created.title == "Owner asks for onboarding"
      assert created.status == :todo
      assert created.assignee_id == ceo.id
      assert created.assigned_role == "ceo"
      assert created.project_id == launch_project.id
      assert created.goal_id == mission.id
      assert created.lineage["goal_id"] == mission.id
      assert created.lineage["mission_id"] == mission.id
      assert created.created_by_user_id == user.id
      assert Issues.dispatch_pinned?(created)

      expected_path = "/issues/#{created.id}#issue-ceo-flow-checklist"
      assert {:error, {:live_redirect, %{to: ^expected_path}}} = result
    end

    test "does not queue focused dispatch for thin owner briefs" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Owner Route Thin Brief Co",
          slug: "owner-route-thin-#{System.unique_integer([:positive])}"
        })

      {:ok, user} =
        Users.create_user(%{
          email: "owner-route-thin-#{System.unique_integer([:positive])}@example.com",
          name: "Owner"
        })

      {:ok, _membership} =
        Companies.create_membership(%{
          user_id: user.id,
          company_id: company.id,
          role: "owner",
          is_board_member: true
        })

      {:ok, ceo} =
        create_agent(%{
          name: "Thin Intake CEO",
          role: :ceo,
          status: :idle,
          company_id: company.id
        })

      conn =
        conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)

      {:ok, view, html} = live(conn, "/issues/new")

      assert html =~ "Too thin for autonomy"
      assert html =~ "Add enough detail to make the brief ready."
      assert html =~ "Create issue"
      queue_attrs = element_attrs(html, "input#queue-dispatch-focus")
      assert Map.has_key?(queue_attrs, "disabled")
      refute Map.has_key?(queue_attrs, "checked")

      result =
        view
        |> form("form", %{
          "queue_dispatch_focus" => "false",
          "issue" => %{
            "title" => "Thin",
            "description" => "Do it."
          }
        })
        |> render_submit()

      [created] = Issues.list_issues(%{company_id: company.id})
      assert created.assignee_id == ceo.id
      assert created.assigned_role == "ceo"
      refute Issues.dispatch_pinned?(created)

      expected_path = "/issues/#{created.id}"
      assert {:error, {:live_redirect, %{to: ^expected_path}}} = result
    end

    test "ignores forged tenant and assignment fields" do
      company_id = current_company_id()

      {:ok, ceo} =
        create_agent(%{
          name: "Scoped Intake CEO",
          role: :ceo,
          status: :idle,
          company_id: company_id
        })

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Foreign Issue Company",
          slug: "foreign-issue-#{System.unique_integer([:positive])}"
        })

      {:ok, foreign_agent} =
        Agents.create_agent(%{
          name: "Foreign Engineer",
          role: :engineer,
          status: :idle,
          company_id: other_company.id
        })

      {:ok, view, _html} = live(conn(), "/issues/new")

      render_submit(view, "save", %{
        "issue" => %{
          "title" => "Tenant-scoped owner request",
          "description" => "Keep this request in the selected company and CEO lane.",
          "company_id" => other_company.id,
          "assignee_id" => foreign_agent.id,
          "assigned_role" => "engineer"
        }
      })

      created =
        Issues.list_issues(%{company_id: company_id})
        |> Enum.find(&(&1.title == "Tenant-scoped owner request"))

      assert created
      assert created.company_id == company_id
      assert created.assignee_id == ceo.id
      assert created.assigned_role == "ceo"

      refute Enum.any?(
               Issues.list_issues(%{company_id: other_company.id}),
               &(&1.title == "Tenant-scoped owner request")
             )
    end

    test "does not queue focused dispatch for almost-ready owner briefs" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Owner Route Almost Ready Co",
          slug: "owner-route-almost-ready-#{System.unique_integer([:positive])}"
        })

      {:ok, user} =
        Users.create_user(%{
          email: "owner-route-almost-ready-#{System.unique_integer([:positive])}@example.com",
          name: "Owner"
        })

      {:ok, _membership} =
        Companies.create_membership(%{
          user_id: user.id,
          company_id: company.id,
          role: "owner",
          is_board_member: true
        })

      {:ok, ceo} =
        create_agent(%{
          name: "Almost Ready CEO",
          role: :ceo,
          status: :idle,
          company_id: company.id
        })

      conn =
        conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)

      {:ok, view, _html} = live(conn, "/issues/new")

      almost_ready_description = """
      Goal: improve onboarding conversion.
      Context: activation drops after workspace setup.
      Constraints / risks: must not slow first workspace creation.
      Definition of done: CEO has split the work or produced a decision.
      CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`): start with a handoff if execution is needed.
      """

      html =
        view
        |> form("form", %{
          "queue_dispatch_focus" => "false",
          "issue" => %{
            "title" => "Owner asks for almost-ready onboarding",
            "description" => almost_ready_description
          }
        })
        |> render_change()

      assert html =~ "Needs one more pass"
      assert html =~ "5/6"
      assert html =~ "Evidence: Specify what proof should be inspected after the run."
      assert html =~ "Add enough detail to make the brief ready."
      assert html =~ "Create issue"

      result =
        view
        |> form("form", %{
          "queue_dispatch_focus" => "false",
          "issue" => %{
            "title" => "Owner asks for almost-ready onboarding",
            "description" => almost_ready_description
          }
        })
        |> render_submit()

      [created] = Issues.list_issues(%{company_id: company.id})
      assert created.assignee_id == ceo.id
      assert created.assigned_role == "ceo"
      refute Issues.dispatch_pinned?(created)

      expected_path = "/issues/#{created.id}"
      assert {:error, {:live_redirect, %{to: ^expected_path}}} = result
    end

    test "keeps owner-created issues in CEO lane when no CEO agent exists" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Owner Route No CEO Co",
          slug: "owner-route-no-ceo-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        create_project(%{
          name: "No CEO Project",
          prefix: "NC",
          company_id: company.id
        })

      {:ok, user} =
        Users.create_user(%{
          email: "owner-route-no-ceo-#{System.unique_integer([:positive])}@example.com",
          name: "Owner"
        })

      {:ok, _membership} =
        Companies.create_membership(%{
          user_id: user.id,
          company_id: company.id,
          role: "owner",
          is_board_member: true
        })

      conn =
        conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)

      {:ok, view, html} = live(conn, "/issues/new")

      assert html =~ "Add a CEO agent before this issue can run."
      assert html =~ "Add CEO agent"
      assert html =~ ~s(href="/agents/new")
      refute html =~ ~s(id="queue-dispatch-focus")
      assert html =~ "Create issue"

      result =
        view
        |> form("form", %{
          "issue" => %{
            "title" => "Owner asks without CEO",
            "description" => "CEO should still own this request.",
            "project_id" => project.id
          }
        })
        |> render_submit()

      [created] = Issues.list_issues(%{company_id: company.id})
      assert created.title == "Owner asks without CEO"
      assert created.status == :todo
      assert is_nil(created.assignee_id)
      assert created.assigned_role == "ceo"
      assert created.project_id == project.id
      assert created.created_by_user_id == user.id
      refute Issues.dispatch_pinned?(created)

      expected_path = "/issues/#{created.id}"
      assert {:error, {:live_redirect, %{to: ^expected_path}}} = result
    end

    test "can create a CEO issue without queueing focused dispatch" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Owner Route Manual Launch Co",
          slug: "owner-route-manual-#{System.unique_integer([:positive])}"
        })

      {:ok, user} =
        Users.create_user(%{
          email: "owner-route-manual-#{System.unique_integer([:positive])}@example.com",
          name: "Owner"
        })

      {:ok, _membership} =
        Companies.create_membership(%{
          user_id: user.id,
          company_id: company.id,
          role: "owner",
          is_board_member: true
        })

      {:ok, ceo} =
        create_agent(%{
          name: "Manual Launch CEO",
          role: :ceo,
          status: :idle,
          company_id: company.id
        })

      conn =
        conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)

      {:ok, view, html} = live(conn, "/issues/new")

      assert html =~ "Add enough detail to make the brief ready."
      assert html =~ "Create issue"

      result =
        view
        |> form("form", %{
          "queue_dispatch_focus" => "false",
          "issue" => %{
            "title" => "Owner asks for manual launch",
            "description" => "CEO should wait for manual focus."
          }
        })
        |> render_submit()

      [created] = Issues.list_issues(%{company_id: company.id})
      assert created.assignee_id == ceo.id
      assert created.assigned_role == "ceo"
      refute Issues.dispatch_pinned?(created)

      expected_path = "/issues/#{created.id}"
      assert {:error, {:live_redirect, %{to: ^expected_path}}} = result
    end

    test "can create a swarm issue with temporary workers routed through CTO" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Owner Route Swarm Co",
          slug: "owner-route-swarm-#{System.unique_integer([:positive])}"
        })

      {:ok, user} =
        Users.create_user(%{
          email: "owner-route-swarm-#{System.unique_integer([:positive])}@example.com",
          name: "Owner"
        })

      {:ok, _membership} =
        Companies.create_membership(%{
          user_id: user.id,
          company_id: company.id,
          role: "owner",
          is_board_member: true
        })

      {:ok, ceo} =
        create_agent(%{
          name: "Swarm Intake CEO",
          role: :ceo,
          status: :idle,
          company_id: company.id
        })

      {:ok, cto} =
        create_agent(%{
          name: "Swarm Intake CTO",
          role: :cto,
          status: :idle,
          company_id: company.id
        })

      {:ok, proxy_a} =
        Proxies.create_proxy_profile(%{
          company_id: company.id,
          name: "swarm-egress-a",
          proxy_type: "socks5",
          host: "127.0.0.1",
          port: 10_801
        })

      {:ok, proxy_b} =
        Proxies.create_proxy_profile(%{
          company_id: company.id,
          name: "swarm-egress-b",
          proxy_type: "http",
          host: "127.0.0.1",
          port: 10_802
        })

      conn =
        conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)

      {:ok, view, html} = live(conn, "/issues/new")

      assert html =~ "Use swarm"
      assert html =~ "3 workers"
      assert has_element?(view, "[data-testid='issue-swarm-controls'].ui-advanced-only")
      refute html =~ ~s(data-testid="issue-swarm-advanced-panel")

      ready_description = """
      Goal: choose the strongest launch segment.
      Context: three candidate markets need comparison.
      Constraints / risks: do not start engineering before CTO synthesis.
      Definition of done: CEO has a CTO-reviewed recommendation.
      CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`): use swarm synthesis before final owner update.
      Evidence to inspect after the run: worker packets and CTO synthesis.
      """

      swarm_params = %{
        "enabled" => "true",
        "agent_count" => "2",
        "mix_rows" => %{
          "0" => %{
            "enabled" => "true",
            "harness" => "claude_code",
            "model" => "sonnet",
            "reasoning_effort" => "medium"
          }
        },
        "proxy_mode" => "selected",
        "proxy_profile_ids" => [proxy_a.id, proxy_b.id]
      }

      view
      |> form("form", %{
        "queue_dispatch_focus" => "false",
        "swarm" => %{"enabled" => "true"},
        "issue" => %{
          "title" => "Owner asks for launch segment swarm",
          "description" => ready_description
        }
      })
      |> render_change()

      html =
        view
        |> form("form", %{
          "swarm" => swarm_params,
          "issue" => %{
            "title" => "Owner asks for launch segment swarm",
            "description" => ready_description
          }
        })
        |> render_change()

      assert html =~ "Create swarm"
      assert html =~ ~s(data-testid="issue-swarm-advanced-panel")
      assert html =~ "Swarm setup"
      assert html =~ "swarm-egress-a"
      assert html =~ "swarm-egress-b"
      assert html =~ "2 proxy profiles"
      assert html =~ "Claude code"
      assert html =~ "sonnet"
      assert html =~ "Medium"
      assert html =~ ~s(data-swarm-count)
      assert html =~ "runtime choice"

      result =
        view
        |> form("form", %{
          "swarm" => swarm_params,
          "issue" => %{
            "title" => "Owner asks for launch segment swarm",
            "description" => ready_description
          }
        })
        |> render_submit()

      parent =
        Issues.list_issues(%{company_id: company.id})
        |> Enum.find(&(&1.title == "Owner asks for launch segment swarm"))

      assert parent.status == :blocked
      assert parent.assignee_id == ceo.id
      assert parent.assigned_role == "ceo"
      refute Issues.dispatch_pinned?(parent)
      assert parent.monitor_state["swarm"]["status"] == "launched"
      assert length(parent.monitor_state["swarm"]["temporary_agent_ids"]) == 2
      assert parent.monitor_state["swarm"]["proxy"]["mode"] == "selected"

      assert parent.monitor_state["swarm"]["proxy"]["pool"] == [
               "swarm-egress-a",
               "swarm-egress-b"
             ]

      reasoning_efforts = Enum.map(parent.monitor_state["swarm"]["mix"], & &1["reasoning_effort"])
      assert length(reasoning_efforts) == 2
      assert Enum.all?(reasoning_efforts, &(&1 in ["medium", "high"]))

      children = Issues.list_child_issues(parent.id)
      assert Enum.count(children, &(&1.origin_type == "swarm_worker")) == 2

      assert Enum.any?(
               children,
               &(&1.origin_type == "swarm_cto_review" and &1.assignee_id == cto.id)
             )

      expected_path = "/issues/#{parent.id}"
      assert {:error, {:live_redirect, %{to: ^expected_path}}} = result
    end
  end

  describe "Show - Issue Detail" do
    test "renders a live-updating document title on first load", %{issue: issue} do
      html =
        conn()
        |> get("/issues/#{issue.id}")
        |> html_response(200)

      assert html =~ ~s(<title data-suffix=" · Cympho">#{issue.title} · Cympho</title>)
    end

    test "renders issue detail", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ issue.title
      assert html =~ issue.description
      assert html =~ "backlog"
      assert html =~ "high"
    end

    test "rejects a forged cross-company revision diff event", %{issue: issue} do
      {:ok, document} =
        Documents.create_document(%{
          key: "tenant-plan",
          title: "Tenant Plan",
          body: "tenant version one",
          issue_id: issue.id
        })

      {:ok, document} = Documents.update_document(document, %{body: "tenant version two"})
      {:ok, _document} = Documents.update_document(document, %{body: "tenant version three"})

      unique = System.unique_integer([:positive])

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Foreign Revision #{unique}",
          slug: "foreign-revision-#{unique}"
        })

      {:ok, other_issue} =
        Issues.create_issue(%{
          title: "Foreign revision issue",
          company_id: other_company.id
        })

      {:ok, other_document} =
        Documents.create_document(%{
          key: "foreign-plan",
          title: "Foreign Plan",
          body: "FOREIGN REVISION BODY #{unique}",
          issue_id: other_issue.id
        })

      {:ok, other_document} =
        Documents.update_document(other_document, %{body: "foreign version two"})

      [foreign_revision] = Documents.list_revisions(other_document.id)
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      render_hook(view, "show_document_revisions", %{"document_key" => "tenant-plan"})

      html =
        render_hook(view, "show_revision_diff", %{"revision_id" => foreign_revision.id})

      assert html =~ "Revision not found"
      refute html =~ "FOREIGN REVISION BODY #{unique}"
    end

    test "a run_status broadcast updates the view without crashing it", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      # Regression: broadcast_run_status delivers a
      # %Phoenix.Socket.Broadcast{event: "run_status"} struct. The view used to
      # have only a {:run_status_changed, _} tuple clause and no catch-all, so
      # every run start/fail terminated the LiveView on prod.
      payload = %{
        event_type: :run_completed,
        resource_id: Ecto.UUID.generate(),
        issue_id: issue.id,
        agent_id: Ecto.UUID.generate(),
        status: "completed",
        adapter: "claude_code",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      CymphoWeb.Endpoint.broadcast("company:#{current_company_id()}:runs", "run_status", payload)

      assert_push_event(view, "toast", %{message: "Run completed successfully"})
      # View is still alive and rendering.
      assert render(view) =~ issue.title
    end

    test "renders swarm issues as an orchestration surface" do
      {:ok, ceo} =
        create_agent(%{
          name: "Detail Swarm CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, _cto} =
        create_agent(%{
          name: "Detail Swarm CTO",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, parent} =
        create_issue(%{
          title: "Design a launch swarm",
          description: """
          Goal: compare two launch paths.
          Context: owner needs a CTO-reviewed recommendation.
          Constraints / risks: no engineering before synthesis.
          Definition of done: CEO receives a CTO-ready recommendation.
          CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`): wait for CTO synthesis.
          Evidence to inspect after the run: worker packets and CTO gate.
          """,
          status: :todo,
          priority: :medium,
          assignee_id: ceo.id,
          assigned_role: "ceo",
          swarm: %{
            enabled: true,
            agent_count: 2,
            mix: [
              %{adapter: :claude_code, model: "sonnet"}
            ],
            proxy: %{enabled: true, profile: "managed-egress-ui"}
          }
        })

      {:ok, _view, html} = live(conn(), "/issues/#{parent.id}")

      assert html =~ ~s(data-testid="issue-swarm-panel")
      assert html =~ ~s(data-testid="issue-swarm-log")
      assert html =~ "Swarm"
      assert html =~ "Live swarm log"
      assert html =~ "Open queue"
      assert html =~ ~s(href="/operations?parent_issue_id=#{parent.id}#delegated-work-queue")
      assert html =~ "Launch ready"
      assert html =~ "CTO issue created"
      refute html =~ "Cto issue created"
      assert html =~ "Swarm is queued"
      assert html =~ "Workers queued"
      assert html =~ "Independent first pass"
      assert html =~ "Evidence over consensus"
      assert html =~ "Preserve dissent"
      assert html =~ "Workers"
      assert html =~ "0/2 finished"
      assert html_has_any?(html, worker_role_labels())
      assert html_has_any?(html, worker_lens_labels())
      assert html =~ "claude_code"
      assert html =~ "sonnet"
      assert html =~ "managed-egress-ui"
      assert html =~ "CTO review"
      assert html =~ "Back to CEO"
      assert html =~ "Owner brief"

      children = Issues.list_child_issues(parent.id)

      worker =
        children
        |> Enum.filter(&(&1.origin_type == "swarm_worker"))
        |> Enum.sort_by(&(&1.monitor_state["swarm"]["worker_index"] || 999))
        |> hd()

      cto_issue = Enum.find(children, &(&1.origin_type == "swarm_cto_review"))

      {:ok, _view, worker_html} = live(conn(), "/issues/#{worker.id}")

      assert worker_html =~ ~s(data-testid="issue-swarm-panel")
      assert worker_html =~ "Swarm worker"
      assert worker_html =~ "goes to your CTO for review"

      assert worker_html =~
               ~s(href="/operations?parent_issue_id=#{parent.id}#delegated-work-queue")

      assert html_has_any?(worker_html, worker_lens_labels())
      assert worker_html =~ "claude_code"

      {:ok, _view, cto_html} = live(conn(), "/issues/#{cto_issue.id}")

      assert cto_html =~ ~s(data-testid="issue-swarm-panel")
      assert cto_html =~ "CTO review"
      assert cto_html =~ ~s(href="/operations?parent_issue_id=#{parent.id}#delegated-work-queue")
      assert cto_html =~ "Waiting on workers"
      assert cto_html =~ "Back to CEO"
      assert cto_html =~ "Workers"
    end

    test "refreshes the swarm panel when a worker event arrives" do
      {:ok, ceo} =
        create_agent(%{
          name: "Live Swarm CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, _cto} =
        create_agent(%{
          name: "Live Swarm CTO",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, parent} =
        create_issue(%{
          title: "Watch worker completion live",
          description: """
          Goal: prove the swarm panel updates live.
          Context: one worker should close before CTO synthesis.
          Constraints / risks: keep CEO blocked until synthesis.
          Definition of done: the parent panel shows the closed worker.
          CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`): wait for CTO.
          Evidence to inspect after the run: live swarm log and worker count.
          """,
          status: :todo,
          priority: :medium,
          assignee_id: ceo.id,
          assigned_role: "ceo",
          swarm: %{
            enabled: true,
            agent_count: 1,
            mix: [%{adapter: :codex, model: "gpt-5.4-mini", reasoning_effort: "medium"}]
          }
        })

      {:ok, view, html} = live(conn(), "/issues/#{parent.id}")

      assert html =~ "0/1 finished"

      worker =
        parent.id
        |> Issues.list_child_issues()
        |> Enum.find(&(&1.origin_type == "swarm_worker"))

      assert worker

      worker
      |> Ecto.Changeset.change(status: :done)
      |> Repo.update!()

      :ok =
        SwarmEvents.record(worker, %{
          event_type: "worker_completed",
          status: "success",
          message: "Worker packet closed.",
          metadata: %{worker_index: 1}
        })

      # Poll until the swarm event broadcast has reached the LiveView.
      wait_until(fn -> assert render(view) =~ "1/1 finished" end)

      html = render(view)
      assert html =~ "1/1 finished"
      assert html =~ "Worker completed"
      assert html =~ "Worker packet closed."
    end

    test "shows linked mission context in the sidebar" do
      {:ok, project} =
        create_project(%{
          name: "Sidebar Mission Project",
          prefix: "SMP"
        })

      {:ok, mission} =
        create_goal(%{
          title: "Sidebar Mission",
          goal_type: :mission,
          status: "active",
          project_id: project.id
        })

      {:ok, issue} =
        create_issue(%{
          title: "Mission-backed issue",
          description: "Needs mission context on the issue page.",
          status: :todo,
          priority: :high,
          project_id: project.id,
          goal_id: mission.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ ~s(data-testid="issue-mission-context")
      assert html =~ "Sidebar Mission"
      assert html =~ "Mission context is attached to this issue inside Sidebar Mission Project"
      assert html =~ ~s(href="/goals/#{mission.id}")
      assert html =~ ~s(href="/projects/#{project.id}")
    end

    test "shows floating mission context for unlinked issues" do
      {:ok, issue} =
        create_issue(%{
          title: "Floating detail issue",
          description: "No goal yet.",
          status: :todo,
          priority: :medium
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ ~s(data-testid="issue-mission-context")
      assert html =~ "No goal linked"
      assert html =~ "Floating"
      assert html =~ "This work is not tied to a goal yet"
      assert html =~ ~s(href="/goals")
    end

    test "blocked issue without a packet falls back to the latest [blocked] note" do
      {:ok, agent} =
        create_agent(%{
          name: "Blocking Marketer",
          role: :marketer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Blocked without structured packet",
          description: "Agent blocked this via comment only.",
          status: :blocked,
          priority: :high
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          issue_id: issue.id,
          author_type: "agent",
          author_id: agent.id,
          body:
            "[blocked] Cause: marketer needs the owner-confirmed launch date before drafting the thread."
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ ~s(data-testid="issue-blocker-packet")
      assert html =~ "Blocked — needs you"
      assert html =~ "owner-confirmed launch date"
    end

    test "shows owner-readable blocker packet in the sidebar" do
      {:ok, issue} =
        create_issue(%{
          title: "Blocked with packet",
          description: "Provider setup is missing.",
          status: :blocked,
          priority: :high,
          monitor_state: %{
            "blocker_packet" => %{
              "kind" => "provider_auth",
              "cause" => "Provider credentials are missing.",
              "attempted_fix" => "Checked the runtime profile and company secrets.",
              "needs" => "Owner adds OPENAI_API_KEY or selects a configured provider.",
              "current_state" => "Runtime is paused before spending retries.",
              "next_decision" => "Owner configures credentials, then relaunches the issue.",
              "restart_packet" =>
                "Open Operations, confirm provider health, and relaunch focused runtime."
            }
          }
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ ~s(data-testid="issue-blocker-packet")
      assert html =~ "Blocked — needs you"
      assert html =~ "Provider Auth"
      assert html =~ "Owner adds OPENAI_API_KEY"
      assert html =~ "Owner configures credentials"
      assert html =~ "Runtime is paused before spending retries"
      assert html =~ "Open Operations, confirm provider health"
    end

    test "shows focused runtime command for dispatchable issues in review mode" do
      {:ok, issue} =
        create_issue(%{
          title: "Run only this CEO issue",
          status: :todo,
          priority: :high
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Focus this issue"
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"
      assert html =~ "CYMPHO_ORCHESTRATOR_ENABLED=1"
      assert html =~ ~s(id="issue-focused-runtime-command-#{issue.id}")
      assert html =~ ~s(phx-hook="CopyToClipboard")
      assert html =~ "Copy command"
      assert html =~ ~s(data-testid="start-agent-disabled-reason")
      assert html =~ "can&#39;t start from here in review mode"
      assert html =~ "Use the focused command above, or launch from Operations."
    end

    test "prioritizes a dispatchable issue from the sidebar" do
      {:ok, issue} =
        create_issue(%{
          title: "Operator focus issue",
          status: :todo,
          priority: :high
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Dispatch focus"
      assert html =~ "Prioritize for next dispatch"

      html =
        view
        |> element("#issue-agent-panel button", "Prioritize for next dispatch")
        |> render_click()

      assert html =~
               "Issue prioritized for next dispatch. Copy the focused command from the digest or sidebar and start runtime."

      assert html =~ "Operator focus active"
      assert html =~ "Focus queued"
      assert html =~ "Dispatch focus is pinned, but autonomous dispatch is disabled."
      assert html =~ "Start the focused runtime command from the digest or sidebar"

      updated = Issues.get_issue!(issue.id)
      assert Issues.dispatch_pinned?(updated)
    end

    test "queues open delegated sub-issues from the parent review gate" do
      {:ok, product_owner} =
        create_agent(%{
          name: "Delegated Product Owner",
          role: :product_manager,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, cto_owner} =
        create_agent(%{
          name: "Delegated CTO Owner",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, parent} =
        create_issue(%{
          title: "Delegated parent issue",
          status: :blocked,
          priority: :high,
          assigned_role: "ceo"
        })

      {:ok, product_child} =
        create_issue(%{
          title: "Define delegated success metrics",
          status: :todo,
          priority: :high,
          parent_id: parent.id,
          assigned_role: "product_manager"
        })

      {:ok, cto_child} =
        create_issue(%{
          title: "Verify delegated runtime path",
          status: :todo,
          priority: :high,
          parent_id: parent.id,
          assignee_id: cto_owner.id,
          assigned_role: "cto"
        })

      {:ok, blocked_child} =
        create_issue(%{
          title: "Wait for blocked dependency",
          status: :todo,
          priority: :critical,
          parent_id: parent.id,
          assigned_role: "cto"
        })

      {:ok, closed_child} =
        create_issue(%{
          title: "Already closed child",
          status: :done,
          priority: :medium,
          parent_id: parent.id,
          assigned_role: "engineer"
        })

      {:ok, dependency} =
        create_issue(%{
          title: "Dependency still active",
          status: :todo,
          priority: :medium
        })

      assert {:ok, _blocked_child} = Issues.add_blocker(blocked_child, dependency)
      assert {:ok, _cto_child} = Issues.prioritize_for_dispatch(cto_child)

      {:ok, view, html} = live(conn(), "/issues/#{parent.id}")

      assert html =~ "Queue runnable sub-issues"
      assert html =~ ~s(id="issue-delegated-dispatch-control")
      assert html =~ "Dispatch delegated work"
      assert html =~ "1 runnable of 3 open child issues will be prioritized."
      assert html =~ "Open sub-issues"
      assert html =~ "Open delegated queue"
      assert html =~ ~s(href="/operations?parent_issue_id=#{parent.id}#delegated-work-queue")

      html =
        view
        |> element("#issue-delegated-dispatch-control button", "Queue runnable sub-issues")
        |> render_click()

      assert html =~
               "Queued 1 runnable sub-issue for focused dispatch. Start runtime from Operations to continue delegated work."

      assert html =~ ~s(id="child-dispatch-focus-#{product_child.id}")
      assert html =~ ~s(id="child-dispatch-focus-#{cto_child.id}")
      refute html =~ ~s(id="child-dispatch-focus-#{blocked_child.id}")
      refute html =~ ~s(id="child-dispatch-focus-#{closed_child.id}")
      assert html =~ ~s(id="child-copy-focused-command-#{product_child.id}")
      assert html =~ ~s(id="child-copy-focused-command-#{cto_child.id}")
      refute html =~ ~s(id="child-copy-focused-command-#{blocked_child.id}")
      refute html =~ ~s(id="child-copy-focused-command-#{closed_child.id}")
      assert html =~ ~s(id="child-clear-dispatch-focus-#{product_child.id}")
      assert html =~ ~s(id="child-clear-dispatch-focus-#{cto_child.id}")
      refute html =~ ~s(id="child-clear-dispatch-focus-#{blocked_child.id}")
      refute html =~ ~s(id="child-clear-dispatch-focus-#{closed_child.id}")
      assert html =~ ~s(id="child-focused-command-text-#{product_child.id}")
      assert html =~ ~s(id="child-focused-command-text-#{cto_child.id}")
      refute html =~ ~s(id="child-focused-command-text-#{blocked_child.id}")
      refute html =~ ~s(id="child-focused-command-text-#{closed_child.id}")
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{product_child.id}"
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{cto_child.id}"
      refute html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{blocked_child.id}"
      refute html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{closed_child.id}"
      assert html =~ "Delegated Product Owner"
      assert html =~ "Delegated CTO Owner"

      product_child = Issues.get_issue!(product_child.id)
      cto_child = Issues.get_issue!(cto_child.id)
      blocked_child = Issues.get_issue!(blocked_child.id)

      assert product_child.assignee_id == product_owner.id
      assert product_child.status == :todo
      assert cto_child.assignee_id == cto_owner.id
      assert cto_child.status == :todo
      assert blocked_child.assignee_id == nil
      assert blocked_child.status == :todo
      assert Issues.dispatch_pinned?(product_child)
      assert Issues.dispatch_pinned?(cto_child)
      refute Issues.dispatch_pinned?(blocked_child)
      refute closed_child.id |> Issues.get_issue!() |> Issues.dispatch_pinned?()

      html =
        view
        |> element("#child-clear-dispatch-focus-#{product_child.id}", "Clear focus")
        |> render_click()

      assert html =~ "Dispatch focus cleared for child issue."
      refute html =~ ~s(id="child-dispatch-focus-#{product_child.id}")
      refute html =~ ~s(id="child-copy-focused-command-#{product_child.id}")
      refute html =~ ~s(id="child-clear-dispatch-focus-#{product_child.id}")
      assert html =~ ~s(id="child-dispatch-focus-#{cto_child.id}")
      assert html =~ "Queue runnable sub-issues"

      refute product_child.id |> Issues.get_issue!() |> Issues.dispatch_pinned?()
      assert cto_child.id |> Issues.get_issue!() |> Issues.dispatch_pinned?()

      html =
        view
        |> element("#issue-digest-actions button", "Queue runnable sub-issues")
        |> render_click()

      assert html =~ "Queued 1 runnable sub-issue for focused dispatch."
      assert html =~ "No runnable sub-issues"
      assert html =~ "Open child work is already focused or blocked by active dependencies."
      assert html =~ ~s(id="issue-delegated-dispatch-control")

      assert has_element?(
               view,
               "#issue-digest-actions button[disabled]",
               "No runnable sub-issues"
             )
    end

    test "shows assigned agent runtime readiness on issue detail" do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO",
          role: :ceo,
          status: :idle,
          adapter: :claude_code,
          health_status: :degraded,
          config: %{"command" => "cz"},
          runtime_config: %{
            "profile_id" => "claude-cz",
            "env" => %{"ANTHROPIC_MODEL" => "cheap-ceo-model"}
          },
          max_concurrent_jobs: 2,
          adapter_failure_count: 3
        })

      {:ok, issue} =
        create_issue(%{
          title: "CEO runtime readiness",
          status: :todo,
          priority: :high,
          assignee_id: ceo.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Agent readiness"
      assert html =~ "CEO"
      assert html =~ "Review mode"
      assert html =~ "Claude Code · 2 local CLI slots"
      assert html =~ "Claude-compatible via cz"
      assert html =~ "cz"
      assert html =~ "cheap-ceo-model"
      assert html =~ "ANTHROPIC_API_KEY"
      assert html =~ "Prior adapter health: Degraded"
      assert html =~ "Recent adapter failures: 3"
      assert html =~ "Open agent config"
    end

    test "shows a local CEO launch preview before provider dispatch" do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO Preview",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Preview CEO handoff",
          status: :todo,
          priority: :high,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "CEO flow"
      assert html =~ "Owner request loop"
      assert html =~ "Owner request captured"
      assert html =~ "Routed to CEO Preview in the CEO lane."
      assert html =~ "CEO flow snapshot"
      assert html =~ ~s(data-testid="issue-ceo-flow-snapshot")
      assert html =~ "Launch needed"

      assert html =~
               "Start the first CEO turn and require an owner update, handoff, or blocker before delivery proceeds."

      assert html =~ ~s(href="#issue-ceo-flow-checklist")
      assert html =~ "Open CEO checklist"
      assert html =~ "Launch CEO turn"
      assert html =~ "Launch needed"
      assert html =~ "Waiting for owner signal"
      assert html =~ "Decision pending"
      assert html =~ "CEO launch preview"
      assert html =~ "Local dry-run"
      assert html =~ "CEO Preview · Process"
      assert html =~ "Review mode"
      assert html =~ "Review mode is active; copy the focused command"
      assert html =~ "Next setup action"
      assert html =~ "Execution mode"
      assert html =~ "Open service gates"
      assert html =~ ~s(href="/operations#runtime-services")
      assert html =~ "[owner_update]"
      assert html =~ "[handoff]"
      assert html =~ "[blocked]"
      assert html =~ "2-5 scoped sub-issues"
      assert html =~ "evidence required"
      assert html =~ "verification required"
      assert html =~ "definition of done"
      assert html =~ "No provider call"
      assert html =~ ~s(phx-hook="CopyToClipboard")
      assert html =~ "Copy CEO brief"
      assert html =~ "CEO launch brief"
      assert html =~ "Focused command:"
      assert html =~ "No description supplied."
      assert html =~ "Draft owner update"
      assert html =~ "Draft handoff"
      assert html =~ "Draft blocker"

      html =
        view
        |> element("#issue-ceo-launch-preview button[phx-value-template='owner_update']")
        |> render_click()

      assert html =~ "[owner_update] What happened:"
      assert html =~ "Business status:"
      assert html =~ "Owner decision needed:"

      html =
        view
        |> element("#issue-ceo-launch-preview button[phx-value-template='handoff']")
        |> render_click()

      assert html =~ "[handoff] What happened:"
      assert html =~ "Next owner:"

      html =
        view
        |> element("#issue-ceo-launch-preview button[phx-value-template='blocked']")
        |> render_click()

      assert html =~ "[blocked] Cause:"
      assert html =~ "Attempted fix:"
      assert html =~ "Needs:"
    end

    test "shows CEO setup blocker on issue detail when no CEO agent exists" do
      {:ok, issue} =
        create_issue(%{
          title: "Owner request without CEO agent",
          status: :todo,
          priority: :high,
          assigned_role: "ceo"
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "CEO flow"
      assert html =~ "Routed to the CEO lane"
      assert html =~ "CEO launch preview"
      assert html =~ "No agent"
      assert html =~ "No idle eligible CEO is available"
      assert html =~ "Next setup action"
      assert html =~ "Dispatch eligibility"
      assert html =~ "eligible CEO"
      assert html =~ "Add CEO agent"
      assert html =~ ~s(href="/agents/new")
      assert html =~ "Waiting for first CEO turn"
    end

    test "shows CEO outcome card from the latest owner update" do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO Outcome",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "CEO outcome issue",
          status: :in_progress,
          priority: :high,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[owner_update] What happened: strategy is framed. Business status: not shipped. Current state: ready to delegate. Next decision: hand off implementation. Owner decision needed: none.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "CEO flow"
      assert html =~ "CEO flow snapshot"
      assert html =~ "CEO turn completed"
      assert html =~ "Owner update captured"

      assert html =~
               "Review the CEO owner update, then accept it, request revision, or keep delegated work moving."

      assert html =~ "Owner decision ready"
      assert html =~ "CEO outcome"
      assert html =~ "Owner update"
      assert html =~ "CEO left an owner-facing status update"
      assert html =~ "strategy is framed"
      assert html =~ "Use this update as the current business status"
      assert html =~ "Open Operations monitor"
      assert html =~ ~s(href="/operations#ceo-outcome-monitor")
    end

    test "accepts and closes CEO owner-verification handbacks from the digest" do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO Owner Verifier",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Close owner verification",
          description: "Owner should verify the CEO first turn.",
          status: :blocked,
          priority: :high,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      Repo.insert!(%Run{
        agent_id: ceo.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "openai_chat",
        continuation_summary: "CEO owner update produced."
      })

      {:ok, _owner_update} =
        Comments.create_comment(%{
          body:
            "[owner_update] What happened: CEO produced the first turn. Business status: not shipped. Current state: waiting on owner verification. Next decision: owner accepts and closes. Owner decision needed: verify.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      {:ok, _blocked} =
        Comments.create_comment(%{
          body:
            "[blocked] Cause: Waiting for owner to verify the smoke test output. Current state: blocked on owner verification. Next decision: owner closes after verification.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Accept and close"
      assert html =~ "owner verification"

      html =
        view
        |> element("#issue-digest-actions button", "Accept and close")
        |> render_click()

      assert html =~ "Owner verification accepted and issue closed."
      assert Issues.get_issue!(issue.id).status == :done
      assert html =~ "Closed"
      assert html =~ "owner accepted the CEO verification update"
    end

    test "requests CEO owner-verification revisions from the digest" do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO Revision Verifier",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Revise owner verification",
          description: "Owner should ask the CEO for one focused revision.",
          status: :blocked,
          priority: :high,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      Repo.insert!(%Run{
        agent_id: ceo.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "openai_chat",
        continuation_summary: "CEO owner update produced."
      })

      {:ok, _owner_update} =
        Comments.create_comment(%{
          body:
            "[owner_update] What happened: CEO produced the first turn. Business status: not shipped. Current state: waiting on owner verification. Next decision: owner accepts or requests revision. Owner decision needed: verify.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      {:ok, _blocked} =
        Comments.create_comment(%{
          body:
            "[blocked] Cause: Waiting for owner to verify the smoke test output. Current state: blocked on owner verification. Next decision: owner closes after verification.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Accept and close"
      assert html =~ "Request revision"

      html =
        view
        |> element("#issue-digest-actions button", "Request revision")
        |> render_click()

      assert html =~ "Owner revision requested"

      reopened = Issues.get_issue!(issue.id)
      assert reopened.status == :todo
      assert reopened.assignee_id == ceo.id
      assert Issues.dispatch_pinned?(reopened)
      refute Issues.owner_verification_closeable?(reopened)

      assert Enum.any?(
               Comments.list_comments(issue.id),
               &String.contains?(&1.body, "owner reopened the CEO verification update")
             )
    end

    test "shows CEO outcome card when the latest CEO run needs attention" do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO Needs Attention",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "CEO failed runtime issue",
          status: :blocked,
          priority: :critical,
          assigned_role: "ceo"
        })

      Repo.insert!(%Run{
        agent_id: ceo.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "failed",
        adapter: "process",
        error_reason: "OPENAI_API_KEY not set"
      })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "CEO flow"
      assert html =~ "CEO flow checklist"
      assert html =~ "Runtime needs attention"
      assert html =~ "Owner signal blocked"
      assert html =~ "Decision blocked"
      assert html =~ "CEO outcome"
      assert html =~ "Needs attention"
      assert html =~ "CEO runtime needs attention"
      assert html =~ "Failed · OPENAI_API_KEY not set"
      assert html =~ "Fix the runtime/provider issue, then relaunch from the focused command."
      assert html =~ "Focused relaunch command"
      assert html =~ "Fix the feedback above, then restart runtime focused on this issue."
      assert html =~ "Setup still needs"
      assert html =~ "Execution mode"
      assert html =~ "Open service gates"
      assert html =~ ~s(href="/operations#runtime-services")
      assert html =~ "Reopen and prioritize relaunch"
      assert html =~ ~s(id="issue-ceo-outcome-focused-command-#{issue.id}")
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"
      assert html =~ "Open Operations monitor"

      assert has_element?(
               view,
               "#issue-ceo-flow-checklist button",
               "Reopen and prioritize relaunch"
             )

      html =
        view
        |> element(
          "#issue-ceo-outcome-focused-command-#{issue.id} button",
          "Reopen and prioritize relaunch"
        )
        |> render_click()

      assert html =~
               "Issue queued for focused relaunch. Copy the focused command from this issue page and start runtime."

      assert html =~ "Relaunch focus queued"
      assert html =~ "Setup still needs"
      assert html =~ "Execution mode"

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :todo
      assert Issues.dispatch_pinned?(updated)
    end

    test "points todo issues without runs at runtime launch before evidence actions" do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO",
          role: :ceo,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "CEO needs first runtime pass",
          description: "Owner asks CEO to define the execution plan.",
          status: :todo,
          priority: :high,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Start runtime first"
      assert html =~ "Launch needed"
      assert html =~ "Assigned, but runtime has not started yet."
      assert html =~ "Open the Operations launch checklist"
      assert html =~ "first output must be `[owner_update]`, `[handoff]`, or `[blocked]`"
      assert html =~ ~s(id="issue-digest-actions")
      assert html =~ ~s(phx-hook="CopyToClipboard")
      assert html =~ "Queue focused dispatch"
      assert html =~ ~s(phx-click="prioritize_dispatch")
      assert html =~ "Copy focused command"
      assert html =~ ~s(data-copy-label="Copy focused command")
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"
      assert html =~ "Open launch checklist"
      assert html =~ ~s(href="/operations#runtime-launch-checklist")
      assert html =~ "CEO first turn"
      assert html =~ "CEO has not produced the first owner-facing signal yet."
      assert html =~ "Start the CEO turn before assigning delivery."
      assert html =~ "no runtime evidence yet"
      assert html =~ "Runtime launch needed"

      assert html =~
               "Start runtime from the digest, sidebar, or Operations before adding delivery notes or artifacts."

      refute html =~
               "Start focused dispatch from Operations before adding delivery notes or artifacts."

      refute html =~ "Auto-nudges"
      refute html =~ "Add completion note"
      refute html =~ "Nudge delivery owner"

      html =
        view
        |> element("#issue-digest-actions button[phx-click='prioritize_dispatch']")
        |> render_click()

      assert html =~
               "Issue prioritized for next dispatch. Copy the focused command from the digest or sidebar and start runtime."

      assert html =~ "Operator focus active"
      assert html =~ "Focus queued"
      assert html =~ "Focused dispatch is queued. Copy the focused command or start runtime"
      assert html =~ "Focused dispatch is already queued for this issue."
      assert html =~ "Focused dispatch is already queued; copy the command or start runtime."
      assert has_element?(view, "#issue-digest-actions button[disabled]", "Focus queued")
      assert html =~ "Clear focus"

      updated = Issues.get_issue!(issue.id)
      assert Issues.dispatch_pinned?(updated)

      html =
        view
        |> element("button[phx-click='clear_dispatch_focus']", "Clear focus")
        |> render_click()

      assert html =~ "Dispatch focus cleared."
      assert html =~ "Queue focused dispatch"
      refute html =~ "Operator focus active"

      updated = Issues.get_issue!(issue.id)
      refute Issues.dispatch_pinned?(updated)
    end

    test "shows CEO launch setup action for missing provider credentials" do
      {:ok, ceo} =
        create_agent(%{
          name: "Remote CEO",
          role: :ceo,
          status: :idle,
          adapter: :agrenting,
          config: %{}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Preview remote CEO credential setup",
          status: :todo,
          priority: :high,
          assignee_id: ceo.id,
          assigned_role: "ceo"
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "CEO launch preview"
      assert html =~ "Next setup action"
      assert html =~ "Agrenting API key"
      assert html =~ "Pick how this agent runs."
      refute html =~ "test-api-key"
    end

    test "shows assigned agent preflight blockers on issue detail" do
      {:ok, agent} =
        create_agent(%{
          name: "Missing Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "__missing_cympho_test_command__", "model" => "custom"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Runtime preflight blocker",
          status: :todo,
          priority: :high,
          assignee_id: agent.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Agent preflight"
      assert html =~ "Blocked"
      assert html =~ "Command"
      assert html =~ "__missing_cympho_test_command__ was not found"
      assert html =~ "Execution mode"
      assert html =~ "Edit command"
      assert html =~ "/agents/#{agent.id}?tab=configuration#agent-process-command"
    end

    test "shows paused company runtime as the issue launch blocker", %{
      current_company: company
    } do
      {:ok, _paused} =
        Companies.execute_company_update(company, %{
          status: "paused",
          paused_at: DateTime.utc_now() |> DateTime.truncate(:second),
          paused_reason: "operator hold"
        })

      {:ok, agent} =
        create_agent(%{
          name: "Paused Company Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom", "repo_capable" => true}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Paused company runtime blocker",
          description: "Acceptance criteria:\n- Runtime stays stopped while paused.",
          status: :todo,
          priority: :high,
          assignee_id: agent.id,
          assigned_role: "engineer"
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Agent preflight"
      assert html =~ "Paused"
      assert html =~ "Runtime paused"
      assert html =~ "operator hold"
      assert html =~ "Resume the team"
      assert html =~ "Turn the team back on to start."

      assert html =~
               "Your agents are paused. Resume them before starting anything new."

      assert has_element?(view, "button[disabled]", "Start agent")
    end

    test "shows dispatch eligibility blocker for busy assigned agent on issue detail" do
      {:ok, agent} =
        create_agent(%{
          name: "Busy Runtime Agent",
          role: :engineer,
          status: :running,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Busy agent preflight blocker",
          status: :todo,
          priority: :high,
          assignee_id: agent.id,
          assigned_role: "engineer"
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Agent preflight"
      assert html =~ "No agent"
      assert html =~ "Dispatch eligibility"
      assert html =~ "Busy Runtime Agent is running"
      assert html =~ "return idle"
    end

    test "shows thin delivery brief warning on issue detail" do
      {:ok, agent} =
        create_agent(%{
          name: "Brief Check Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom", "repo_capable" => true}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Thin delivery brief issue",
          description: "Do it.",
          status: :todo,
          priority: :high,
          assignee_id: agent.id,
          assigned_role: "engineer"
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ ~s(id="issue-description")
      assert html =~ "Agent preflight"
      assert html =~ "Needs config"
      assert html =~ "Delivery brief"
      assert html =~ "Too thin for delivery"
      assert html =~ "Acceptance criteria"
      assert html =~ "Edit issue brief"
      assert html =~ "/issues/#{issue.id}#issue-description"
      assert html =~ "The brief needs more detail"
      assert html =~ "Copy template"
      assert html =~ "Use template"

      html =
        view
        |> element("#issue-delivery-brief-repair button", "Use template")
        |> render_click()

      assert html =~ "Template loaded into the description editor."
      assert html =~ ~s(phx-submit="save_description")
      assert textarea_value(html, "textarea[name='description']") =~ "Delivery goal:"
      assert textarea_value(html, "textarea[name='description']") =~ "Acceptance criteria:"
      assert textarea_value(html, "textarea[name='description']") =~ "Evidence required:"
      assert textarea_value(html, "textarea[name='description']") =~ "Verification required:"
      assert textarea_value(html, "textarea[name='description']") =~ "Definition of done:"
    end

    test "shows simple workspace isolation setup action on issue detail" do
      {:ok, project} =
        create_project(%{
          name: "Workspace Isolation UI",
          prefix: unique_project_prefix()
        })

      {:ok, project_workspace} =
        Workspaces.create_project_workspace(%{
          name: "Shared UI checkout",
          cwd: "/tmp/cympho/shared-ui-checkout-#{System.unique_integer([:positive])}",
          is_primary: true,
          project_id: project.id,
          company_id: project.company_id
        })

      {:ok, agent} =
        create_agent(%{
          name: "Workspace UI Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom", "repo_capable" => true}
        })

      description = """
      Acceptance criteria:
      - Workspace setup warning is visible.

      Evidence required:
      - Issue detail includes the warning.

      Verification required:
      - Focused render test covers the preflight action.

      Definition of done:
      - Operator can open the workspace.
      """

      {:ok, issue} =
        create_issue(%{
          title: "Workspace isolation UI issue",
          description: description,
          status: :todo,
          priority: :high,
          assignee_id: agent.id,
          assigned_role: "engineer",
          project_id: project.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ ~s(id="issue-simple-preflight-action")
      assert html =~ "No safe place to work"
      assert html =~ "Workspace isolation"
      assert html =~ "Give it its own copy of the code."
      assert html =~ "Shared UI checkout"
      assert html =~ "/workspaces/#{project_workspace.id}"
      assert html =~ "Open workspace"
    end

    test "shows delivery brief repair for an assigned repo agent without assigned role" do
      {:ok, agent} =
        create_agent(%{
          name: "Assigned Brief Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Build assigned engineer brief",
          description: "Do it.",
          status: :todo,
          priority: :high,
          assignee_id: agent.id
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Agent preflight"
      assert html =~ "Delivery brief"
      assert html =~ "Too thin for delivery"
      assert html =~ "The brief needs more detail"
      assert html =~ "Use template"

      html =
        view
        |> element("#issue-delivery-brief-repair button", "Use template")
        |> render_click()

      assert html =~ "Template loaded into the description editor."
      assert textarea_value(html, "textarea[name='description']") =~ "Acceptance criteria:"
      assert textarea_value(html, "textarea[name='description']") =~ "Evidence required:"
      assert textarea_value(html, "textarea[name='description']") =~ "Definition of done:"
    end

    test "shows auto-route readiness and delivery repair for unassigned repo issue" do
      {:ok, _agent} =
        create_agent(%{
          name: "Auto Route Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom", "repo_capable" => true}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Fix code path from auto route",
          description: "Do it.",
          status: :todo,
          priority: :high
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Auto-route readiness"
      assert html =~ "Auto Route Engineer"
      assert html =~ "routed by dispatcher"
      assert html =~ "Delivery brief"
      assert html =~ "Too thin for delivery"
      assert html =~ "The brief needs more detail"
      assert html =~ "Use template"

      html =
        view
        |> element("#issue-delivery-brief-repair button", "Use template")
        |> render_click()

      assert html =~ "Template loaded into the description editor."
      assert textarea_value(html, "textarea[name='description']") =~ "Acceptance criteria:"
      assert textarea_value(html, "textarea[name='description']") =~ "Evidence required:"
      assert textarea_value(html, "textarea[name='description']") =~ "Verification required:"
      assert textarea_value(html, "textarea[name='description']") =~ "Definition of done:"
    end

    test "renders comments section", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ ~s(aria-label="Comment templates")
      assert html =~ ~s(aria-label="Send comment")
      assert html =~ "Owner update"
      assert html =~ "Delivery"
      assert html =~ "Blocked"
    end

    test "comment composer sticks above fixed mobile nav", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      attrs = element_attrs(html, "#issue-comments")
      class = Map.get(attrs, "class", "")

      assert class =~ "sticky-above-mobile-nav"
      assert class =~ "sticky"
      refute class =~ "bottom-0"
    end

    test "shows existing comments", %{issue: issue} do
      {:ok, _comment} =
        Comments.create_comment(%{
          body: "Test comment body",
          author_type: "user",
          author_id: "test-author",
          issue_id: issue.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Test comment body"
      assert html =~ "test-author"
      assert html =~ "Owner input"
    end

    test "renders execution brief and per-agent contribution cards", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} = Issues.update_issue(issue, %{assignee_id: agent.id})

      {:ok, _comment} =
        Comments.create_comment(%{
          body: "Implemented the smoke path and verified the LiveView renders.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "claude_code",
        continuation_summary: "Tests passed for the smoke path."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "code_change",
          title: "Smoke implementation",
          description: "Changed the issue detail page and added coverage."
        })

      {:ok, _child_issue} =
        create_issue(%{
          title: "Follow-up smoke subtask",
          description: "Subtask created by the runtime agent.",
          status: :todo,
          priority: :medium,
          parent_id: issue.id,
          assigned_role: "engineer",
          created_by_agent_id: agent.id
        })

      {:ok, ready_child} =
        create_issue(%{
          title: "Review-ready implementation slice",
          description: "Engineer finished the slice and wants CTO review.",
          status: :in_review,
          priority: :high,
          parent_id: issue.id,
          assignee_id: agent.id,
          assigned_role: "engineer",
          created_by_agent_id: agent.id
        })

      {:ok, _child_comment} =
        Comments.create_comment(%{
          body: "[delivery] Implemented the delegated slice and attached evidence.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: ready_child.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: ready_child.id,
        company_id: ready_child.company_id,
        status: "completed",
        adapter: "claude_code",
        continuation_summary: "Child slice checks passed."
      })

      {:ok, _child_work_product} =
        WorkProducts.create_work_product(%{
          issue_id: ready_child.id,
          created_by_agent_id: agent.id,
          kind: "code_change",
          title: "Child implementation diff",
          description: "Evidence for the child issue."
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Executive digest"
      assert html =~ "Coordinating work"
      assert html =~ "Next action"
      assert html =~ "Latest signal"
      assert html =~ "What happened so far"
      assert html =~ "Compact operational memory"
      assert html =~ "Actions taken"
      assert html =~ "Files / artifacts"
      assert html =~ "What happened"
      assert html =~ "Current state"
      assert html =~ "Next decision"
      assert html =~ "Comment mix"
      assert html =~ "Role run summaries"
      assert html =~ "Engineer delivery"
      assert html =~ "CTO review"
      assert html =~ "CEO owner update"
      assert html =~ "Runtime evidence"
      assert html =~ "Delivery"
      assert html =~ "Agent-by-agent ledger"
      assert html =~ "What each role has contributed"
      assert html =~ "Review readiness"
      assert html =~ "CTO/CEO review decision"
      assert html =~ "blocking CTO/CEO approval"
      assert html =~ "Contract audit"
      assert html =~ "Satisfied by Runtime Agent"
      assert html =~ "Evidence coverage"
      assert html =~ "Execution brief"
      assert html =~ "Handoff lane"
      assert html =~ "Current signal"
      assert html =~ "Runtime complete"
      assert html =~ "Runtime run ledger"
      assert html =~ "Owner decision packet"
      assert html =~ "Decision requested"
      assert html =~ "Evidence to trust"
      assert html =~ "Risk / gaps"
      assert html =~ "Next owner"
      assert html =~ "Runtime Agent"
      assert html =~ "Follow 2 open delegated sub-issues"
      assert html =~ "Owner update"
      assert html =~ "Work narrative"
      assert html =~ "Owner request"
      assert html =~ "Engineering work"
      assert html =~ "Delegation map"
      assert html =~ "CTO review queue"
      assert html =~ "CEO owner update readiness"
      assert html =~ "Ready for CTO"
      assert html =~ "Missing evidence"
      assert html =~ "Review-ready implementation slice"
      assert html =~ "Agent contributions"
      assert html =~ "Runtime Agent"
      assert html =~ "Implemented the smoke path"
      assert html =~ "Smoke implementation"
      assert html =~ "Delegated"
      assert html =~ "Follow-up smoke subtask"
      assert html =~ "Code work exists but no PR link is set."
    end

    test "shows runtime run ledger with latest run status and detail", %{issue: issue} do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO Runtime",
          role: :ceo,
          status: :idle,
          adapter: :claude_code
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      completed =
        Repo.insert!(%Run{
          agent_id: ceo.id,
          issue_id: issue.id,
          company_id: issue.company_id,
          status: "completed",
          adapter: "claude_code",
          continuation_summary: "CEO summarized the operating plan.",
          started_at: DateTime.add(now, -180, :second),
          completed_at: DateTime.add(now, -120, :second),
          input_tokens: 12_000,
          output_tokens: 1_500
        })

      failed =
        Repo.insert!(%Run{
          agent_id: ceo.id,
          issue_id: issue.id,
          company_id: issue.company_id,
          status: "failed",
          adapter: "claude_code",
          error_reason: "Provider rejected the request.",
          log_excerpt: "HTTP 401",
          started_at: DateTime.add(now, -90, :second),
          completed_at: DateTime.add(now, -80, :second)
        })

      running =
        Repo.insert!(%Run{
          agent_id: ceo.id,
          issue_id: issue.id,
          company_id: issue.company_id,
          status: "running",
          adapter: "claude_code",
          workspace_path: "/tmp/cympho-ceo-run",
          started_at: DateTime.add(now, -30, :second)
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Runtime run ledger"
      assert html =~ ~s(id="runtime-run-ledger-#{running.id}")
      assert html =~ ~s(id="runtime-run-ledger-#{failed.id}")
      assert html =~ ~s(id="runtime-run-ledger-#{completed.id}")
      assert html =~ "Running"
      assert html =~ "Failed"
      assert html =~ "Completed"
      assert html =~ "CEO Runtime"
      assert html =~ "claude code"
      assert html =~ "Runtime is still in flight."
      assert html =~ "Provider rejected the request."
      assert html =~ "CEO summarized the operating plan."
      assert html =~ "/tmp/cympho-ceo-run"
      assert html =~ "12,000 in"
      assert html =~ "1,500 out"

      assert html =~ "1m 0s"
      assert html =~ "10s"
    end

    test "keeps long runtime ledgers bounded and shows the true total", %{issue: issue} do
      {:ok, ceo} =
        create_agent(%{
          name: "Bounded Runtime CEO",
          role: :ceo,
          status: :idle,
          adapter: :codex
        })

      base_time = ~U[2026-01-01 00:00:00Z]

      runs =
        for index <- 1..55 do
          timestamp = DateTime.add(base_time, index, :second)
          label = index |> Integer.to_string() |> String.pad_leading(2, "0")

          Repo.insert!(%Run{
            agent_id: ceo.id,
            issue_id: issue.id,
            company_id: issue.company_id,
            status: "failed",
            adapter: "codex",
            error_reason: "bounded-run-#{label}",
            started_at: timestamp,
            completed_at: timestamp,
            inserted_at: timestamp,
            updated_at: timestamp
          })
        end

      oldest = List.first(runs)
      newest = List.last(runs)

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Runtime run ledger"
      assert html =~ "Latest 5 of 55 runs"
      assert html =~ "Showing the newest entries keeps long-running issues responsive."
      assert html =~ ~s(id="runtime-run-ledger-#{newest.id}")
      assert html =~ "bounded-run-55"
      refute html =~ ~s(id="runtime-run-ledger-#{oldest.id}")
      refute html =~ "bounded-run-01"
    end

    test "shows CEO flow checklist for CEO-owned issues", %{issue: issue} do
      {:ok, ceo} =
        create_agent(%{
          name: "Checklist CEO",
          role: :ceo,
          status: :idle
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          title: "Improve onboarding activation",
          description: """
          Goal: improve onboarding activation.
          Context: setup drops after project creation.
          Constraints / risks: must not slow first project creation.
          Definition of done: CEO creates a plan or handoff with acceptance criteria.
          CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`): handoff if execution is needed.
          Evidence to inspect after the run: scoped child issues and verification notes.
          """,
          status: :todo,
          assigned_role: "ceo",
          assignee_id: ceo.id
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "CEO flow checklist"
      assert html =~ ~s(data-testid="issue-ceo-flow-checklist")
      assert html =~ "CEO launch packet"
      assert html =~ ~s(data-testid="issue-ceo-launch-packet")
      assert html =~ "Ready to launch"

      assert html =~
               "Queue focus if needed, run the focused command, then require the CEO to leave `[owner_update]`, `[handoff]`, or `[blocked]`."

      assert html =~ "Owner brief readiness"
      assert html =~ "Ready for CEO launch (6/6 signals)"
      assert html =~ "First-turn contract"
      assert html =~ "Focused command"
      assert html =~ "Copy packet"
      assert html =~ "Copy command"
      refute html =~ "Owner brief repair"
      assert html =~ "Owner brief readiness: Ready for CEO launch (6/6 signals)"
      assert html =~ "First-turn contract: Return `[owner_update]`, `[handoff]`, or `[blocked]`"
      assert html =~ "Observe after launch"
      assert html =~ "Runtime result"
      assert html =~ "Watch for a completed or failed CEO run before judging the flow."
      assert html =~ "CEO signal"
      assert html =~ "First useful output must be `[owner_update]`, `[handoff]`, or `[blocked]`."
      assert html =~ "Delegated work"
      assert html =~ "Owner decision"
      assert html =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"
      assert html =~ "Issue defined"
      assert html =~ "Brief readiness"
      assert html =~ "6/6 signals"
      assert html =~ "All launch signals are present."
      assert html =~ "CEO assigned"
      assert html =~ "Checklist CEO"
      assert html =~ "Runtime launch"
      assert html =~ "Launch needed"
      assert html =~ "No CEO runtime has started yet."
      assert html =~ "CEO outcome"
      assert html =~ "Awaiting signal"

      assert html =~
               "First useful CEO result should be `[owner_update]`, `[handoff]`, or `[blocked]`."

      assert html =~ "Owner signoff"
      assert html =~ "Owner signoff starts after a CEO owner update is posted."
      assert html =~ "Queue focused CEO run"

      command_attrs =
        element_attrs(html, "#issue-ceo-launch-packet button[data-copy-label='Copy command']")

      assert command_attrs["data-copy-text"] =~ "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue.id}"
      assert command_attrs["data-copy-text"] =~ "mise exec -- mix phx.server"

      html =
        view
        |> element("#issue-ceo-flow-checklist button", "Queue focused CEO run")
        |> render_click()

      assert html =~
               "Issue prioritized for next dispatch. Copy the focused command from the digest or sidebar and start runtime."

      assert html =~ "Focus queued"
      assert html =~ "Focus is queued. Start the focused runtime command below"
      assert html =~ "then watch for `[owner_update]`, `[handoff]`, or `[blocked]`"

      updated = Issues.get_issue!(issue.id)
      assert Issues.dispatch_pinned?(updated)
    end

    test "CEO flow checklist holds thin briefs before runtime launch", %{issue: issue} do
      {:ok, ceo} =
        create_agent(%{
          name: "Thin Brief CEO",
          role: :ceo,
          status: :idle
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          title: "Short",
          description: "Do it.",
          status: :todo,
          assigned_role: "ceo",
          assignee_id: ceo.id
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "CEO flow checklist"
      assert html =~ "CEO launch packet"
      assert html =~ "Needs operator check"
      assert html =~ "Too thin for autonomy (0/6 signals)"
      assert html =~ "Owner brief readiness: Too thin for autonomy (0/6 signals)"
      assert html =~ "Complete the owner brief before launching CEO runtime"
      assert html =~ "Observe after launch"
      assert html =~ "Brief repair"
      assert html =~ "Launch gate"
      assert html =~ "Needs attention"
      assert html =~ "Brief readiness"
      assert html =~ "0/6 signals"
      assert html =~ "Outcome: Name the owner-visible result"
      assert html =~ "Complete the owner brief signals before launching CEO runtime."
      assert html =~ "The brief needs more detail"
      assert html =~ "Copy template"
      assert html =~ "Use template"
      assert html =~ "Brief repair scaffold:"
      assert html =~ "Constraints / risks:"
      assert html =~ "Focused command: hidden until the owner brief is decision-grade."
      assert has_element?(view, "#issue-ceo-launch-packet button", "Copy packet")
      assert has_element?(view, "#issue-ceo-brief-repair button", "Use template")
      refute has_element?(view, "#issue-ceo-launch-packet button", "Copy command")
      refute has_element?(view, "#issue-ceo-launch-packet code")
      refute has_element?(view, "#issue-ceo-flow-checklist button", "Queue focused CEO run")

      html =
        view
        |> element("#issue-ceo-brief-repair button", "Use template")
        |> render_click()

      assert html =~ ~s(phx-submit="save_description")
      assert html =~ "Template loaded into the description editor."
      assert html =~ "Goal: &lt;the business outcome the owner wants&gt;"

      assert html =~
               "Constraints / risks: &lt;deadline, budget, known risk, or thing the CEO must not do&gt;"
    end

    test "CEO flow checklist recognizes owner update signoff state", %{issue: issue} do
      {:ok, ceo} =
        create_agent(%{
          name: "Signoff CEO",
          role: :ceo,
          status: :idle
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          status: :blocked,
          assigned_role: "ceo",
          assignee_id: ceo.id
        })

      Repo.insert!(%Run{
        agent_id: ceo.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "claude_code",
        continuation_summary: "CEO owner update produced."
      })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[owner_update] What happened: CEO verified the plan. Business status: not shipped. Current state: waiting on owner acceptance. Next decision: owner accepts or requests revision. Owner decision needed: accept.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "CEO flow checklist"
      assert html =~ "CEO flow snapshot"
      assert html =~ "Owner update captured"
      assert html =~ "Runtime launch"
      assert html =~ "Completed"
      assert html =~ "CEO outcome"
      assert html =~ "Owner signal"
      assert html =~ "Owner signoff"
      assert html =~ "Owner review"

      assert html =~
               "CEO update exists and the issue is blocked for owner acceptance or revision."

      assert html =~ "Owner should accept the CEO update or request revision."
    end

    test "shows pending agent wake in the handoff lane", %{issue: issue} do
      {:ok, ceo} =
        create_agent(%{
          name: "CEO",
          role: :ceo,
          status: :idle
        })

      {:ok, issue} = Issues.update_issue(issue, %{status: :todo, assignee_id: ceo.id})

      Repo.insert!(%AgentWake{
        agent_id: ceo.id,
        issue_id: issue.id,
        reason: "manual_dispatch",
        status: "pending",
        triggered_by_type: "system",
        triggered_by_id: "test"
      })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Handoff lane"
      assert html =~ "Waiting on agent"
      assert html =~ "Wake queued for CEO"
      assert html =~ "Manual dispatch"
    end

    test "hides stale pending wake badge on completed issues", %{issue: issue} do
      {:ok, ceo} =
        create_agent(%{
          name: "Done CEO",
          role: :ceo,
          status: :idle
        })

      {:ok, issue} = Issues.update_issue(issue, %{status: :done, assignee_id: ceo.id})

      Repo.insert!(%AgentWake{
        agent_id: ceo.id,
        issue_id: issue.id,
        reason: "manual_dispatch",
        status: "pending",
        triggered_by_type: "system",
        triggered_by_id: "test"
      })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      refute html =~ "Waiting on Done CEO"
      refute html =~ "Wake queued for Done CEO"
    end

    test "shows direct sub-issues", %{issue: issue} do
      {:ok, _child} =
        create_issue(%{
          title: "Child execution task",
          description: "Engineer-owned acceptance criteria",
          status: :todo,
          priority: :medium,
          parent_id: issue.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Sub-issues"
      assert html =~ "Child execution task"
      assert html =~ "Engineer-owned acceptance criteria"
    end

    test "shows delegated child execution contract", %{issue: issue} do
      {:ok, _child} =
        create_issue(%{
          title: "Implement invite handoff",
          description: """
          Build the invite handoff path.

          ## Execution brief

          Parent issue: #{issue.identifier || "CYM-1"} - #{issue.title}
          Target role: Engineer

          **Acceptance criteria**
          - User can complete invite flow
          - Audit trail records inviter

          **Dependencies**
          - (none)

          **Evidence required**
          - PR and work product link

          **Verification required**
          - mix test test/cympho_web/live/invite_flow_test.exs

          **Definition of done**
          - CTO can review from parent issue
          """,
          status: :todo,
          priority: :medium,
          parent_id: issue.id,
          monitor_state: %{"estimated_minutes" => 45}
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Implement invite handoff"
      assert html =~ "Build the invite handoff path."
      assert html =~ "Execution contract"
      assert html =~ "~45m"
      assert html =~ "Acceptance"
      assert html =~ "User can complete invite flow +1"
      assert html =~ "Evidence"
      assert html =~ "PR and work product link"
      assert html =~ "Verification"
      assert html =~ "mix test test/cympho_web/live/invite_flow_test.exs"
      assert html =~ "Done"
      assert html =~ "CTO can review from parent issue"
    end

    test "renders work products in the activity timeline", %{issue: issue} do
      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          kind: "code_change",
          title: "Implementation diff",
          description: "Changed the LiveView and added tests."
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Work product"
      assert html =~ "Implementation diff"
      assert html =~ "Changed the LiveView and added tests."
    end

    test "shows failed run reason in the activity timeline", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "failed",
        adapter: "claude_code",
        error_reason: "Adapter command exited with code 1",
        log_excerpt: "missing provider configuration"
      })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Executive digest"
      assert html =~ "Needs attention"
      assert html =~ "Latest blocker"
      assert html =~ "Missing credentials"
      assert html =~ "Credentials missing"
      assert html =~ "Adapter command exited with code 1"
      assert html =~ "missing provider configuration"
    end

    test "filters activity timeline from signal to runs", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Noise Filter Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, comment} =
        Comments.create_comment(%{
          body: "[owner_update] Owner-visible agent note",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      {:ok, routine_comment} =
        Comments.create_comment(%{
          body: "Still reading through context.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      run =
        Repo.insert!(%Run{
          agent_id: agent.id,
          issue_id: issue.id,
          company_id: issue.company_id,
          status: "completed",
          adapter: "process",
          continuation_summary: "Completed run with owner-visible summary"
        })

      quiet_run =
        Repo.insert!(%Run{
          agent_id: agent.id,
          issue_id: issue.id,
          company_id: issue.company_id,
          status: "completed",
          adapter: "process"
        })

      {:ok, work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "code_change",
          title: "Signal artifact",
          description: "A useful artifact remains visible in signal."
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Signal"
      assert html =~ "Showing 3 signal events · 2 routine events hidden"
      assert html =~ "Signal mode keeps tagged comments"
      assert html =~ "Owner-visible agent note"
      assert html =~ "Completed run with owner-visible summary"
      assert html =~ "Signal artifact"
      assert html =~ "Thread rollup"
      assert html =~ "folding 1 routine note"
      assert html =~ "Comments and All preserve the full audit trail"
      assert html =~ "entry-run-#{run.id}"
      refute html =~ "entry-run-#{quiet_run.id}"
      refute html =~ "entry-comment-#{routine_comment.id}"

      html =
        view
        |> element("#issue-executive-digest button[phx-value-filter='all']", "Open raw timeline")
        |> render_click()

      assert html =~ "entry-run-#{run.id}"
      assert html =~ "entry-run-#{quiet_run.id}"
      assert html =~ "entry-comment-#{routine_comment.id}"
      assert html =~ "Still reading through context."

      html =
        view
        |> element("button[phx-value-filter='runs']")
        |> render_click()

      assert html =~ "entry-run-#{run.id}"
      assert html =~ "entry-run-#{quiet_run.id}"
      assert html =~ "Completed run with owner-visible summary"
      refute html =~ "entry-comment-#{comment.id}"
      refute html =~ "entry-comment-#{routine_comment.id}"
      refute html =~ "entry-work_product-#{work_product.id}"

      html =
        view
        |> element("button[phx-value-filter='comments']")
        |> render_click()

      assert html =~ "entry-comment-#{comment.id}"
      assert html =~ "entry-comment-#{routine_comment.id}"
      assert html =~ "Still reading through context."
    end

    test "comment form accepts input", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      form =
        form(view, "#comment-form", %{
          "comment" => %{
            "author_type" => "user",
            "author_id" => "new-author",
            "body" => "New comment body"
          }
        })

      assert form
    end

    test "comment templates prefill tagged owner-readable comments", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      html =
        view
        |> element("button[phx-value-template='delivery']")
        |> render_click()

      assert html =~ "[delivery]"
      assert html =~ "What happened:"
      assert html =~ "Files changed:"
      assert html =~ "Verification:"
      assert html =~ "Risks:"
    end

    test "resolve review gates loads delivery guidance", %{issue: issue} do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Digest actions"
      assert html =~ "Open raw timeline"
      assert html =~ "Resolve review gates"
      assert html =~ "Completion contract"
      assert html =~ "Engineer / delivery owner"
      assert html =~ "CTO / reviewer"
      assert html =~ "CEO / owner liaison"
      assert html =~ "Add completion note"
      assert html =~ "Attach work product"
      assert html =~ "Why this action?"
      assert html =~ "Shown because the Agent completion note gate is blocking this issue."
      assert html =~ "Signal view hides repetitive routine notes"

      html =
        view
        |> element("#issue-executive-digest button[phx-value-action='delivery_note']")
        |> render_click()

      assert html =~ "Delivery comment template loaded"
      assert html =~ "[delivery] What happened"
    end

    test "resolve review gates attaches work product evidence", %{issue: issue} do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Resolve review gates"
      assert html =~ "Attach work product"

      html =
        view
        |> element("#issue-executive-digest button[phx-value-action='work_product']")
        |> render_click()

      assert html =~ "Work product form opened"
      assert html =~ ~s(id="issue-work-product-form")
      assert html =~ "Attach artifact evidence"

      html =
        view
        |> form("#work-product-form", %{
          "work_product" => %{
            "title" => "Manual Evidence Bundle",
            "kind" => "url",
            "url" => "https://example.com/review-notes",
            "description" => "Reviewer-visible notes from the issue page."
          }
        })
        |> render_submit()

      assert html =~ "Work product attached"
      assert html =~ "Manual Evidence Bundle"
      refute html =~ "Attach a work product with"

      [work_product] = WorkProducts.list_work_products(issue.id)
      assert work_product.title == "Manual Evidence Bundle"
      assert work_product.kind == "url"
      assert work_product.url == "https://example.com/review-notes"
      assert work_product.metadata["source"] == "issue_show"
    end

    test "queues an auto-nudge for missing delivery evidence", %{issue: issue} do
      {:ok, engineer} =
        create_agent(%{
          name: "Delivery Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress,
          assigned_role: "engineer"
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Auto-nudges"
      assert html =~ "Digest actions"
      assert html =~ "Delivery Agent"
      assert html =~ "Nudge delivery owner"

      assert html =~
               "Shown because Delivery Agent is the best available owner for missing digest evidence."

      assert html =~ "Queue Delivery Agent with the missing evidence request."

      html =
        view
        |> element(
          "#issue-executive-digest button[phx-value-key='delivery:#{issue.id}:#{engineer.id}']"
        )
        |> render_click()

      assert html =~ "Auto-nudge queued for Delivery Agent"
      assert html =~ "Queued"
      assert html =~ "Ask for one tagged delivery note"

      updated = Issues.get_issue!(issue.id)
      assert updated.assignee_id == engineer.id
      assert Inbox.get_inbox_state(issue.id, engineer.id)
      assert [_wake | _] = Wakes.list_issue_wakes(issue.id)

      assert Enum.any?(Comments.list_comments(issue.id), fn comment ->
               comment.author_type == "system" and
                 comment.body =~ "Auto-nudge queued for Delivery Agent"
             end)
    end

    test "queues a contract nudge from the completion contract card", %{issue: issue} do
      {:ok, engineer} =
        create_agent(%{
          name: "Delivery Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress,
          assignee_id: engineer.id,
          assigned_role: "engineer"
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body: "[delivery] Done.",
          author_type: "agent",
          author_id: engineer.id,
          issue_id: issue.id
        })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: engineer.id,
          kind: "document",
          title: "Partial evidence",
          description: "Evidence exists, but the delivery comment needs the contract fields."
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Completion contract"
      assert html =~ "Nudge delivery contract"
      assert html =~ "Verification"

      html =
        view
        |> element(
          "#issue-executive-digest button[phx-value-contract='delivery_contract']",
          "Nudge delivery contract"
        )
        |> render_click()

      assert html =~ "Contract nudge queued for Delivery Agent"
      assert html =~ "Pending nudge for Delivery Agent"

      assert [wake] = Wakes.list_review_nudges([issue.id])
      assert wake.metadata["contract_key"] == "delivery_contract"
      assert "contract_delivery_contract" in wake.metadata["blocker_keys"]
    end

    test "queues PR quality nudge from the issue sidebar", %{issue: issue} do
      {:ok, engineer} =
        create_agent(%{
          name: "PR Repair Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress,
          assignee_id: engineer.id,
          assigned_role: "engineer",
          github_pr_url: "https://github.com/acme/app/pull/42",
          monitor_state: %{
            "pr_quality" => %{
              "status" => "attention",
              "status_label" => "Needs PR fixes",
              "summary" => "2 PR contract gaps need fixes.",
              "gaps" => [
                %{"label" => "Branch name", "detail" => "Expected branch to include CYM-7."}
              ]
            }
          }
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Needs PR fixes"
      assert html =~ "Nudge agent to fix PR"
      assert html =~ "PR repair packet"
      assert html =~ "Expected branch"
      assert html =~ "Expected title"
      assert html =~ "gh pr edit https://github.com/acme/app/pull/42"
      assert html =~ "PR body template"

      html =
        view
        |> element("#issue-github-pr button[phx-value-contract='pr_quality']")
        |> render_click()

      assert html =~ "Contract nudge queued for PR Repair Agent"

      assert [wake] = Wakes.list_review_nudges([issue.id])
      assert wake.metadata["contract_key"] == "pr_quality"
      assert "pr_quality" in wake.metadata["blocker_keys"]
    end

    test "shows satisfied review nudge after evidence clears it", %{issue: issue} do
      {:ok, cto} =
        create_agent(%{
          name: "Review Captain",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, agent} =
        create_agent(%{
          name: "Delivery Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_review
        })

      {:ok, _delivery_comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered the work. Files changed: review evidence. Evidence produced: review evidence artifact and completed runtime. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review. Restart packet: CTO should inspect the review evidence artifact and completed runtime.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Review evidence",
          description: "Evidence for review."
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Nudge CTO review"

      view
      |> element(
        "#issue-executive-digest button[phx-value-key='cto_review:#{issue.id}:#{cto.id}']"
      )
      |> render_click()

      assert [_pending] = Wakes.list_review_nudges([issue.id])

      {:ok, _review_comment} =
        Comments.create_comment(%{
          body:
            "[review] Verdict: accepted. What happened: evidence accepted. Evidence inspected: delivery note, run, and work product. Verification: passed. Gaps: none. Follow-up issues: none. Next decision: close. Restart packet: CEO should inspect the accepted review, run, and work product before closing.",
          author_type: "agent",
          author_id: cto.id,
          issue_id: issue.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert [] = Wakes.list_review_nudges([issue.id])
      assert html =~ "Review nudges satisfied"
      assert html =~ "Cleared"
      assert html =~ "CTO/CEO review decision"
    end

    test "next owner strip points missing artifact work at assignee", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Evidence Owner",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress,
          assignee_id: agent.id
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered reviewable work. Files changed: reviewable evidence. Evidence produced: reviewable evidence artifact and completed runtime. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review. Restart packet: CTO should inspect the reviewable evidence artifact and completed runtime.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Next owner"
      assert html =~ "Evidence Owner"
      assert html =~ "Engineer"
      assert html =~ "Work product"
      assert html =~ "Attach work product"
      assert html =~ "should attach a work product"
    end

    test "review gate query opens work product resolver", %{issue: issue} do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}?gate=work_product")

      assert html =~ "Work product form opened"
      assert html =~ ~s(id="issue-work-product-form")
      assert html =~ ~s(data-clean-url="/issues/#{issue.id}#issue-work-product-form")
      assert html =~ "Attach artifact evidence"
    end

    test "review gate query preloads comment resolver", %{issue: issue} do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_progress
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}?gate=delivery_note")

      assert html =~ "Delivery comment template loaded"
      assert html =~ ~s(data-clean-url="/issues/#{issue.id}#issue-comments")
      assert html =~ "[delivery] What happened"
    end

    test "resolve review gates loads review guidance when only approval is missing", %{
      issue: issue
    } do
      {:ok, _cto} =
        create_agent(%{
          name: "Review Captain",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, agent} =
        create_agent(%{
          name: "Review Helper Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Owner request is clear.",
          status: :in_review
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered reviewable work. Files changed: reviewable evidence. Evidence produced: reviewable evidence artifact and completed runtime. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review. Restart packet: CTO should inspect the reviewable evidence artifact and completed runtime.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Reviewable evidence",
          description: "Non-code evidence."
        })

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Resolve review gates"
      assert html =~ "Next owner"
      assert html =~ "Review Captain"
      assert html =~ "CTO"
      assert html =~ "CTO/CEO review decision"
      assert html =~ "Add review comment"

      html =
        view
        |> element("#issue-next-owner button[phx-value-action='review_comment']")
        |> render_click()

      assert html =~ "Review comment template loaded"
      assert html =~ "[review] Verdict"
    end

    test "comment form submits with server-side owner defaults", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")
      current_user_id = :sys.get_state(view.pid).socket.assigns.current_user.id

      view
      |> form("#comment-form", %{
        "comment" => %{
          "body" => "[owner_update] What happened: owner posted a status update."
        }
      })
      |> render_submit()

      [comment] = Comments.list_comments(issue.id)
      assert comment.author_type == "user"
      assert comment.author_id == current_user_id
      assert comment.body =~ "[owner_update]"
    end

    @tag membership_role: "admin"
    test "issue runtime can be paused and resumed from the issue page", %{issue: issue} do
      {:ok, issue} = Issues.update_issue(issue, %{status: :todo})

      {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Agents"
      assert html =~ "Pause just this issue if a run gets stuck."
      assert html =~ ~s(aria-label="Pause agents")

      html =
        view
        |> element("button[phx-click='pause_issue_runtime']")
        |> render_click()

      assert html =~ "Issue paused"
      assert html =~ "Paused"
      assert html =~ "Paused — nothing new starts until you resume."
      assert html =~ ~s(aria-label="Resume agents")
      assert Issues.issue_runtime_paused?(Issues.get_issue!(issue.id))

      {events, _total} =
        AuditTrail.list_company_events(current_company_id(),
          event_type: "issue_runtime_paused",
          resource_type: "issue",
          resource_id: issue.id
        )

      assert Enum.any?(events, &(&1.resource_id == issue.id))

      html =
        view
        |> element("button[phx-click='resume_issue_runtime']")
        |> render_click()

      assert html =~ "Issue resumed"
      refute Issues.issue_runtime_paused?(Issues.get_issue!(issue.id))

      {events, _total} =
        AuditTrail.list_company_events(current_company_id(),
          event_type: "issue_runtime_resumed",
          resource_type: "issue",
          resource_id: issue.id
        )

      assert Enum.any?(events, &(&1.resource_id == issue.id))
    end
  end

  describe "Show - Inline Title Edit" do
    test "shows edit button for title", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "start_editing"
      assert html =~ ~s(field="title")
    end

    test "enters edit mode and saves title", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='title']")
      |> render_click()

      assert render(view) =~ "Save"
      assert render(view) =~ "Cancel"

      view
      |> form("form[phx-submit='save_title']", %{"title" => "Updated Title"})
      |> render_submit()

      assert render(view) =~ "Updated Title"
      assert render(view) =~ "Title updated"
    end

    test "rejects empty title", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='title']")
      |> render_click()

      view
      |> form("form[phx-submit='save_title']", %{"title" => "   "})
      |> render_submit()

      assert render(view) =~ "Title cannot be empty"
    end

    test "cancels title editing", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='title']")
      |> render_click()

      assert render(view) =~ "Cancel"

      view
      |> element("button[phx-click='cancel_editing']")
      |> render_click()

      refute render(view) =~ ~s(phx-submit="save_title")
    end
  end

  describe "Show - Inline Description Edit" do
    test "opens description editor from edit query param", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}?edit=description")

      assert html =~ ~s(phx-submit="save_description")
      assert html =~ "Test description for the issue"
      refute html =~ ~s(phx-click="start_editing" phx-value-field="description")
    end

    test "opens owner brief repair scaffold from query param", %{issue: issue} do
      {:ok, issue} = Issues.update_issue(issue, %{title: "Improve onboarding quality"})

      {:ok, _view, html} =
        live(conn(), "/issues/#{issue.id}?edit=description&repair=owner_brief")

      assert html =~ ~s(phx-submit="save_description")

      description = textarea_value(html, "textarea[name='description']")
      assert description =~ "Goal: Improve onboarding quality"
      assert description =~ "Definition of done:"
      assert description =~ "CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`):"
      assert description =~ "Missing signals:"
      refute description =~ "Test description for the issue"
    end

    test "returns to operations checklist after saving owner brief repair", %{issue: issue} do
      return_to = "/operations#runtime-launch-checklist"
      encoded_return_to = URI.encode_www_form(return_to)

      {:ok, view, _html} =
        live(
          conn(),
          "/issues/#{issue.id}?edit=description&repair=owner_brief&return_to=#{encoded_return_to}"
        )

      description = """
      Goal: Improve onboarding quality for trial users.
      Context: Activation drops when setup has no clear next step.
      Risk/constraint: Keep the launch cheap and observable before building more automation.
      Definition of done: CEO hands off a scoped onboarding fix with acceptance criteria.
      CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`): `[handoff]` to CTO with split tasks.
      Evidence: Use onboarding completion, first issue created, and runtime launch notes.
      """

      assert {:error, {:live_redirect, %{to: ^return_to}}} =
               view
               |> form("form[phx-submit='save_description']", %{"description" => description})
               |> render_submit()

      assert {:ok, updated} = Issues.get_issue(issue.id)
      assert updated.description == description
    end

    test "ignores unsafe owner brief repair return paths", %{issue: issue} do
      encoded_return_to = URI.encode_www_form("https://evil.example/issues")

      {:ok, view, _html} =
        live(
          conn(),
          "/issues/#{issue.id}?edit=description&repair=owner_brief&return_to=#{encoded_return_to}"
        )

      html =
        view
        |> form("form[phx-submit='save_description']", %{
          "description" => "Updated description without unsafe redirect"
        })
        |> render_submit()

      assert is_binary(html)
      assert html =~ "Description updated"

      assert {:ok, updated} = Issues.get_issue(issue.id)
      assert updated.description == "Updated description without unsafe redirect"
    end

    test "enters edit mode and saves description", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='description']")
      |> render_click()

      assert render(view) =~ ~s(phx-submit="save_description")

      view
      |> form("form[phx-submit='save_description']", %{"description" => "New description"})
      |> render_submit()

      assert render(view) =~ "New description"
      assert render(view) =~ "Description updated"
    end
  end

  describe "Show - Status Combobox" do
    test "shows status combobox with valid transitions", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "combobox_status"
      # backlog can transition to todo, in_progress, blocked
      assert html =~ ~s(data-combobox-id="todo")
      assert html =~ ~s(data-combobox-id="in_progress")
      assert html =~ ~s(data-combobox-id="blocked")
    end

    test "valid status transition succeeds", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "todo"})

      assert render(view) =~ "Status updated to todo"

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :todo
    end

    test "invalid status transition shows error", %{issue: _issue} do
      {:ok, issue} =
        create_issue(%{
          title: "Done Issue",
          description: "Test",
          status: :backlog
        })

      # backlog -> done is not a valid direct transition
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "done"})

      assert render(view) =~ "Invalid transition"
    end

    test "review gates block moving to review without delivery evidence" do
      {:ok, issue} =
        create_issue(%{
          title: "Needs evidence before review",
          description: "Owner request is clear.",
          status: :todo,
          priority: :medium
        })

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "in_review"})

      html = render(view)
      assert html =~ "Review gates blocking status change"
      assert html =~ "Runtime verification"
      assert html =~ "Agent completion note"
      assert Issues.get_issue!(issue.id).status == :todo
    end

    test "review gates allow moving to review once delivery evidence exists" do
      {:ok, agent} =
        create_agent(%{
          name: "Evidence Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Evidence ready",
          description: "Owner request is clear.",
          status: :in_progress,
          priority: :medium
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered the reviewable work. Files changed: review evidence. Evidence produced: review evidence artifact and completed runtime. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review. Restart packet: CTO should inspect the review evidence artifact and completed runtime.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Review evidence",
          description: "Non-code review evidence."
        })

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "in_review"})

      assert render(view) =~ "Status updated to in_review"
      assert Issues.get_issue!(issue.id).status == :in_review
    end

    test "approval gates block closing without CTO or CEO review decision" do
      {:ok, agent} =
        create_agent(%{
          name: "Delivery Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} =
        create_issue(%{
          title: "Cannot close yet",
          description: "Owner request is clear.",
          status: :in_progress,
          priority: :medium
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered the work. Files changed: closure evidence. Evidence produced: closure evidence artifact and completed runtime. Verification: runtime passed. Risks: none known. Current state: ready for review. Next decision: CTO review. Restart packet: CTO should inspect the closure evidence artifact and completed runtime.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        company_id: issue.company_id,
        status: "completed",
        adapter: "process",
        continuation_summary: "Verification passed."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "document",
          title: "Closure evidence",
          description: "Non-code closure evidence."
        })

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "done"})

      html = render(view)
      assert html =~ "Approval gates blocking closure"
      assert html =~ "CTO/CEO review decision"
      assert Issues.get_issue!(issue.id).status == :in_progress
    end
  end

  describe "Show - Priority Combobox" do
    test "shows priority combobox", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "combobox_priority"
      assert html =~ ~s(data-combobox-id="low")
      assert html =~ ~s(data-combobox-id="medium")
      assert html =~ ~s(data-combobox-id="high")
    end

    test "priority change succeeds", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-priority-combobox")
      |> render_hook("combobox_priority", %{"selected" => "low"})

      assert render(view) =~ "Priority updated"

      updated = Issues.get_issue!(issue.id)
      assert updated.priority == :low
    end
  end

  describe "Show - Assignee Management" do
    test "shows assignee combobox when no assignee", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "combobox_assignee"
      assert html =~ "Unassigned"
    end

    test "assigns an agent to the issue", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-assignee-combobox")
      |> render_hook("combobox_assignee", %{"selected" => agent.id})

      html = render(view)
      assert html =~ "Test Agent"
      assert html =~ "Assignee updated"

      updated = Issues.get_issue!(issue.id)
      assert updated.assignee_id == agent.id
    end

    test "unassigns an agent from the issue", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Remove Me",
          role: :engineer,
          status: :running
        })

      {:ok, _} = Issues.update_issue(issue, %{assignee_id: agent.id})

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      html = render(view)
      assert html =~ "Remove Me"

      view
      |> element("#issue-assignee-combobox")
      |> render_hook("combobox_assignee", %{"selected" => nil})

      html = render(view)
      assert html =~ "Assignee removed"

      updated = Issues.get_issue!(issue.id)
      assert updated.assignee_id == nil
    end

    test "shows agent status badge when assigned", %{issue: issue} do
      {:ok, agent} =
        create_agent(%{
          name: "Busy Agent",
          role: :cto,
          status: :running
        })

      {:ok, _} = Issues.update_issue(issue, %{assignee_id: agent.id})

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Busy Agent"
    end
  end

  defp html_has_any?(html, labels) do
    Enum.any?(labels, &String.contains?(html, &1))
  end

  defp worker_role_labels do
    [
      "Product Manager",
      "Designer",
      "Researcher",
      "Marketer",
      "Content Strategist",
      "Sales Development",
      "Customer Support"
    ]
  end

  defp worker_lens_labels do
    [
      "Market and prioritization",
      "User journey and usability",
      "Evidence and uncertainty",
      "Positioning and demand",
      "Narrative and information architecture",
      "Buyer objections and qualification",
      "Support burden and failure modes"
    ]
  end
end
