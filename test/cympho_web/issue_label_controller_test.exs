defmodule CymphoWeb.IssueLabelControllerTest do
  use CymphoWeb.ConnCase
  alias Cympho.Issues
  alias Cympho.Labels
  alias Cympho.Projects

  setup %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{role: "admin"})

    {:ok, project} =
      Projects.create_project(%{name: "Test", prefix: "TST", company_id: company.id})

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Test",
        description: "Desc",
        project_id: project.id,
        company_id: company.id
      })

    {:ok, label} = Labels.create_label(%{name: "Bug", color: "#FF0000", company_id: company.id})
    %{conn: conn, issue: issue, label: label}
  end

  test "index returns empty", %{conn: conn, issue: issue} do
    conn = get(conn, ~p"/api/issues/#{issue.id}/labels")
    assert json_response(conn, 200)["data"] == []
  end

  test "adds label", %{conn: conn, issue: issue, label: label} do
    conn = post(conn, ~p"/api/issues/#{issue.id}/labels", label_id: label.id)
    assert length(json_response(conn, 200)["data"]) == 1
  end

  test "set rejects foreign labels without replacing existing labels", %{
    conn: conn,
    issue: issue,
    label: label
  } do
    suffix = System.unique_integer([:positive])

    {:ok, other_company} =
      Cympho.Companies.create_company(%{
        name: "Foreign issue-label API company #{suffix}",
        slug: "foreign-issue-label-api-company-#{suffix}"
      })

    {:ok, foreign_label} =
      Labels.create_label(%{
        name: "Foreign API label #{suffix}",
        color: "#AABBCC",
        company_id: other_company.id
      })

    assert {:ok, _} = Issues.add_label_to_issue(issue, label)

    conn =
      put(conn, ~p"/api/issues/#{issue.id}/labels", label_ids: [label.id, foreign_label.id])

    assert conn.status == 404
    assert Enum.map(Issues.get_issue!(issue.id).labels, & &1.id) == [label.id]
  end

  test "removes label", %{conn: conn, issue: issue, label: label} do
    Issues.add_label_to_issue(issue, label)
    conn = delete(conn, ~p"/api/issues/#{issue.id}/labels/#{label.id}")
    assert conn.status == 204
  end
end
