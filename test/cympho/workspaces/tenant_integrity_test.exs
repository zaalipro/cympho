defmodule Cympho.Workspaces.TenantIntegrityTest do
  use Cympho.DataCase, async: true

  alias Cympho.{Companies, Issues, Projects, Workspaces}

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Workspace scope A #{unique}",
        slug: "workspace-scope-a-#{unique}"
      })

    {:ok, other_company} =
      Companies.create_company(%{
        name: "Workspace scope B #{unique}",
        slug: "workspace-scope-b-#{unique}"
      })

    {:ok, project} =
      Projects.create_project(%{
        name: "Workspace scope project A",
        prefix: "WSA",
        company_id: company.id
      })

    {:ok, other_project} =
      Projects.create_project(%{
        name: "Workspace scope project B",
        prefix: "WSB",
        company_id: other_company.id
      })

    {:ok, workspace} =
      Workspaces.create_project_workspace(%{
        name: "Workspace scope A",
        company_id: company.id,
        project_id: project.id
      })

    {:ok, other_workspace} =
      Workspaces.create_project_workspace(%{
        name: "Workspace scope B",
        company_id: other_company.id,
        project_id: other_project.id
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Workspace source A",
        company_id: company.id,
        project_id: project.id
      })

    {:ok, other_issue} =
      Issues.create_issue(%{
        title: "Workspace source B",
        company_id: other_company.id,
        project_id: other_project.id
      })

    {:ok, other_execution_workspace} =
      Workspaces.create_execution_workspace(%{
        name: "Execution workspace B",
        company_id: other_company.id,
        project_id: other_project.id,
        project_workspace_id: other_workspace.id,
        source_issue_id: other_issue.id
      })

    %{
      company: company,
      other_company: other_company,
      project: project,
      other_project: other_project,
      workspace: workspace,
      other_workspace: other_workspace,
      issue: issue,
      other_issue: other_issue,
      other_execution_workspace: other_execution_workspace
    }
  end

  test "project workspaces cannot reference another company's project", context do
    assert {:error, changeset} =
             Workspaces.create_project_workspace(%{
               name: "Forged project workspace",
               company_id: context.company.id,
               project_id: context.other_project.id
             })

    assert Keyword.has_key?(changeset.errors, :project_id)
  end

  test "execution workspace relations stay in one company and project", context do
    base = %{
      name: "Forged execution workspace",
      company_id: context.company.id,
      project_id: context.project.id,
      project_workspace_id: context.workspace.id,
      source_issue_id: context.issue.id
    }

    for {field, value} <- [
          project_workspace_id: context.other_workspace.id,
          source_issue_id: context.other_issue.id,
          derived_from_execution_workspace_id: context.other_execution_workspace.id
        ] do
      assert {:error, changeset} =
               base
               |> Map.put(field, value)
               |> Workspaces.create_execution_workspace()

      assert Keyword.has_key?(changeset.errors, field)
    end
  end

  test "environments cannot reference another company's project", context do
    assert {:error, changeset} =
             Workspaces.create_environment(%{
               name: "Forged environment",
               company_id: context.company.id,
               project_id: context.other_project.id
             })

    assert Keyword.has_key?(changeset.errors, :project_id)
  end

  test "environment leases reject cross-company workspace and issue references", context do
    {:ok, environment} =
      Workspaces.create_environment(%{
        name: "Scoped lease environment",
        company_id: context.company.id,
        project_id: context.project.id
      })

    base = %{
      status: "active",
      company_id: context.company.id,
      environment_id: environment.id
    }

    for {field, value} <- [
          execution_workspace_id: context.other_execution_workspace.id,
          issue_id: context.other_issue.id
        ] do
      assert {:error, changeset} =
               base
               |> Map.put(field, value)
               |> Workspaces.create_lease()

      assert Keyword.has_key?(changeset.errors, field)
    end
  end
end
