defmodule CymphoWeb.IssueControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Projects

  setup %{conn: conn} do
    {conn, user, company} = register_and_log_in_user(conn)

    {:ok, project} =
      Projects.create_project(%{
        name: "Test Project",
        prefix: "TST",
        company_id: company.id
      })

    %{conn: conn, user: user, project: project, company: company}
  end

  describe "POST /api/issues" do
    test "rejects a PR URL from another repository", %{
      conn: conn,
      project: project
    } do
      {:ok, _} = Projects.update_project(project, %{repo_url: "https://github.com/acme/app"})

      conn =
        post(conn, "/api/issues", %{
          "issue" => %{
            "title" => "Wrong PR repository",
            "project_id" => project.id,
            "github_pr_url" => "https://github.com/other/app/pull/4"
          }
        })

      assert %{"errors" => %{"github_pr_url" => [message]}} = json_response(conn, 422)
      assert message =~ "project repository"
    end

    test "rejects a malformed PR URL", %{conn: conn, project: project} do
      {:ok, _} = Projects.update_project(project, %{repo_url: "https://github.com/acme/app"})

      conn =
        post(conn, "/api/issues", %{
          "issue" => %{
            "title" => "Malformed PR URL",
            "project_id" => project.id,
            "github_pr_url" => "https://github.com/acme/app/pull/4?redirect=1"
          }
        })

      assert %{"errors" => %{"github_pr_url" => [_]}} = json_response(conn, 422)
    end

    test "accepts a PR URL in its configured repository", %{conn: conn, project: project} do
      {:ok, _} = Projects.update_project(project, %{repo_url: "https://github.com/acme/app"})

      conn =
        post(conn, "/api/issues", %{
          "issue" => %{
            "title" => "Authorized PR",
            "project_id" => project.id,
            "github_pr_url" => "https://github.com/Acme/App/pull/4"
          }
        })

      assert %{"data" => %{"id" => issue_id}} = json_response(conn, 201)

      assert Cympho.Issues.get_issue!(issue_id).github_pr_url ==
               "https://github.com/Acme/App/pull/4"
    end

    test "creates an issue without parentId", %{conn: conn, project: project} do
      params = %{
        "issue" => %{
          "title" => "Standalone Issue",
          "description" => "A regular issue",
          "project_id" => project.id
        }
      }

      conn = post(conn, "/api/issues", params)
      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] == "Standalone Issue"
      assert data["parent_id"] == nil
    end

    test "creates a child issue with parentId", %{conn: conn, project: project, company: company} do
      {:ok, parent} =
        Cympho.Issues.create_issue(%{
          "title" => "Parent Issue",
          "description" => "The parent",
          "project_id" => project.id,
          "company_id" => company.id
        })

      params = %{
        "issue" => %{
          "title" => "Child Issue",
          "description" => "The child",
          "project_id" => project.id,
          "parent_id" => parent.id
        }
      }

      conn = post(conn, "/api/issues", params)
      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] == "Child Issue"
      assert data["parent_id"] == parent.id
    end

    test "returns 422 for invalid data", %{conn: conn} do
      params = %{
        "issue" => %{
          "title" => "",
          "description" => ""
        }
      }

      conn = post(conn, "/api/issues", params)
      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "ignores forged system and tenant fields and records the authenticated creator", %{
      conn: conn,
      user: user,
      project: project,
      company: company
    } do
      forged_id = Ecto.UUID.generate()

      conn =
        post(conn, "/api/issues", %{
          "issue" => %{
            "title" => "Request-owned fields",
            "project_id" => project.id,
            "company_id" => forged_id,
            "created_by_user_id" => forged_id,
            "created_by_agent_id" => forged_id,
            "last_reviewer_id" => forged_id,
            "checkout_run_id" => forged_id,
            "project_workspace_id" => forged_id,
            "execution_workspace_id" => forged_id,
            "identifier" => "FORGED-999",
            "issue_number" => 999,
            "origin_type" => "forged",
            "origin_id" => "forged",
            "request_depth" => 999,
            "execution_state" => %{"forged" => true},
            "monitor_state" => %{"forged" => true},
            "lineage" => %{"forged" => true},
            "actor_type" => "agent",
            "actor_id" => forged_id
          }
        })

      %{"data" => %{"id" => issue_id}} = json_response(conn, 201)
      issue = Cympho.Repo.get!(Cympho.Issues.Issue, issue_id)

      assert issue.company_id == company.id
      assert issue.created_by_user_id == user.id
      assert issue.project_id == project.id
      assert issue.identifier != "FORGED-999"
      assert issue.issue_number != 999
      assert is_nil(issue.created_by_agent_id)
      assert is_nil(issue.last_reviewer_id)
      assert is_nil(issue.checkout_run_id)
      assert is_nil(issue.project_workspace_id)
      assert is_nil(issue.execution_workspace_id)
      assert is_nil(issue.origin_type)
      assert is_nil(issue.origin_id)
      assert issue.request_depth == 0
      assert issue.execution_state == %{}
      assert issue.monitor_state == %{}
      refute issue.lineage == %{"forged" => true}
    end
  end

  describe "GET /api/issues/:id" do
    test "returns an issue with parent_id", %{conn: conn, project: project, company: company} do
      {:ok, parent} =
        Cympho.Issues.create_issue(%{
          "title" => "Parent Issue",
          "description" => "The parent",
          "project_id" => project.id,
          "company_id" => company.id
        })

      {:ok, child} =
        Cympho.Issues.create_issue(%{
          "title" => "Child Issue",
          "description" => "The child",
          "project_id" => project.id,
          "parent_id" => parent.id,
          "company_id" => company.id
        })

      conn = get(conn, "/api/issues/#{child.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["title"] == "Child Issue"
      assert data["parent_id"] == parent.id
    end

    test "returns 404 for non-existent issue", %{conn: conn} do
      conn = get(conn, "/api/issues/00000000-0000-0000-0000-000000000000")
      assert %{"errors" => _} = json_response(conn, 404)
    end
  end
end
