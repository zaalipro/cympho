defmodule CymphoWeb.CompanyRBACLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.{
    Agents,
    Authentication,
    Companies,
    ExecutionPolicies,
    Inbox,
    Issues,
    Labels,
    Skills
  }

  test "viewer LiveView events are read-only", %{conn: _setup_conn} do
    conn = authenticated_conn(%{role: "viewer"})
    company = current_company()
    {:ok, view, html} = live(conn, "/labels")

    assert html =~ "Labels"

    html =
      view
      |> form("form", label: %{name: "Forbidden label", color: "#112233"})
      |> render_submit()

    assert html =~ "Your company role does not allow that action."
    assert Labels.list_labels_by_company(company.id) == []
  end

  test "member cannot trigger destructive LiveView events", %{conn: _setup_conn} do
    conn = authenticated_conn(%{role: "member"})
    company = current_company()

    {:ok, label} =
      Labels.create_label(%{name: "Protected label", color: "#112233", company_id: company.id})

    {:ok, view, _html} = live(conn, "/labels")
    html = render_click(view, "delete_label", %{"id" => label.id})

    assert html =~ "Your company role does not allow that action."
    assert {:ok, _label} = Labels.get_company_label(company.id, label.id)
  end

  test "an open LiveView honors a role demotion", %{conn: _setup_conn} do
    conn = authenticated_conn(%{role: "admin"})
    company = current_company()
    [membership] = Companies.list_memberships(company.id)

    {:ok, label} =
      Labels.create_label(%{name: "Demotion guard", color: "#112233", company_id: company.id})

    {:ok, view, _html} = live(conn, "/labels")
    {:ok, _membership} = Companies.update_membership(membership, %{role: "viewer"})

    html = render_click(view, "delete_label", %{"id" => label.id})

    assert html =~ "Your company role does not allow that action."
    assert {:ok, _label} = Labels.get_company_label(company.id, label.id)
  end

  test "viewer cannot create skills", %{conn: _setup_conn} do
    conn = authenticated_conn(%{role: "viewer"})
    company = current_company()
    identifier = "forbidden_skill_#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, "/skills/new")

    _html =
      render_submit(view, "save", %{
        "skill" => %{
          "name" => "Forbidden skill",
          "identifier" => identifier,
          "version" => "1.0.0",
          "entrypoint" => "Cympho.Skills.Forbidden"
        }
      })

    assert {:error, :not_found} = Skills.get_skill_by_identifier(identifier, company.id)
  end

  test "company deletion remains owner-only in LiveView", %{conn: _setup_conn} do
    conn = authenticated_conn(%{role: "admin"})
    company = current_company()
    {:ok, view, html} = live(conn, "/companies")

    refute html =~ ~s(aria-label="Delete #{company.name}")

    html = render_click(view, "delete_company", %{"id" => company.id})

    assert html =~ "Company not found or you cannot manage it."
    assert Companies.get_company!(company.id).id == company.id
  end

  test "members cannot mutate integrations, agent configuration, or execution policies", %{
    conn: conn,
    current_company: company
  } do
    {:ok, mcp_agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Protected MCP Agent",
        role: :ceo,
        status: :idle
      })

    {:ok, integrations, _html} = live(conn, "/settings/integrations")

    _html =
      render_submit(integrations, "create_mcp_key", %{
        "mcp_key" => %{"agent_id" => mcp_agent.id, "name" => "Forbidden member key"}
      })

    assert forbidden_flash(integrations)
    assert Authentication.list_agent_api_keys(mcp_agent.id) == []

    {:ok, policies, _html} = live(conn, "/settings/policies/new")

    _html =
      render_submit(policies, "save", %{
        "execution_policy" => %{
          "name" => "Forbidden member policy",
          "stage_configs" => "[]"
        }
      })

    assert forbidden_flash(policies)
    assert ExecutionPolicies.list_execution_policies(company.id) == []

    {:ok, agents, _html} = live(conn, "/agents/new")

    _html =
      render_submit(agents, "save", %{
        "agent" => %{
          "name" => "Forbidden member agent",
          "role" => "engineer",
          "adapter" => "process"
        }
      })

    assert forbidden_flash(agents)

    refute Enum.any?(
             Agents.list_agents_by_company(company.id),
             &(&1.name == "Forbidden member agent")
           )
  end

  test "member inbox archive and restore remain ordinary writes", %{
    conn: conn,
    current_company: company
  } do
    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Member Inbox Agent",
        role: :engineer,
        status: :idle
      })

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "Member inbox lifecycle",
        status: :todo,
        assignee_id: agent.id
      })

    {:ok, _state} = Inbox.ensure_inbox_entry(issue.id, agent.id)
    {:ok, view, _html} = live(conn, "/inbox?agent_id=#{agent.id}&status=unread")

    render_click(view, "archive", %{"issue_id" => issue.id, "agent_id" => agent.id})
    assert Inbox.get_inbox_state(issue.id, agent.id).status == "archived"

    render_click(view, "restore", %{"issue_id" => issue.id, "agent_id" => agent.id})
    assert Inbox.get_inbox_state(issue.id, agent.id).status == "unread"
  end

  test "membership removal disconnects a mounted company LiveView", %{
    conn: conn,
    current_company: company
  } do
    user_id = Plug.Conn.get_session(conn, :user_id)
    membership = Companies.get_membership(user_id, company.id)
    {:ok, view, _html} = live(conn, "/labels")

    assert {:ok, _membership} = Companies.delete_membership(membership)
    send(view.pid, :fresh_company_authority_probe)

    assert_redirect(view, "/")
  end

  defp forbidden_flash(view) do
    view.pid
    |> :sys.get_state()
    |> then(&Phoenix.Flash.get(&1.socket.assigns.flash, :error))
    |> Kernel.==("Your company role does not allow that action.")
  end
end
