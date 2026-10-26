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

      # The runtime checklist link sits in the list band's header, Advanced-only as before:
      # it lands on a Health section that Simple mode hides.
      assert Floki.attribute(doc, "#workspace-list .card-h a.lnk", "href") == [
               "/operations#runtime-launch-checklist"
             ]

      assert Floki.find(doc, "#workspace-list .card-h .ui-advanced-only > a.lnk") != []

      # The command is one line in the list band: its state is a word, not a coloured pill.
      assert text(doc, "#workspace-list .card-h .wf-st") == "Watch"
      assert html =~ "Expose previews"

      # Each recommendation carries its own count, so the company's count sentence is not
      # printed above them a second time.
      refute text(doc, "[data-testid='workspace-command']") =~ "need review"

      # One row per folder: the title opens it, the state is a word.
      assert Floki.attribute(doc, "#workspace-#{workspace.id} a.rt2", "href") == [
               "/workspaces/#{workspace.id}"
             ]

      assert text(doc, "#workspace-#{workspace.id} .lr-st") == "Inspect"
      assert text(doc, "#workspace-#{workspace.id} .rm") =~ "Workspace Project"
      assert html =~ workspace.name
    end

    test "a folder that needs a look says why under its row", %{
      conn: conn,
      current_company: company
    } do
      project = create_project(company, "Workspace Project")
      stale = create_project_workspace(company, project, "Stale Workspace")
      idle = create_project_workspace(company, project, "Idle Workspace", %{is_primary: false})
      five_hours_ago = DateTime.add(DateTime.utc_now(), -5 * 60 * 60, :second)

      {:ok, _lane} =
        Workspaces.create_execution_workspace(%{
          name: "Forgotten Lane",
          status: "open",
          company_id: company.id,
          project_id: project.id,
          project_workspace_id: stale.id,
          opened_at: five_hours_ago,
          last_used_at: five_hours_ago
        })

      {:ok, _view, html} = live(conn, "/workspaces")
      doc = main_doc(html)

      # Its only problem is a stale run folder: the row's state word asks for a look, the line below says why.
      assert text(doc, "#workspace-#{stale.id} .lr-st") == "Inspect"
      assert text(doc, "#workspace-#{stale.id} .lr-below") =~ "1 stale execution workspace(s)"

      # A folder with nothing wrong has no line below: its state word says it all.
      assert text(doc, "#workspace-#{idle.id} .lr-st") == "Idle"
      assert Floki.find(doc, "#workspace-#{idle.id} .lr-below") == []
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
          cwd: "/tmp/cympho-demo/runtime",
          repo_url: "https://github.com/northwind-demo/invoicing-app"
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

      # A long repository URL wraps after a slash, never inside a name ("no/rthwind").
      assert details =~ "https://github.com/northwind-demo/invoicing-app"
      assert length(Floki.find(doc, ".aside .wf-loc wbr")) == 4
    end

    test "a running service says how its health check went", %{
      conn: conn,
      current_company: company
    } do
      project = create_project(company, "Workspace Project")
      workspace = create_project_workspace(company, project, "Runtime Workspace")
      execution_workspace = create_execution_workspace(company, project, workspace)
      services = health_services(execution_workspace)

      {:ok, _view, html} = live(conn, "/workspaces/#{workspace.id}")

      assert_service_health(main_doc(html), services)
    end

    test "an unhealthy service keeps its lifecycle beside its health", %{
      conn: conn,
      current_company: company
    } do
      project = create_project(company, "Workspace Project")
      workspace = create_project_workspace(company, project, "Runtime Workspace")
      execution_workspace = create_execution_workspace(company, project, workspace)
      {running, stopped} = unhealthy_services(execution_workspace)

      {:ok, _view, html} = live(conn, "/workspaces/#{workspace.id}")

      assert_service_states(main_doc(html), running, stopped)
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

    test "an unhealthy service keeps its lifecycle beside its health", %{
      conn: conn,
      current_company: company
    } do
      project = create_project(company, "Workspace Project")
      workspace = create_project_workspace(company, project, "Runtime Workspace")
      execution_workspace = create_execution_workspace(company, project, workspace)
      {running, stopped} = unhealthy_services(execution_workspace)

      {:ok, _view, html} =
        live(conn, "/workspaces/#{workspace.id}/exec/#{execution_workspace.id}")

      assert_service_states(main_doc(html), running, stopped)
    end

    test "a running service says how its health check went", %{
      conn: conn,
      current_company: company
    } do
      project = create_project(company, "Workspace Project")
      workspace = create_project_workspace(company, project, "Runtime Workspace")
      execution_workspace = create_execution_workspace(company, project, workspace)
      services = health_services(execution_workspace)

      {:ok, _view, html} =
        live(conn, "/workspaces/#{workspace.id}/exec/#{execution_workspace.id}")

      assert_service_health(main_doc(html), services)
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

      # Without a repository the folder cannot be created yet; the pill says so by being disabled,
      # and the way forward is the project's settings, where the repository is added.
      assert has_element?(view, "button.pl[phx-click='create_workspace'][disabled]")

      assert has_element?(
               view,
               ".gl-sec a.lnk[href='/projects/#{project.id}/edit']",
               "Add a repository"
             )

      refute has_element?(view, "[phx-click='delete_workspace']")
      refute has_element?(view, "form[phx-submit='write_prompt']")
    end

    test "the brief form writes PROMPT.md into the task's folder", %{
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

      # The folder exists on disk (create_workspace would clone a repository, so it is made here).
      folder = Cympho.Workspace.workspace_path(issue)
      File.mkdir_p!(folder)
      on_exit(fn -> File.rm_rf!(folder) end)

      {:ok, view, _html} = live(conn, "/workspace/#{issue.id}")

      html =
        view
        |> form("#iw-prompt", %{"prompt" => "Ship the welcome email."})
        |> render_submit()

      assert File.read!(Path.join(folder, "PROMPT.md")) == "Ship the welcome email."
      assert text(main_doc(html), ".flash-msg") == "Prompt file written successfully"
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

  # Two services that both report unhealthy: one still running, one stopped afterwards
  # (stop_service/1 keeps health_status, so only the lifecycle tells them apart).
  defp unhealthy_services(execution_workspace) do
    {:ok, running} =
      Workspaces.create_runtime_service(execution_workspace, %{service_name: "Web"})

    {:ok, running} =
      Workspaces.issue_service_preview(running, 4329, %{health_status: "unhealthy"})

    {:ok, stopped} =
      Workspaces.create_runtime_service(execution_workspace, %{service_name: "Worker"})

    {:ok, stopped} =
      Workspaces.issue_service_preview(stopped, 4330, %{health_status: "unhealthy"})

    {:ok, stopped} = Workspaces.stop_service(stopped)
    assert stopped.health_status == "unhealthy"

    {running, stopped}
  end

  # Health is the row's status word (the problem); the lifecycle stays beside it as a tag, said once.
  defp assert_service_states(doc, running, stopped) do
    assert text(doc, "#svc-#{running.id} .lr-st") == "Unhealthy"
    assert text(doc, "#svc-#{running.id} .lr-tr .tag") == "Running"
    assert text(doc, "#svc-#{stopped.id} .lr-st") == "Unhealthy"
    assert text(doc, "#svc-#{stopped.id} .lr-tr .tag") == "Stopped"
    refute text(doc, "#svc-#{running.id} .rm") =~ "unhealthy"
    refute text(doc, "#svc-#{stopped.id} .rm") =~ "unhealthy"
  end

  # Three running services: one reports healthy, one unknown, one has not reported yet.
  defp health_services(execution_workspace) do
    for {name, port, health} <- [
          {"Web", 4331, "healthy"},
          {"Api", 4332, "unknown"},
          {"Jobs", nil, nil}
        ] do
      {:ok, service} =
        Workspaces.create_runtime_service(execution_workspace, %{service_name: name})

      {:ok, service} =
        if port,
          do: Workspaces.issue_service_preview(service, port, %{health_status: health}),
          else: Workspaces.mark_service_running(service)

      {health, service}
    end
  end

  # A good or unknown report is not a problem, so the status word stays "Running";
  # the report itself is part of the row's meta line, and a service with none says nothing.
  defp assert_service_health(doc, services) do
    for {health, service} <- services do
      assert text(doc, "#svc-#{service.id} .lr-st") == "Running"
      meta = text(doc, "#svc-#{service.id} .rm")

      if health,
        do: assert(meta =~ health),
        else: refute(meta =~ ~r/healthy|unknown/)
    end
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
