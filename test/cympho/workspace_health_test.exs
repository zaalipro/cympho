defmodule Cympho.WorkspaceHealthTest do
  use Cympho.DataCase, async: true

  alias Cympho.Companies
  alias Cympho.Projects
  alias Cympho.Workspaces

  describe "health_summary/2" do
    test "reports empty state when no project workspaces exist" do
      company = create_company("empty")

      assert %{
               level: :empty,
               label: "Not configured",
               metrics: %{total_project_workspaces: 0},
               summary: "No project workspaces are configured yet."
             } = Workspaces.health_summary(company.id)
    end

    test "detects unhealthy services, failed probes, stale workspaces, preview gaps, and expiring leases" do
      now = ~U[2026-06-10 12:00:00Z]
      company = create_company("risk")
      project = create_project(company, "Risk Project")
      workspace = create_project_workspace(company, project, "Risk Workspace")

      {:ok, execution_workspace} =
        Workspaces.create_execution_workspace(%{
          name: "Stale Exec",
          status: "open",
          project_id: project.id,
          company_id: company.id,
          project_workspace_id: workspace.id,
          opened_at: DateTime.add(now, -5 * 60 * 60, :second),
          last_used_at: DateTime.add(now, -5 * 60 * 60, :second)
        })

      {:ok, _service} =
        Workspaces.create_runtime_service(%{
          service_name: "Preview",
          status: "running",
          health_status: "unhealthy",
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
          company_id: company.id,
          environment_id: environment.id,
          execution_workspace_id: execution_workspace.id,
          expires_at: DateTime.add(now, 10 * 60, :second)
        })

      {:ok, _probe} =
        Workspaces.create_probe(%{
          probe_type: "http",
          status: "failed",
          company_id: company.id,
          environment_id: environment.id,
          execution_workspace_id: execution_workspace.id
        })

      summary = Workspaces.health_summary(company.id, now: now)

      assert summary.level == :critical
      assert summary.metrics.total_project_workspaces == 1
      assert summary.metrics.open_execution_workspaces == 1
      assert summary.metrics.stale_execution_workspaces == 1
      assert summary.metrics.running_services == 1
      assert summary.metrics.unhealthy_services == 1
      assert summary.metrics.previewless_services == 1
      assert summary.metrics.active_leases == 1
      assert summary.metrics.expiring_leases == 1
      assert summary.metrics.failed_probes == 1
      assert summary.summary =~ "1 unhealthy service"
      assert Enum.any?(summary.recommendations, &(&1.label == "Fix runtime health"))
      assert Enum.any?(summary.recommendations, &(&1.label == "Review probes"))
      assert Enum.any?(summary.recommendations, &(&1.label == "Expose previews"))
      assert Enum.any?(summary.recommendations, &(&1.label == "Close stale workspaces"))
      assert Enum.any?(summary.recommendations, &(&1.label == "Renew leases"))
    end

    test "reports healthy when workspace runtime state is inspectable and fresh" do
      now = ~U[2026-06-10 12:00:00Z]
      company = create_company("healthy")
      project = create_project(company, "Healthy Project")
      workspace = create_project_workspace(company, project, "Healthy Workspace")

      {:ok, execution_workspace} =
        Workspaces.create_execution_workspace(%{
          name: "Fresh Exec",
          status: "open",
          project_id: project.id,
          company_id: company.id,
          project_workspace_id: workspace.id,
          opened_at: DateTime.add(now, -15 * 60, :second),
          last_used_at: DateTime.add(now, -5 * 60, :second)
        })

      {:ok, _service} =
        Workspaces.create_runtime_service(%{
          service_name: "Preview",
          status: "running",
          health_status: "healthy",
          port: 4000,
          company_id: company.id,
          project_id: project.id,
          project_workspace_id: workspace.id,
          execution_workspace_id: execution_workspace.id
        })

      assert %{
               level: :healthy,
               label: "Healthy",
               metrics: %{
                 open_execution_workspaces: 1,
                 running_services: 1,
                 previewless_services: 0,
                 unhealthy_services: 0
               },
               recommendations: []
             } = Workspaces.health_summary(company.id, now: now)
    end
  end

  defp create_company(label) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Workspace #{label} #{unique}",
        slug: "workspace-#{label}-#{unique}"
      })

    company
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
        project_id: project.id
      })

    workspace
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
