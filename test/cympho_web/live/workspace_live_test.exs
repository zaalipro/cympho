defmodule CymphoWeb.WorkspaceLiveTest do
  use CymphoWeb.LiveCase, async: true

  import CymphoWeb.R3PageHelpers

  alias Cympho.Issues
  alias Cympho.Projects
  alias Cympho.Workspaces

  describe "Index" do
    test "shows workspace overview and inventory diagnostics", %{
      conn: conn,
      current_company: company
    } do
      project = create_project(company, "Workspace Project")
      workspace = create_project_workspace(company, project, "Runtime Workspace")

      {:ok, service} =
        Workspaces.create_runtime_service(workspace, %{service_name: "Preview"})

      {:ok, _service} = Workspaces.mark_service_running(service)

      {:ok, view, html} = live(conn, "/workspaces")
      doc = main_doc(html)

      # r3 (v7 O3): a root page under Tasks, titled with its rail label.
      assert_r3_page(doc, page: "workfiles", h1: "Work files", kind: :root, primaries: 0)

      assert has_element?(view, "[data-testid='workspace-health']")
      assert has_element?(view, "[data-testid='workspace-command']")
      assert has_element?(view, "[data-testid='workspace-list']")

      # The runtime checklist link sits in the list band's header.
      assert Floki.attribute(doc, "#workspace-list .card-h a.lnk", "href") == [
               "/operations#runtime-launch-checklist"
             ]

      # The command is one line in the list band: its state is a word, not a coloured pill.
      assert text(doc, "#workspace-list .card-h .wf-st") == "Watch"
      assert html =~ "Expose previews"

      # One row per folder: the title opens it, the state is a word.
      assert Floki.attribute(doc, "#workspace-#{workspace.id} a.rt2", "href") == [
               "/workspaces/#{workspace.id}"
             ]

      assert text(doc, "#workspace-#{workspace.id} .lr-st") == "Inspect"
      assert text(doc, "#workspace-#{workspace.id} .rm") =~ "Workspace Project"
      assert html =~ workspace.name
    end

    test "an empty company sees one quiet line and a New project pill", %{conn: conn} do
      {:ok, view, html} = live(conn, "/workspaces")
      doc = main_doc(html)

      assert text(doc, "#workspace-list .gl-big") == "No work folders yet"

      assert Floki.attribute(doc, "#workspace-list .gl-sec a.pl", "href") == [
               "/projects/new"
             ]

      refute has_element?(view, "[data-testid='workspace-command']")
    end
  end

  describe "Show project workspace" do
    test "shows workspace readiness, execution lanes, and runtime services", %{
      conn: conn,
      current_company: company
    } do
      project = create_project(company, "Workspace Project")

      workspace =
        create_project_workspace(company, project, "Runtime Workspace", %{
          cwd: "/tmp/cympho-demo/runtime"
        })

      execution_workspace = create_execution_workspace(company, project, workspace)

      {:ok, service} =
        Workspaces.create_runtime_service(execution_workspace, %{
          service_name: "Preview"
        })

      {:ok, _service} =
        Workspaces.issue_service_preview(service, 4329, %{health_status: "healthy"})

      {:ok, view, html} = live(conn, "/workspaces/#{workspace.id}")
      doc = main_doc(html)

      # r3 (v7 O4): a deep page under Work files.
      assert_r3_page(doc,
        page: "workfile",
        h1: "Runtime Workspace",
        kind: :deep,
        parent: "Work files",
        primaries: 0
      )

      assert has_element?(view, "[data-testid='project-workspace-command']")
      assert html =~ "This workspace is ready"

      # "Copy path" is a chip in the head, inside the copy hook.
      assert Floki.attribute(
               doc,
               ".head .chips[phx-hook='CopyToClipboard'] button.chip",
               "data-copy-text"
             ) ==
               ["/tmp/cympho-demo/runtime"]

      assert text(doc, "#wf-runs-t") == "Runs in this folder"

      assert Floki.attribute(doc, "#exec-#{execution_workspace.id} a.rt2", "href") == [
               "/workspaces/#{workspace.id}/exec/#{execution_workspace.id}"
             ]

      assert html =~ execution_workspace.name
      assert text(doc, "#wf-svc-t") == "Services"
      assert html =~ "Preview"

      # The details aside holds the folder's properties.
      details = text(doc, ".aside")
      assert details =~ "Workspace Project"
      assert details =~ "main"
      assert details =~ "/tmp/cympho-demo/runtime"
    end

    test "a folder from another company is refused", %{conn: conn} do
      other = Cympho.Companies.create_company(%{name: "Other Co", slug: unique_slug()})
      {:ok, other} = other
      project = create_project(other, "Their Project")
      workspace = create_project_workspace(other, project, "Their Workspace")

      assert {:error, {:live_redirect, %{to: "/workspaces"}}} =
               live(conn, "/workspaces/#{workspace.id}")
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

      {:ok, service} =
        Workspaces.create_runtime_service(execution_workspace, %{
          service_name: "Phoenix preview",
          command: "mix phx.server"
        })

      {:ok, _service} =
        Workspaces.issue_service_preview(service, 4329, %{health_status: "healthy"})

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

      doc = main_doc(html)

      # r3 (v7 O5): a deep page whose parent is its folder, by name.
      assert_r3_page(doc,
        page: "exec",
        h1: "Execution Lane",
        kind: :deep,
        parent: "Runtime Workspace",
        primaries: 0
      )

      assert Floki.attribute(doc, ".crumb a.back", "href") == ["/workspaces/#{workspace.id}"]

      assert has_element?(view, "[data-testid='execution-workspace-command']")
      assert html =~ "This lane is ready"
      assert text(doc, "#ex-svc-t") == "Services"
      assert text(doc, "#ex-guard-t") == "Environment guardrails"
      assert text(doc, "#ex-ops-t") == "Operations log"
      assert html =~ "Phoenix preview"
      assert html =~ "mix phx.server"

      # The run's folder is the aside: its path is mono and copies with one chip.
      assert text(doc, ".aside .h2") == "This run's folder"

      assert Floki.attribute(
               doc,
               ".aside [phx-hook='CopyToClipboard'] [data-copy-text]",
               "data-copy-text"
             ) ==
               ["/tmp/cympho-runtime"]
    end
  end

  describe "Issue work files" do
    test "a task without a folder offers to create one", %{
      conn: conn,
      current_company: company
    } do
      project = create_project(company, "Folder Project")

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Write the onboarding email",
          company_id: company.id,
          project_id: project.id
        })

      {:ok, view, html} = live(conn, "/workspace/#{issue.id}")
      doc = main_doc(html)
      identifier = issue.identifier || String.slice(issue.id, 0, 8)

      # r3 (v7 O6): a deep page whose parent is its task.
      assert_r3_page(doc,
        page: "issue-workfile",
        h1: "Work files for #{identifier}",
        kind: :deep,
        parent: identifier,
        primaries: 0
      )

      assert Floki.attribute(doc, ".crumb a.back", "href") == ["/issues/#{issue.id}"]
      assert text(doc, ".head .sub") == "Write the onboarding email"
      assert text(doc, ".gl-big") == "No work folder yet"

      # Without a repository the folder cannot be created yet; the pill says so by being disabled.
      assert has_element?(view, "button.pl[phx-click='create_workspace'][disabled]")
      refute has_element?(view, "[phx-click='delete_workspace']")
      refute has_element?(view, "form[phx-submit='write_prompt']")
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

  defp create_project_workspace(company, project, name, attrs \\ %{}) do
    {:ok, workspace} =
      Workspaces.create_project_workspace(
        Map.merge(
          %{
            name: name,
            company_id: company.id,
            project_id: project.id,
            default_ref: "main",
            is_primary: true,
            source_type: "local"
          },
          attrs
        )
      )

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

  defp unique_slug, do: "other-co-#{System.unique_integer([:positive])}"

  defp unique_prefix do
    suffix =
      System.unique_integer([:positive])
      |> Integer.digits(26)
      |> Enum.map_join(fn digit -> <<?A + digit>> end)
      |> String.slice(0, 8)

    "W" <> suffix
  end
end
