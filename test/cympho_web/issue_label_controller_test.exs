defmodule CymphoWeb.IssueLabelControllerTest do
  use CymphoWeb.ConnCase
  alias Cympho.Issues
  alias Cympho.Labels
  alias Cympho.Projects

  setup do
    {:ok, project} = Projects.create_project(%{name: "Test", prefix: "TST"})
    {:ok, issue} = Issues.create_issue(%{title: "Test", description: "Desc", project_id: project.id})
    {:ok, label} = Labels.create_label(%{name: "Bug", color: "#FF0000"})
    %{issue: issue, label: label}
  end

  test "index returns empty", %{conn: conn, issue: issue} do
    conn = get(conn, ~p"/api/issues/#{issue.id}/labels")
    assert json_response(conn, 200)["data"] == []
  end

  test "adds label", %{conn: conn, issue: issue, label: label} do
    conn = post(conn, ~p"/api/issues/#{issue.id}/labels", label_id: label.id)
    assert length(json_response(conn, 200)["data"]) == 1
  end

  test "removes label", %{conn: conn, issue: issue, label: label} do
    Issues.add_label_to_issue(issue, label)
    conn = delete(conn, ~p"/api/issues/#{issue.id}/labels/#{label.id}")
    assert conn.status == 204
  end
end
