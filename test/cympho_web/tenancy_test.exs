defmodule CymphoWeb.TenancyTest do
  @moduledoc """
  Regression net for cross-tenant data leakage in LiveView mounts.

  Each test creates a record in company B, then mounts a LiveView as a user
  who only belongs to company A. The LiveView must redirect away (typically
  to the index page for that resource) — never render the cross-company
  record's data.

  When adding a new LiveView that loads a record by ID, add a case here.
  """

  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.{
    Agents,
    Budgets,
    Companies,
    Inbox,
    Issues,
    Plugins,
    Projects,
    Repo,
    Secrets,
    Skills
  }

  alias Cympho.Users.User

  setup do
    {:ok, company_a} =
      Companies.create_company(%{
        name: "Company A",
        slug: "company-a-#{System.unique_integer([:positive])}"
      })

    {:ok, company_b} =
      Companies.create_company(%{
        name: "Company B",
        slug: "company-b-#{System.unique_integer([:positive])}"
      })

    {:ok, user_a} =
      %User{}
      |> User.registration_changeset(%{
        email: "user_a-#{System.unique_integer([:positive])}@example.com",
        name: "User A",
        password: "password123",
        company_id: company_a.id
      })
      |> Repo.insert()

    Companies.create_membership!(%{
      user_id: user_a.id,
      company_id: company_a.id,
      role: "member"
    })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session("user_id", user_a.id)
      |> Plug.Conn.put_session("company_id", company_a.id)

    %{conn: conn, company_a: company_a, company_b: company_b, user_a: user_a}
  end

  describe "ProjectLive.Show" do
    test "redirects when project belongs to another company", %{
      conn: conn,
      company_b: company_b
    } do
      {:ok, project} =
        Projects.create_project(%{
          name: "B's secret project",
          prefix: "BSEC#{<<Enum.random(?A..?Z)>>}",
          company_id: company_b.id
        })

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, "/projects/#{project.id}")
    end

    test "does not delete env vars from another company", %{
      conn: conn,
      company_a: company_a,
      company_b: company_b
    } do
      {:ok, project_a} =
        Projects.create_project(%{
          name: "A's project",
          prefix: "AENV",
          company_id: company_a.id
        })

      {:ok, project_b} =
        Projects.create_project(%{
          name: "B's project",
          prefix: "BENV",
          company_id: company_b.id
        })

      {:ok, secret_b} =
        Secrets.create_secret(%{
          company_id: company_b.id,
          scope: "project",
          scope_id: project_b.id,
          key: "SECRET_B",
          value: "do-not-delete"
        })

      {:ok, view, _html} = live(conn, "/projects/#{project_a.id}")

      render_click(view, "delete_env", %{"id" => secret_b.id})

      assert {:ok, reloaded} = Secrets.get_secret(secret_b.id)
      assert reloaded.is_active
    end
  end

  describe "IssueLive.Show" do
    test "redirects when issue belongs to another company", %{
      conn: conn,
      company_b: company_b
    } do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "B's issue",
          status: :todo,
          company_id: company_b.id
        })

      assert {:error, {:live_redirect, %{to: "/issues"}}} =
               live(conn, "/issues/#{issue.id}")
    end

    test "does not assign an issue to another company's agent", %{
      conn: conn,
      company_a: company_a,
      company_b: company_b
    } do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "A's issue",
          status: :todo,
          company_id: company_a.id
        })

      {:ok, agent_b} =
        Agents.create_agent(%{
          name: "B's agent",
          role: :engineer,
          status: :idle,
          company_id: company_b.id,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, view, _html} = live(conn, "/issues/#{issue.id}")

      assert view
             |> element("#issue-assignee-combobox")
             |> render_hook("combobox_assignee", %{"selected" => agent_b.id}) =~ "Agent not found"

      assert is_nil(Issues.get_issue!(issue.id).assignee_id)
    end
  end

  describe "AgentLive" do
    test "show redirects when agent belongs to another company", %{
      conn: conn,
      company_b: company_b
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "B's agent",
          role: :engineer,
          status: :idle,
          company_id: company_b.id,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      assert {:error, {:live_redirect, %{to: "/agents"}}} =
               live(conn, "/agents/#{agent.id}")
    end

    test "index ignores forged delete events for another company's agent", %{
      conn: conn,
      company_b: company_b
    } do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "B's protected agent",
          role: :engineer,
          status: :idle,
          company_id: company_b.id,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, view, _html} = live(conn, "/agents")

      render_click(view, "delete_agent", %{"id" => agent.id})

      assert {:ok, _agent} = Agents.get_agent(agent.id)
    end
  end

  describe "KanbanLive.Index" do
    test "ignores forged transitions for another company's issue", %{
      conn: conn,
      company_b: company_b
    } do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "B's kanban issue",
          status: :todo,
          company_id: company_b.id
        })

      {:ok, view, _html} = live(conn, "/kanban")

      assert view
             |> element("#kanban-board")
             |> render_hook("transition_issue", %{"id" => issue.id, "to_status" => "done"}) =~
               "Issue not found"

      assert Issues.get_issue!(issue.id).status == :todo
    end
  end

  describe "InboxLive.Index" do
    test "falls back to company inbox when agent_id belongs to another company", %{
      conn: conn,
      company_b: company_b
    } do
      {:ok, issue_b} =
        Issues.create_issue(%{
          title: "B's inbox issue",
          status: :todo,
          company_id: company_b.id
        })

      {:ok, agent_b} =
        Agents.create_agent(%{
          name: "B's inbox agent",
          role: :engineer,
          status: :idle,
          company_id: company_b.id,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, _state} = Inbox.ensure_inbox_entry(issue_b.id, agent_b.id)

      {:ok, _view, html} = live(conn, "/inbox?agent_id=#{agent_b.id}")

      assert html =~ "Inbox"
      refute html =~ "B's inbox issue"
      refute html =~ "B's inbox agent"
    end
  end

  describe "OperationsLive.Index" do
    test "ignores forged contract nudges for another company's issue", %{
      conn: conn,
      company_b: company_b
    } do
      {:ok, issue_b} =
        Issues.create_issue(%{
          title: "B's operations issue",
          status: :in_progress,
          company_id: company_b.id
        })

      {:ok, view, _html} = live(conn, "/operations")

      render_click(view, "queue_contract_nudge", %{
        "issue-id" => issue_b.id,
        "contract" => "delivery_contract"
      })

      assert [] = Cympho.Wakes.list_review_nudges([issue_b.id])
    end
  end

  describe "BudgetLive.Show" do
    test "redirects when budget belongs to another company", %{
      conn: conn,
      company_b: company_b
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, budget} =
        Budgets.create_budget(%{
          name: "B's budget",
          scope_type: "company",
          scope_id: company_b.id,
          limit_amount: Decimal.new(1000),
          period_start: now,
          period_end: DateTime.add(now, 30 * 24 * 3600, :second),
          status: "active",
          company_id: company_b.id
        })

      # Live.BoardAuth catches this first when no board members exist (redirects
      # to "/"), otherwise BudgetLive.Show's tenancy check redirects to "/budgets".
      # Either is a valid denial — what matters is no render of B's data.
      result = live(conn, "/budgets/#{budget.id}")

      assert match?({:error, {:live_redirect, %{to: "/budgets"}}}, result) or
               match?({:error, {:redirect, %{to: "/"}}}, result),
             "expected a redirect away from cross-tenant budget, got: #{inspect(result)}"
    end
  end

  describe "SkillLive.Show" do
    test "redirects when skill belongs to another company", %{
      conn: conn,
      company_b: company_b
    } do
      {:ok, skill} =
        Skills.create_skill(%{
          name: "B's skill",
          identifier: "b-skill-#{System.unique_integer([:positive])}",
          manifest: %{},
          company_id: company_b.id
        })

      assert {:error, {:live_redirect, %{to: "/skills"}}} = live(conn, "/skills/#{skill.id}")
    end
  end

  describe "PluginLive.Show" do
    test "redirects when plugin belongs to another company", %{
      conn: conn,
      company_b: company_b
    } do
      {:ok, plugin} =
        Plugins.create_plugin(%{
          name: "B's plugin",
          identifier: "b-plugin-#{System.unique_integer([:positive])}",
          version: "1.0.0",
          manifest: %{},
          company_id: company_b.id
        })

      assert {:error, {:live_redirect, %{to: "/plugins"}}} =
               live(conn, "/plugins/#{plugin.id}")
    end
  end

  describe "guest user (no session)" do
    test "is redirected before tenant data can be inspected", %{
      company_a: _a,
      company_b: _b
    } do
      conn = build_conn() |> Plug.Test.init_test_session(%{})

      assert {:error, {:redirect, %{to: "/login?return_to=%2Fissues"}}} =
               live(conn, "/issues")
    end
  end
end
