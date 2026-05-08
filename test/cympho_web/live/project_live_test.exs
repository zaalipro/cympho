defmodule CymphoWeb.ProjectLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Projects
  alias Cympho.Repo
  alias Cympho.Secrets
  alias CymphoWeb.ConnCase

  describe "New project" do
    test "creates projects inside the current company", %{conn: conn} do
      {_conn, user, company} = ConnCase.register_and_log_in_user(conn)

      conn = live_session_conn(conn, user, company)

      {:ok, view, html} = live(conn, "/projects/new")

      assert html =~ "New project"

      view
      |> form("form", %{
        "project" => %{
          "name" => "Customer Portal",
          "description" => "Second project for multi-project intake.",
          "prefix" => "CP",
          "status" => "active",
          "repo_url" => ""
        }
      })
      |> render_submit()

      [project] = Projects.list_projects_by_company(company.id)
      assert project.name == "Customer Portal"
      assert project.company_id == company.id
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

      conn = live_session_conn(conn, user, company)
      {:ok, view, html} = live(conn, "/projects/#{project.id}")

      assert html =~ "Project settings"
      assert html =~ "Environment variables"
      assert html =~ "Recent issues"
      assert html =~ "Save changes"
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
