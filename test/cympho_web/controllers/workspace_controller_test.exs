defmodule CymphoWeb.WorkspaceControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Projects
  alias Cympho.Workspaces

  setup %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn)
    unique = System.unique_integer([:positive])

    {:ok, project} =
      Projects.create_project(%{
        name: "Workspace API Project #{unique}",
        prefix: project_prefix("WA", unique),
        company_id: company.id
      })

    {:ok, workspace} =
      Workspaces.create_project_workspace(%{
        name: "API project workspace #{unique}",
        company_id: company.id,
        project_id: project.id
      })

    {:ok, execution_workspace} =
      Workspaces.create_execution_workspace(%{
        name: "API exec workspace #{unique}",
        status: "open",
        company_id: company.id,
        project_id: project.id,
        project_workspace_id: workspace.id
      })

    %{
      conn: conn,
      company: company,
      project: project,
      workspace: workspace,
      execution_workspace: execution_workspace,
      unique: unique
    }
  end

  test "GET /api/workspaces/:id/exec-workspaces returns 200 for a found record", %{
    conn: conn,
    workspace: workspace,
    execution_workspace: execution_workspace
  } do
    conn = get(conn, "/api/workspaces/#{workspace.id}/exec-workspaces?status=open")
    assert %{"data" => data} = json_response(conn, 200)
    assert Enum.any?(data, fn row -> row["id"] == execution_workspace.id end)
  end

  test "GET /api/exec-workspaces/:id/operations returns 200 for a found record", %{
    conn: conn,
    company: company,
    execution_workspace: execution_workspace
  } do
    {:ok, _operation} =
      Workspaces.create_operation(%{
        phase: "launch",
        status: "completed",
        company_id: company.id,
        execution_workspace_id: execution_workspace.id
      })

    conn = get(conn, "/api/exec-workspaces/#{execution_workspace.id}/operations?limit=10")
    assert %{"data" => data} = json_response(conn, 200)
    assert is_list(data)
    assert length(data) >= 1
  end

  test "DELETE /api/exec-workspaces/:id returns 200", %{
    conn: conn,
    execution_workspace: execution_workspace
  } do
    conn = delete(conn, "/api/exec-workspaces/#{execution_workspace.id}")
    assert %{"data" => data} = json_response(conn, 200)
    assert data["id"] == execution_workspace.id
    assert data["status"] == "closed"
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
