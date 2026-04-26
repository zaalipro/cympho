defmodule CymphoWeb.WorkProductControllerTest do
  use CymphoWeb.ConnCase
  alias Cympho.Issues
  alias Cympho.Projects
  alias Cympho.WorkProducts

  setup do
    {:ok, project} = Projects.create_project(%{name: "Test Project", prefix: "TST"})
    {:ok, issue} = Issues.create_issue(%{title: "Test Issue", description: "Desc", project_id: project.id})
    %{issue: issue}
  end

  describe "POST /api/issues/:issue_id/work-products" do
    test "creates work product with valid data", %{conn: conn, issue: issue} do
      attrs = %{kind: "code_change", title: "Implementation PR", description: "PR #42"}
      conn = post(conn, "/api/issues/#{issue.id}/work-products", work_product: attrs)
      assert json_response(conn, 201)["data"]["title"] == "Implementation PR"
      assert json_response(conn, 201)["data"]["kind"] == "code_change"
    end

    test "returns 422 for invalid kind", %{conn: conn, issue: issue} do
      attrs = %{kind: "invalid_kind", title: "Test"}
      conn = post(conn, "/api/issues/#{issue.id}/work-products", work_product: attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end

    test "returns 422 for missing required fields", %{conn: conn, issue: issue} do
      conn = post(conn, "/api/issues/#{issue.id}/work-products", work_product: %{})
      assert json_response(conn, 422)["errors"] != %{}
    end

    test "returns 422 for missing title", %{conn: conn, issue: issue} do
      attrs = %{kind: "document"}
      conn = post(conn, "/api/issues/#{issue.id}/work-products", work_product: attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end

    test "returns 422 for missing kind", %{conn: conn, issue: issue} do
      attrs = %{title: "Test Title"}
      conn = post(conn, "/api/issues/#{issue.id}/work-products", work_product: attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end

    test "creates work product with optional fields", %{conn: conn, issue: issue} do
      attrs = %{
        kind: "url",
        title: "Design Doc",
        description: "Figma link",
        url: "https://figma.com/design",
        metadata: %{"version" => "1.0"}
      }
      conn = post(conn, "/api/issues/#{issue.id}/work-products", work_product: attrs)
      assert json_response(conn, 201)["data"]["url"] == "https://figma.com/design"
      assert json_response(conn, 201)["data"]["metadata"] == %{"version" => "1.0"}
    end
  end

  describe "GET /api/issues/:issue_id/work-products" do
    test "returns empty list when no work products", %{conn: conn, issue: issue} do
      conn = get(conn, "/api/issues/#{issue.id}/work-products")
      assert json_response(conn, 200)["data"] == []
    end

    test "returns work products ordered newest first", %{conn: conn, issue: issue} do
      {:ok, wp1} = WorkProducts.create_work_product(%{issue_id: issue.id, kind: "document", title: "First"})
      {:ok, wp2} = WorkProducts.create_work_product(%{issue_id: issue.id, kind: "code_change", title: "Second"})
      conn = get(conn, "/api/issues/#{issue.id}/work-products")
      data = json_response(conn, 200)["data"]
      assert length(data) == 2
      assert Enum.map(data, & &1["title"]) == ["Second", "First"]
    end
  end

  describe "GET /api/issues/:issue_id/work-products/:id" do
    test "returns work product", %{conn: conn, issue: issue} do
      {:ok, wp} = WorkProducts.create_work_product(%{issue_id: issue.id, kind: "artifact", title: "Test WP"})
      conn = get(conn, "/api/issues/#{issue.id}/work-products/#{wp.id}")
      assert json_response(conn, 200)["data"]["title"] == "Test WP"
    end

    test "returns 404 for non-existent work product", %{conn: conn, issue: issue} do
      conn = get(conn, "/api/issues/#{issue.id}/work-products/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end

  describe "PATCH /api/issues/:issue_id/work-products/:id" do
    test "updates work product", %{conn: conn, issue: issue} do
      {:ok, wp} = WorkProducts.create_work_product(%{issue_id: issue.id, kind: "document", title: "Old Title"})
      conn = patch(conn, "/api/issues/#{issue.id}/work-products/#{wp.id}", work_product: %{title: "New Title"})
      assert json_response(conn, 200)["data"]["title"] == "New Title"
    end

    test "returns 422 for invalid kind on update", %{conn: conn, issue: issue} do
      {:ok, wp} = WorkProducts.create_work_product(%{issue_id: issue.id, kind: "document", title: "Test"})
      conn = patch(conn, "/api/issues/#{issue.id}/work-products/#{wp.id}", work_product: %{kind: "bad"})
      assert json_response(conn, 422)["errors"] != %{}
    end

    test "returns 404 for non-existent work product", %{conn: conn, issue: issue} do
      conn = patch(conn, "/api/issues/#{issue.id}/work-products/#{Ecto.UUID.generate()}", work_product: %{title: "New"})
      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/issues/:issue_id/work-products/:id" do
    test "deletes work product", %{conn: conn, issue: issue} do
      {:ok, wp} = WorkProducts.create_work_product(%{issue_id: issue.id, kind: "other", title: "To Delete"})
      conn = delete(conn, "/api/issues/#{issue.id}/work-products/#{wp.id}")
      assert conn.status == 204
      conn = get(conn, "/api/issues/#{issue.id}/work-products")
      assert json_response(conn, 200)["data"] == []
    end

    test "returns 404 for non-existent work product", %{conn: conn, issue: issue} do
      conn = delete(conn, "/api/issues/#{issue.id}/work-products/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end
end