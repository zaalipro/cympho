defmodule CymphoWeb.ProjectLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Goals
  alias Cympho.Issues
  alias Cympho.Projects
  alias Cympho.Repo
  alias Cympho.Secrets
  alias Cympho.Workspaces
  alias CymphoWeb.ConnCase

  describe "Project index" do
    test "renders operating health for project workstreams", %{conn: conn} do
      {_conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, project} =
        Projects.create_project(%{
          name: "Flow Project",
          description: "Owns the delivery flow.",
          prefix: "FLW",
          company_id: company.id
        })

      {:ok, _idle_project} =
        Projects.create_project(%{
          name: "Idle Project",
          prefix: "IDL",
          repo_url: "https://github.com/example/idle",
          company_id: company.id
        })

      {:ok, _goal} =
        Goals.create_goal(%{
          title: "Flow mission",
          company_id: company.id,
          project_id: project.id,
          goal_type: :mission
        })

      for status <- [:todo, :in_review, :blocked, :done] do
        {:ok, _issue} =
          Issues.create_issue(%{
            title: "Flow #{status}",
            company_id: company.id,
            project_id: project.id,
            status: status
          })
      end

      conn = live_session_conn(conn, user, company)
      {:ok, _view, html} = live(conn, "/projects")

      assert html =~ "Workstream health"
      assert html =~ "3 open issues across 2 active projects"
      assert html =~ "Project queue signals"
      assert html =~ "Flow Project"
      assert html =~ "No repository configured"
      assert html =~ "1 active goal"
      assert html =~ "25% complete"
      assert html =~ ~s(href="/issues?project_id=#{project.id}")
    end

    test "does not archive a project from another company", %{conn: conn} do
      {_conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Other Project Company",
          slug: "other-project-company-#{System.unique_integer([:positive])}"
        })

      {:ok, other_project} =
        Projects.create_project(%{
          name: "Foreign Project",
          prefix: "FRGN",
          company_id: other_company.id
        })

      conn = live_session_conn(conn, user, company)
      {:ok, view, _html} = live(conn, "/projects")

      html = render_click(view, "delete_project", %{"id" => other_project.id})

      assert html =~ "Project not found for this company."
      assert Projects.get_project!(other_project.id).status == :active
    end

    test "archives a current-company project and updates the visible state", %{conn: conn} do
      {_conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, project} =
        Projects.create_project(%{
          name: "Archive Me",
          prefix: "ARCV",
          company_id: company.id
        })

      conn = live_session_conn(conn, user, company)
      {:ok, view, _html} = live(conn, "/projects")

      html = render_click(view, "delete_project", %{"id" => project.id})

      assert html =~ "Project archived."
      assert html =~ "Archived"
      assert Projects.get_project!(project.id).status == :archived
    end
  end

  describe "New project" do
    test "creates projects inside the current company", %{conn: conn} do
      {_conn, user, company} = ConnCase.register_and_log_in_user(conn)

      conn = live_session_conn(conn, user, company)

      {:ok, view, html} = live(conn, "/projects/new")

      assert html =~ "New project"
      assert html =~ "Project launch plan"
      assert html =~ "Operating boundary"
      assert html =~ "Issue identifier"
      assert html =~ "Workspace posture"
      assert html =~ "Setup checklist"
      assert html =~ "Create behavior"
      assert has_element?(view, "[data-ui-complex-page]")
      assert has_element?(view, "form[data-ui-simple-single-column]")

      assert has_element?(
               view,
               "[data-testid='project-identifier-fields'][data-ui-simple-single-column]"
             )

      assert has_element?(
               view,
               "[data-testid='project-create-actions'][data-ui-simple-full-span]"
             )

      assert has_element?(view, "input[name='project[name]']")
      assert has_element?(view, "input[name='project[prefix]']")

      refute has_element?(view, ".ui-advanced-only input[name='project[name]']")
      refute has_element?(view, ".ui-advanced-only input[name='project[prefix]']")
      refute has_element?(view, ".ui-advanced-only button[type='submit']")

      assert has_element?(
               view,
               "[data-testid='project-repository-field'].ui-advanced-only input[name='project[repo_url]']"
             )

      assert has_element?(
               view,
               "[data-testid='project-workspace-posture'].ui-advanced-only select[name='project[status]']"
             )

      assert has_element?(view, "[data-testid='project-setup-rail'].ui-advanced-only")

      result =
        view
        |> form("form", %{
          "project" => %{
            "name" => "Customer Portal",
            "description" => "Second project for multi-project intake.",
            "prefix" => "CP",
            "status" => "active",
            "repo_url" => "https://github.com/example/customer-portal",
            "color" => "#d97757"
          }
        })
        |> render_submit()

      [project] = Projects.list_projects_by_company(company.id)
      assert project.name == "Customer Portal"
      assert project.company_id == company.id
      assert project.repo_url == "https://github.com/example/customer-portal"
      assert project.color == "#d97757"

      expected_path = "/projects/#{project.id}"
      assert {:error, {:live_redirect, %{to: ^expected_path}}} = result
    end

    test "ignores a forged company id", %{conn: conn} do
      {_conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Foreign New Project Company",
          slug: "foreign-new-project-#{System.unique_integer([:positive])}"
        })

      conn = live_session_conn(conn, user, company)
      {:ok, view, _html} = live(conn, "/projects/new")

      render_submit(view, "save", %{
        "project" => %{
          "name" => "Scoped Project",
          "prefix" => "SCOP",
          "company_id" => other_company.id
        }
      })

      [project] = Projects.list_projects_by_company(company.id)
      assert project.name == "Scoped Project"
      assert Projects.list_projects_by_company(other_company.id) == []
    end
  end

  describe "Project control page" do
    test "renders show context and edits project settings in one page", %{conn: conn} do
      {_conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, project} =
        Projects.create_project(%{
          name: "AILogic",
          description: "Original description",
          prefix: "AIL",
          repo_url: "https://github.com/zaalipro/ailogic",
          company_id: company.id
        })

      {:ok, goal} =
        Goals.create_goal(%{
          title: "Ship autonomous project command",
          company_id: company.id,
          project_id: project.id,
          goal_type: :mission
        })

      {:ok, _issue} =
        Issues.create_issue(%{
          title: "Implement project command center",
          company_id: company.id,
          project_id: project.id,
          goal_id: goal.id,
          status: :in_progress
        })

      {:ok, _workspace} =
        Workspaces.create_project_workspace(%{
          name: "AILogic Workspace",
          company_id: company.id,
          project_id: project.id,
          cwd: "/tmp/ailogic"
        })

      {:ok, _secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "project",
          scope_id: project.id,
          key: "PROJECT_TOKEN",
          value: "secret-value",
          description: "Project env var"
        })

      conn = live_session_conn(conn, user, company)
      {:ok, view, html} = live(conn, "/projects/#{project.id}")

      assert has_element?(view, "[data-testid='project-command']")
      assert has_element?(view, "[data-testid='project-readiness']")
      assert has_element?(view, "[data-testid='project-goals']")
      assert html =~ "Project command"
      assert html =~ "Project work is moving through execution"
      assert html =~ "Execution readiness"
      assert html =~ "Mission control"
      assert html =~ "AILogic Workspace"
      assert html =~ "PROJECT_TOKEN"
      assert html =~ "Ship autonomous project command"
      assert html =~ "Project settings"
      assert html =~ "Environment variables"
      assert html =~ "Work queue"
      assert html =~ "Save changes"
      assert has_element?(view, "[data-testid='project-status-field'].ui-advanced-only")

      assert has_element?(
               view,
               "[data-testid='project-settings-repository-field'].ui-advanced-only"
             )

      assert has_element?(view, "[data-testid='project-color-field'].ui-advanced-only")
      assert has_element?(view, "[data-testid='project-environment-variables'].ui-advanced-only")
      assert has_element?(view, "#project-settings[data-ui-simple-single-column]")
      assert has_element?(view, "#project-settings [data-ui-simple-single-column]")
      refute html =~ "/projects/#{project.id}/edit"

      {:ok, _edit_view, edit_html} = live(conn, "/projects/#{project.id}/edit")
      assert edit_html =~ "Project settings"
      assert edit_html =~ "Save changes"

      view
      |> form("form[phx-submit='save']", %{
        "project" => %{
          "name" => "AILogic Ops",
          "description" => "Updated from the unified project page.",
          "prefix" => "AIL",
          "status" => "active",
          "repo_url" => "https://github.com/zaalipro/ailogic"
        }
      })
      |> render_submit()

      updated = Repo.reload!(project)
      assert updated.name == "AILogic Ops"
      assert updated.description == "Updated from the unified project page."
    end

    test "adds project environment variables from the show page", %{conn: conn} do
      {_conn, user, company} = ConnCase.register_and_log_in_user(conn)

      {:ok, project} =
        Projects.create_project(%{
          name: "Env Project",
          prefix: "ENV",
          company_id: company.id
        })

      conn = live_session_conn(conn, user, company)
      {:ok, view, _html} = live(conn, "/projects/#{project.id}")

      view
      |> form("form[phx-submit='add_env']", %{
        "env" => %{"key" => "github_token", "value" => "secret-value"}
      })
      |> render_submit()

      assert {:ok, secret} =
               Secrets.get_secret_by_key(company.id, "GITHUB_TOKEN",
                 scope: "project",
                 scope_id: project.id
               )

      assert secret.scope == "project"
      assert render(view) =~ "GITHUB_TOKEN"
    end
  end

  defp live_session_conn(conn, user, company) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_id", user.id)
    |> Plug.Conn.put_session("company_id", company.id)
  end
end
