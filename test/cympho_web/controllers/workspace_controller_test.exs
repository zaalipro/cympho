defmodule CymphoWeb.WorkspaceControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Projects
  alias Cympho.Workspaces

  setup %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{role: "admin"})
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

  test "service creation cannot forge lifecycle, preview port, or ownership", %{
    conn: conn,
    company: company,
    project: project,
    workspace: workspace,
    execution_workspace: execution_workspace
  } do
    forged_id = Ecto.UUID.generate()
    browser_conn = conn

    conn =
      post(conn, "/api/exec-workspaces/#{execution_workspace.id}/services", %{
        "runtime_service" => %{
          "service_name" => "Forged preview",
          "status" => "running",
          "port" => 5432,
          "preview_ref" => forged_id,
          "company_id" => forged_id,
          "project_id" => forged_id,
          "project_workspace_id" => forged_id,
          "execution_workspace_id" => forged_id,
          "scope_type" => "issue",
          "scope_id" => forged_id,
          "owner_agent_id" => forged_id,
          "started_by_run_id" => forged_id,
          "provider_ref" => "forged-provider"
        }
      })

    assert %{"data" => %{"id" => service_id, "status" => "stopped", "port" => nil}} =
             json_response(conn, 201)

    service = Workspaces.get_runtime_service!(service_id)
    assert service.company_id == company.id
    assert service.project_id == project.id
    assert service.project_workspace_id == workspace.id
    assert service.execution_workspace_id == execution_workspace.id
    assert service.preview_ref == nil
    assert service.scope_id == nil
    assert service.owner_agent_id == nil
    assert service.started_by_run_id == nil
    assert service.provider_ref == nil

    start_conn = patch(recycle(conn), "/api/services/#{service.id}/start")

    assert %{"data" => %{"status" => "starting", "port" => nil, "preview_ref" => nil}} =
             json_response(start_conn, 200)

    preview_host = Cympho.Workspaces.PreviewUrl.preview_host()

    proxy_conn =
      browser_conn
      |> Map.put(:host, preview_host)
      |> get("/api/preview/#{service.id}/invalid-capability/proxy/")

    assert %{"error" => "Runtime service not found"} = json_response(proxy_conn, 404)
  end

  test "lease creation is bound to the URL workspace and server-owned lifecycle", %{
    conn: conn,
    company: company,
    project: project,
    workspace: workspace,
    execution_workspace: execution_workspace,
    unique: unique
  } do
    {:ok, other_execution_workspace} =
      Workspaces.create_execution_workspace(%{
        name: "Other API exec workspace #{unique}",
        status: "open",
        company_id: company.id,
        project_id: project.id,
        project_workspace_id: workspace.id
      })

    {:ok, environment} =
      Workspaces.create_environment(%{
        name: "API lease environment #{unique}",
        status: "active",
        company_id: company.id,
        project_id: project.id
      })

    forged_id = Ecto.UUID.generate()

    conn =
      post(conn, "/api/exec-workspaces/#{execution_workspace.id}/leases", %{
        "lease" => %{
          "environment_id" => environment.id,
          "execution_workspace_id" => other_execution_workspace.id,
          "company_id" => forged_id,
          "status" => "released",
          "provider" => "fake",
          "provider_lease_id" => "forged-provider-lease",
          "acquired_at" => DateTime.utc_now(),
          "released_at" => DateTime.utc_now()
        }
      })

    assert %{"data" => %{"id" => lease_id}} = json_response(conn, 201)
    {:ok, lease} = Workspaces.get_company_environment_lease(company.id, lease_id)

    assert lease.company_id == company.id
    assert lease.execution_workspace_id == execution_workspace.id
    assert lease.environment_id == environment.id
    assert lease.status == "active"
    assert is_nil(lease.provider)
    assert is_nil(lease.provider_lease_id)
    assert is_nil(lease.released_at)
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
