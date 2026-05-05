defmodule CymphoWeb.SearchControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Issues
  alias Cympho.Comments

  setup %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn)

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Searchable test issue",
        description: "This issue is searchable via API endpoint",
        status: :todo,
        priority: :high,
        company_id: company.id
      })

    {:ok, _comment} =
      Comments.create_comment(%{
        body: "Comment about the searchable endpoint",
        author_type: "user",
        author_id: "00000000-0000-0000-0000-000000000001",
        issue_id: issue.id
      })

    %{conn: conn, issue: issue, company: company}
  end

  describe "GET /api/search" do
    test "returns search results for valid query", %{conn: conn} do
      conn = get(conn, "/api/search?q=searchable")
      assert %{"issues" => issues, "comments" => comments} = json_response(conn, 200)
      assert is_list(issues)
      assert is_list(comments)
      assert length(issues) >= 1
    end

    test "returns empty results for non-matching query", %{conn: conn} do
      conn = get(conn, "/api/search?q=xyzzy_nonexistent_12345")
      assert %{"issues" => [], "comments" => []} = json_response(conn, 200)
    end

    test "returns 400 for missing query parameter", %{conn: conn} do
      conn = get(conn, "/api/search")
      assert conn.status == 400
    end

    test "returns 400 for empty query parameter", %{conn: conn} do
      conn = get(conn, "/api/search?q=")
      assert conn.status == 400
    end

    test "issue results include expected fields", %{conn: conn} do
      conn = get(conn, "/api/search?q=searchable")
      %{"issues" => [issue | _]} = json_response(conn, 200)
      assert Map.has_key?(issue, "id")
      assert Map.has_key?(issue, "title")
      assert Map.has_key?(issue, "status")
      assert Map.has_key?(issue, "priority")
    end
  end
end
