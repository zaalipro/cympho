defmodule CymphoWeb.WorkspaceLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Projects
  alias Cympho.Workspaces

  describe "Index" do
    test "shows workspace command and inventory diagnostics", %{
      conn: conn,
      current_company: company
    } do
      project = create_project(company, "Workspace Project")
      workspace = create_project_workspace(company, project, "Runtime Workspace")

      {:ok, _service} =
        Workspaces.create_runtime_service(%{
          service_name: "Preview",
          status: "running",
          company_id: company.id,
          project_id: project.id,
          project_workspace_id: workspace.id
        })

      {:ok, view, html} = live(conn, "/workspaces")

      assert has_element?(view, "[data-testid='workspace-health']")
      assert has_element?(view, "[data-testid='workspace-command']")
      assert has_element?(view, "[data-testid='workspace-list']")
      assert html =~ "Workspace command"
      assert html =~ "Watch"
      assert html =~ "Preview gaps"
      assert html =~ "Expose previews"
      assert html =~ "Workspace inventory"
      assert html =~ "Runtime Workspace"
      assert html =~ "Inspect"
      assert html =~ workspace.name
    end
  end

  describe "Show project workspace" do
    test "shows workspace readiness, execution lanes, and runtime services", %{
      conn: conn,
      current_company: company
    } do
      project = create_project(company, "Workspace Project")
      workspace = create_project_workspace(company, project, "Runtime Workspace")
      execution_workspace = create_execution_workspace(company, project, workspace)

      {:ok, _service} =
        Workspaces.create_runtime_service(%{
          service_name: "Preview",
          status: "running",
          health_status: "healthy",
          port: 4329,
          company_id: company.id,
          project_id: project.id,
          project_workspace_id: workspace.id,
          execution_workspace_id: execution_workspace.id
        })

      {:ok, view, html} = live(conn, "/workspaces/#{workspace.id}")

      assert has_element?(view, "[data-testid='project-workspace-command']")
      assert html =~ "This workspace is ready"
      assert html =~ "Execution lanes"
      assert html =~ execution_workspace.name
      assert html =~ "Runtime services"
      assert html =~ "Preview"
    end
  end

  describe "Show execution workspace" do
    test "shows services, guardrails, and operation history", %{
      conn: conn,
      current_company: company
    } do
      project = create_project(company, "Workspace Project")
      workspace = create_project_workspace(company, project, "Runtime Workspace")
      execution_workspace = create_execution_workspace(company, project, workspace)

      {:ok, _service} =
        Workspaces.create_runtime_service(%{
          service_name: "Phoenix preview",
          status: "running",
          health_status: "healthy",
          command: "mix phx.server",
          port: 4329,
          company_id: company.id,
          project_id: project.id,
          project_workspace_id: workspace.id,
          execution_workspace_id: execution_workspace.id
        })

      {:ok, environment} =
        Workspaces.create_environment(%{
          name: "Preview Env",
          status: "active",
          company_id: company.id,
          project_id: project.id
        })

      {:ok, _lease} =
        Workspaces.create_lease(%{
          status: "active",
          lease_policy: "exclusive",
          company_id: company.id,
          environment_id: environment.id,
          execution_workspace_id: execution_workspace.id,
          expires_at: DateTime.add(DateTime.utc_now(), 60 * 60, :second)
        })

      {:ok, _probe} =
        Workspaces.create_probe(%{
          probe_type: "http",
          status: "healthy",
          company_id: company.id,
          environment_id: environment.id,
          execution_workspace_id: execution_workspace.id,
          result: %{"status" => 200}
        })

      {:ok, _operation} =
        Workspaces.create_operation(%{
          phase: "launch",
          status: "completed",
          command: "mix phx.server",
          exit_code: 0,
          stdout_excerpt: "Listening on 4329",
          company_id: company.id,
          execution_workspace_id: execution_workspace.id
        })

      {:ok, view, html} =
        live(conn, "/workspaces/#{workspace.id}/exec/#{execution_workspace.id}")

      assert has_element?(view, "[data-testid='execution-workspace-command']")
      assert html =~ "This lane is ready"
      assert html =~ "Runtime services"
      assert html =~ "Environment guardrails"
      assert html =~ "Operations log"
      assert html =~ "Phoenix preview"
      assert html =~ "mix phx.server"
    end
  end

  defp create_project(company, name) do
    {:ok, project} =
      Projects.create_project(%{
        name: name,
        prefix: unique_prefix(),
        company_id: company.id
      })

    project
  end

  defp create_project_workspace(company, project, name) do
    {:ok, workspace} =
      Workspaces.create_project_workspace(%{
        name: name,
        company_id: company.id,
        project_id: project.id,
        default_ref: "main",
        is_primary: true,
        source_type: "local"
      })

    workspace
  end

  defp create_execution_workspace(company, project, workspace) do
    {:ok, execution_workspace} =
      Workspaces.create_execution_workspace(%{
        name: "Execution Lane",
        status: "open",
        mode: "worktree",
        branch_name: "agent/runtime-preview",
        cwd: "/tmp/cympho-runtime",
        company_id: company.id,
        project_id: project.id,
        project_workspace_id: workspace.id,
        opened_at: DateTime.utc_now(),
        last_used_at: DateTime.utc_now()
      })

    execution_workspace
  end

  defp unique_prefix do
    suffix =
      System.unique_integer([:positive])
      |> Integer.digits(26)
      |> Enum.map_join(fn digit -> <<?A + digit>> end)
      |> String.slice(0, 8)

    "W" <> suffix
  end
end
