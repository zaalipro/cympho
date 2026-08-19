defmodule Cympho.Workspaces.RuntimeServiceTest do
  use Cympho.DataCase, async: true

  alias Cympho.Companies
  alias Cympho.Projects
  alias Cympho.Workspaces
  alias Cympho.Workspaces.PreviewUrl

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Runtime service company #{unique}",
        slug: "runtime-service-company-#{unique}"
      })

    {:ok, project} =
      Projects.create_project(%{
        name: "Runtime service project #{unique}",
        prefix: unique_prefix(unique),
        company_id: company.id
      })

    {:ok, project_workspace} =
      Workspaces.create_project_workspace(%{
        name: "Runtime project workspace #{unique}",
        company_id: company.id,
        project_id: project.id
      })

    {:ok, execution_workspace} =
      Workspaces.create_execution_workspace(%{
        name: "Runtime execution workspace #{unique}",
        status: "open",
        company_id: company.id,
        project_id: project.id,
        project_workspace_id: project_workspace.id
      })

    %{
      company: company,
      project: project,
      project_workspace: project_workspace,
      execution_workspace: execution_workspace
    }
  end

  test "registration ignores forged lifecycle, preview port, and ownership", %{
    company: company,
    project: project,
    project_workspace: project_workspace,
    execution_workspace: execution_workspace
  } do
    forged_id = Ecto.UUID.generate()

    assert {:ok, service} =
             Workspaces.create_runtime_service(execution_workspace, %{
               "service_name" => "Untrusted registration",
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
             })

    assert service.status == "stopped"
    assert service.port == nil
    assert service.preview_ref == nil
    assert service.company_id == company.id
    assert service.project_id == project.id
    assert service.project_workspace_id == project_workspace.id
    assert service.execution_workspace_id == execution_workspace.id
    assert service.scope_id == nil
    assert service.owner_agent_id == nil
    assert service.started_by_run_id == nil
    assert service.provider_ref == nil
    assert PreviewUrl.get_target_url(service) == nil

    assert {:error, :not_found} =
             Workspaces.get_company_preview_service(company.id, service.id, forged_id)
  end

  test "trusted port observation issues a revocable preview identity", %{
    company: company,
    execution_workspace: execution_workspace
  } do
    {:ok, service} =
      Workspaces.create_runtime_service(execution_workspace, %{
        service_name: "Trusted preview"
      })

    assert {:ok, service} = Workspaces.issue_service_preview(service, 4329)
    assert is_binary(service.preview_ref)
    assert PreviewUrl.get_target_url(service) == "http://127.0.0.1:4329"

    assert {:ok, found} =
             Workspaces.get_company_preview_service(
               company.id,
               service.id,
               service.preview_ref
             )

    assert found.id == service.id
    issued_ref = service.preview_ref

    assert {:ok, service} = Workspaces.issue_service_preview(service, 4329)
    refute service.preview_ref == issued_ref

    assert {:error, :not_found} =
             Workspaces.get_company_preview_service(company.id, service.id, issued_ref)

    issued_ref = service.preview_ref

    assert {:ok, service} = Workspaces.restart_service(service)
    assert service.status == "starting"
    assert service.port == nil
    assert service.preview_ref == nil
    assert PreviewUrl.get_target_url(service) == nil

    assert {:error, :not_found} =
             Workspaces.get_company_preview_service(company.id, service.id, issued_ref)
  end

  test "closing the owning execution workspace invalidates its preview", %{
    company: company,
    execution_workspace: execution_workspace
  } do
    {:ok, service} =
      Workspaces.create_runtime_service(execution_workspace, %{service_name: "Closing preview"})

    {:ok, service} = Workspaces.issue_service_preview(service, 4329)
    issued_ref = service.preview_ref

    {:ok, _execution_workspace} =
      Workspaces.update_execution_workspace(execution_workspace, %{status: "closed"})

    assert {:error, :not_found} =
             Workspaces.get_company_preview_service(company.id, service.id, issued_ref)

    assert {:error, :invalid_preview_scope} = Workspaces.issue_service_preview(service, 4330)
  end

  defp unique_prefix(unique) do
    suffix =
      unique
      |> Integer.digits(26)
      |> Enum.map_join(fn digit -> <<?A + digit>> end)
      |> String.slice(0, 8)

    "RS" <> suffix
  end
end
