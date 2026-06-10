defmodule CymphoWeb.WorkspaceLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Projects
  alias Cympho.Workspaces

  describe "Index" do
    test "shows workspace health diagnostics", %{conn: conn, current_company: company} do
      {:ok, project} =
        Projects.create_project(%{
          name: "Workspace Project",
          prefix: unique_prefix(),
          company_id: company.id
        })

      {:ok, workspace} =
        Workspaces.create_project_workspace(%{
          name: "Runtime Workspace",
          company_id: company.id,
          project_id: project.id
        })

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
      assert html =~ "Workspace Health"
      assert html =~ "Watch"
      assert html =~ "Preview gaps"
      assert html =~ "Expose previews"
      assert html =~ "Runtime Workspace"
    end
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
