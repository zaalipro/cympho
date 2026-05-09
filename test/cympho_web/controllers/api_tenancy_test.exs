defmodule CymphoWeb.ApiTenancyTest do
  use CymphoWeb.ConnCase, async: true

  import Ecto.Query

  alias Cympho.Agents
  alias Cympho.Approvals.Approval
  alias Cympho.Companies
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Projects
  alias Cympho.Repo
  alias Cympho.Routines.Routine
  alias Cympho.Workspaces

  setup %{conn: conn} do
    {conn, user, company} = register_and_log_in_user(conn)
    unique = System.unique_integer([:positive])

    {:ok, project} =
      Projects.create_project(%{
        name: "API Project #{unique}",
        prefix: project_prefix("AP", unique),
        company_id: company.id
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "API Agent #{unique}",
        role: :engineer,
        company_id: company.id,
        url_key: "api-agent-#{unique}"
      })

    {:ok, other_company} =
      Companies.create_company(%{
        name: "Other API Co #{unique}",
        slug: "other-api-co-#{unique}"
      })

    {:ok, other_project} =
      Projects.create_project(%{
        name: "Other API Project #{unique}",
        prefix: project_prefix("OP", unique),
        company_id: other_company.id
      })

    {:ok, other_agent} =
      Agents.create_agent(%{
        name: "Other API Agent #{unique}",
        role: :engineer,
        company_id: other_company.id,
        url_key: "other-api-agent-#{unique}"
      })

    {:ok, other_issue} =
      Issues.create_issue(%{
        title: "Other API Issue #{unique}",
        project_id: other_project.id,
        company_id: other_company.id
      })

    %{
      conn: conn,
      user: user,
      company: company,
      project: project,
      agent: agent,
      other_company: other_company,
      other_project: other_project,
      other_agent: other_agent,
      other_issue: other_issue,
      unique: unique
    }
  end

  test "browser quick-create ignores forged session company ids", %{
    conn: conn,
    other_company: other_company,
    unique: unique
  } do
    title = "Forged browser issue #{unique}"

    conn =
      conn
      |> put_session(:company_id, other_company.id)
      |> post(~p"/issues/quick-create", %{"title" => title})

    assert redirected_to(conn) == ~p"/issues"
    refute Repo.exists?(from i in Issue, where: i.title == ^title)
  end

  test "accepting an invite requires API authentication", %{conn: _conn} do
    conn = post(build_conn(), ~p"/api/invites/fake-token/accept")
    assert %{"errors" => [%{"detail" => "Authentication required"}]} = json_response(conn, 401)
  end

  test "issue create rejects cross-company project and assignee references", %{
    conn: conn,
    other_project: other_project,
    other_agent: other_agent,
    unique: unique
  } do
    title = "Cross-company API issue #{unique}"

    conn =
      post(conn, ~p"/api/issues", %{
        "issue" => %{
          "title" => title,
          "project_id" => other_project.id,
          "assignee_id" => other_agent.id
        }
      })

    assert json_response(conn, 404)
    refute Repo.exists?(from i in Issue, where: i.title == ^title)
  end

  test "routine create rejects cross-company agent references", %{
    conn: conn,
    other_agent: other_agent,
    unique: unique
  } do
    name = "Cross-company routine #{unique}"

    conn =
      post(conn, ~p"/api/routines", %{
        "routine" => %{"name" => name, "agent_id" => other_agent.id}
      })

    assert json_response(conn, 404)
    refute Repo.exists?(from r in Routine, where: r.name == ^name)
  end

  test "workspace API hides project workspaces from other companies", %{
    conn: conn,
    other_company: other_company,
    other_project: other_project,
    unique: unique
  } do
    {:ok, workspace} =
      Workspaces.create_project_workspace(%{
        name: "Other workspace #{unique}",
        project_id: other_project.id,
        company_id: other_company.id
      })

    conn = get(conn, ~p"/api/workspaces/#{workspace.id}")
    assert json_response(conn, 404)
  end

  test "workspace API does not start runtime services from other companies", %{
    conn: conn,
    other_company: other_company,
    other_project: other_project,
    unique: unique
  } do
    {:ok, workspace} =
      Workspaces.create_project_workspace(%{
        name: "Other runtime workspace #{unique}",
        project_id: other_project.id,
        company_id: other_company.id
      })

    {:ok, execution_workspace} =
      Workspaces.create_execution_workspace(%{
        name: "Other execution workspace #{unique}",
        project_id: other_project.id,
        company_id: other_company.id,
        project_workspace_id: workspace.id
      })

    {:ok, service} =
      Workspaces.create_runtime_service(%{
        service_name: "Other service #{unique}",
        status: "stopped",
        company_id: other_company.id,
        project_id: other_project.id,
        project_workspace_id: workspace.id,
        execution_workspace_id: execution_workspace.id
      })

    conn = patch(conn, ~p"/api/services/#{service.id}/start")
    assert json_response(conn, 404)

    {:ok, service} = Workspaces.get_runtime_service(service.id)
    assert service.status == "stopped"
  end

  test "preview API hides runtime services from other companies", %{
    conn: conn,
    other_company: other_company,
    other_project: other_project,
    unique: unique
  } do
    {:ok, workspace} =
      Workspaces.create_project_workspace(%{
        name: "Other preview workspace #{unique}",
        project_id: other_project.id,
        company_id: other_company.id
      })

    {:ok, execution_workspace} =
      Workspaces.create_execution_workspace(%{
        name: "Other preview execution workspace #{unique}",
        project_id: other_project.id,
        company_id: other_company.id,
        project_workspace_id: workspace.id
      })

    {:ok, service} =
      Workspaces.create_runtime_service(%{
        service_name: "Other preview service #{unique}",
        status: "running",
        port: 4000,
        company_id: other_company.id,
        project_id: other_project.id,
        project_workspace_id: workspace.id,
        execution_workspace_id: execution_workspace.id
      })

    conn = get(conn, ~p"/api/preview/#{service.id}")
    assert json_response(conn, 404)
  end

  test "approval create rejects cross-company agents and issues", %{
    conn: conn,
    other_agent: other_agent,
    other_issue: other_issue
  } do
    conn =
      post(conn, ~p"/api/approvals", %{
        "approval" => %{
          "type" => "release",
          "requested_by_agent_id" => other_agent.id,
          "issue_ids" => [other_issue.id]
        }
      })

    assert json_response(conn, 404)
    refute Repo.exists?(from a in Approval, where: a.requested_by_agent_id == ^other_agent.id)
  end

  defp project_prefix(base, unique) do
    suffix =
      unique
      |> Integer.digits(26)
      |> Enum.map_join(fn digit -> <<?A + digit>> end)
      |> String.slice(0, 8)

    base <> suffix
  end
end
