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

  test "project workspace read, create, and update return safe nonempty data", %{
    conn: conn,
    company: company,
    project: project,
    workspace: workspace
  } do
    secret = "workspace-secret-sentinel"

    {:ok, workspace} =
      Workspaces.update_project_workspace(workspace, %{metadata: %{"secret_bindings" => secret}})

    list = get(conn, "/api/workspaces?project_id=#{project.id}")
    assert %{"data" => rows} = json_response(list, 200)
    assert Enum.any?(rows, &(&1["id"] == workspace.id))
    refute inspect(rows) =~ secret

    show = get(recycle(conn), "/api/workspaces/#{workspace.id}")

    assert %{"data" => %{"id" => id, "name" => name, "company_id" => company_id}} =
             json_response(show, 200)

    assert id == workspace.id
    assert name == workspace.name
    assert company_id == company.id
    refute show.resp_body =~ secret

    branch = get(recycle(conn), "/api/exec-workspaces/#{workspace.id}/default-branch")

    assert %{"data" => %{"default_branch" => "main", "project_workspace" => %{"id" => ^id}}} =
             json_response(branch, 200)

    refute branch.resp_body =~ secret

    create =
      post(recycle(conn), "/api/workspaces", %{
        "project_workspace" => %{
          "project_id" => project.id,
          "name" => "Created workspace",
          "repo_url" => "https://user:#{secret}@git.example/repo.git",
          "setup_command" => "export TOKEN=#{secret}",
          "shared_workspace_key" => secret,
          "metadata" => %{"secret_bindings" => secret}
        }
      })

    assert %{"data" => %{"id" => created_id, "name" => "Created workspace"}} =
             json_response(create, 201)

    refute create.resp_body =~ secret

    update =
      patch(recycle(conn), "/api/workspaces/#{created_id}", %{
        "project_workspace" => %{"name" => "Renamed workspace"}
      })

    assert %{"data" => %{"name" => "Renamed workspace"}} = json_response(update, 200)
    refute update.resp_body =~ secret

    config =
      patch(recycle(conn), "/api/workspaces/#{created_id}/worktree-config", %{
        "config" => %{"credential" => secret}
      })

    assert %{"data" => %{"id" => ^created_id}} = json_response(config, 200)
    refute config.resp_body =~ secret
  end

  test "execution workspace read, create, update, seed, and secret injection omit secret config",
       %{
         conn: conn,
         project: project,
         workspace: workspace,
         execution_workspace: execution_workspace
       } do
    secret = "execution-secret-sentinel"

    create =
      post(conn, "/api/workspaces/#{workspace.id}/exec-workspaces", %{
        "execution_workspace" => %{
          "name" => "Created execution workspace",
          "repo_url" => "https://user:#{secret}@git.example/repo.git",
          "metadata" => %{"secret_bindings" => secret}
        }
      })

    assert %{"data" => %{"id" => created_id, "name" => "Created execution workspace"}} =
             json_response(create, 201)

    refute create.resp_body =~ secret

    update =
      patch(recycle(conn), "/api/exec-workspaces/#{created_id}", %{
        "execution_workspace" => %{"name" => "Renamed execution workspace"}
      })

    assert %{"data" => %{"name" => "Renamed execution workspace"}} =
             json_response(update, 200)

    refute update.resp_body =~ secret

    list = get(recycle(conn), "/api/workspaces/#{workspace.id}/exec-workspaces")
    assert %{"data" => rows} = json_response(list, 200)
    assert Enum.any?(rows, &(&1["id"] == created_id))
    refute list.resp_body =~ secret

    show = get(recycle(conn), "/api/exec-workspaces/#{created_id}")

    assert %{"data" => %{"id" => ^created_id, "project_id" => project_id}} =
             json_response(show, 200)

    assert project_id == project.id
    refute show.resp_body =~ secret

    seed =
      post(recycle(conn), "/api/exec-workspaces/#{execution_workspace.id}/seed", %{
        "seed_config" => %{"credential" => secret}
      })

    assert %{"data" => %{"id" => _}} = json_response(seed, 200)
    refute seed.resp_body =~ secret

    inject =
      post(recycle(conn), "/api/exec-workspaces/#{execution_workspace.id}/secrets", %{
        "secret_mappings" => %{"API_KEY" => secret}
      })

    assert %{"data" => %{"id" => _}} = json_response(inject, 200)
    refute inject.resp_body =~ secret
  end

  test "workspace subresources omit commands, provider credentials, metadata, and logs", %{
    conn: conn,
    company: company,
    execution_workspace: execution_workspace
  } do
    secret = "subresource-secret-sentinel"

    service_create =
      post(conn, "/api/exec-workspaces/#{execution_workspace.id}/services", %{
        "runtime_service" => %{
          "service_name" => "API service",
          "reuse_key" => "stable-api-service",
          "command" => secret
        }
      })

    assert %{
             "data" => %{
               "id" => service_id,
               "service_name" => "API service",
               "reuse_key" => "stable-api-service"
             }
           } =
             json_response(service_create, 201)

    refute service_create.resp_body =~ secret

    service_id
    |> Workspaces.get_runtime_service!()
    |> Cympho.Workspaces.RuntimeService.lifecycle_changeset(%{
      url: "https://preview.test/?token=#{secret}",
      provider_ref: secret,
      stop_policy: %{"credential" => secret}
    })
    |> Cympho.Repo.update!()

    services = get(recycle(conn), "/api/exec-workspaces/#{execution_workspace.id}/services")

    assert %{"data" => [%{"id" => ^service_id, "reuse_key" => "stable-api-service"}]} =
             json_response(services, 200)

    refute services.resp_body =~ secret

    start = patch(recycle(conn), "/api/services/#{service_id}/start")
    assert %{"data" => %{"status" => "starting"}} = json_response(start, 200)
    refute start.resp_body =~ secret

    {:ok, _operation} =
      Workspaces.create_operation(%{
        phase: "launch",
        status: "completed",
        company_id: company.id,
        execution_workspace_id: execution_workspace.id,
        stdout_excerpt: secret,
        metadata: %{"credential" => secret}
      })

    operations = get(recycle(conn), "/api/exec-workspaces/#{execution_workspace.id}/operations")

    assert %{"data" => [%{"phase" => "launch", "status" => "completed"}]} =
             json_response(operations, 200)

    refute operations.resp_body =~ secret
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
    secret = "lease-secret-sentinel"

    conn =
      post(conn, "/api/exec-workspaces/#{execution_workspace.id}/leases", %{
        "lease" => %{
          "environment_id" => environment.id,
          "execution_workspace_id" => other_execution_workspace.id,
          "company_id" => forged_id,
          "status" => "released",
          "provider" => "fake",
          "provider_lease_id" => "forged-provider-lease",
          "metadata" => %{"credential" => secret},
          "acquired_at" => DateTime.utc_now(),
          "released_at" => DateTime.utc_now()
        }
      })

    assert %{"data" => %{"id" => lease_id}} = json_response(conn, 201)
    refute conn.resp_body =~ secret
    {:ok, lease} = Workspaces.get_company_environment_lease(company.id, lease_id)

    assert lease.company_id == company.id
    assert lease.execution_workspace_id == execution_workspace.id
    assert lease.environment_id == environment.id
    assert lease.status == "active"
    assert is_nil(lease.provider)
    assert is_nil(lease.provider_lease_id)
    assert is_nil(lease.released_at)

    lease
    |> Cympho.Workspaces.EnvironmentLease.changeset(%{provider_lease_id: secret})
    |> Cympho.Repo.update!()

    revoke = delete(recycle(conn), "/api/leases/#{lease_id}")

    assert %{"data" => %{"id" => ^lease_id, "status" => "released"}} =
             json_response(revoke, 200)

    refute revoke.resp_body =~ secret
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
