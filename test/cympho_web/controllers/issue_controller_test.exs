defmodule CymphoWeb.IssueControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Projects

  setup %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn)

    {:ok, project} =
      Projects.create_project(%{
        name: "Test Project",
        prefix: "TST",
        company_id: company.id
      })

    %{conn: conn, project: project, company: company}
  end

  describe "POST /api/issues" do
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
