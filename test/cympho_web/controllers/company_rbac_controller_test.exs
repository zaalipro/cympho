defmodule CymphoWeb.CompanyRBACControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.{Companies, Goals, Issues}

  test "viewer can read goals but cannot create them", %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{role: "viewer"})
    {:ok, _goal} = Goals.create_goal(%{title: "Visible goal", company_id: company.id})

    assert %{"data" => [_]} = conn |> get(~p"/api/goals") |> json_response(200)

    denied =
      conn
      |> recycle()
      |> post(~p"/api/goals", %{"goal" => %{"title" => "Forbidden goal"}})

    assert %{"errors" => [%{"detail" => "Forbidden"}]} = json_response(denied, 403)
    assert Enum.map(Goals.list_goals_by_company(company.id), & &1.title) == ["Visible goal"]
  end

  test "member can create ordinary work but cannot delete it", %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{role: "member"})

    created =
      conn
      |> post(~p"/api/goals", %{"goal" => %{"title" => "Member goal"}})
      |> json_response(201)

    goal_id = created["data"]["id"]

    denied = conn |> recycle() |> delete(~p"/api/goals/#{goal_id}")
    assert %{"errors" => [%{"detail" => "Forbidden"}]} = json_response(denied, 403)
    assert {:ok, _goal} = Goals.get_company_goal(company.id, goal_id)
  end

  test "viewer is denied across labels, documents, routines, and workspaces", %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{role: "viewer"})
    {:ok, issue} = Issues.create_issue(%{title: "Viewer target", company_id: company.id})

    label_conn =
      conn
      |> post(~p"/api/labels", %{"label" => %{"name" => "No", "color" => "#112233"}})

    assert json_response(label_conn, 403)

    document_conn =
      conn
      |> recycle()
      |> put(~p"/api/issues/#{issue.id}/documents/plan", %{"body" => "No"})

    assert json_response(document_conn, 403)

    routine_conn =
      conn
      |> recycle()
      |> post(~p"/api/routines", %{"routine" => %{"name" => "No"}})

    assert json_response(routine_conn, 403)

    workspace_conn =
      conn
      |> recycle()
      |> post(~p"/api/workspaces", %{"project_workspace" => %{"name" => "No"}})

    assert json_response(workspace_conn, 403)
  end

  test "admin can delete company work", %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{role: "admin"})
    {:ok, goal} = Goals.create_goal(%{title: "Admin cleanup", company_id: company.id})

    assert conn |> delete(~p"/api/goals/#{goal.id}") |> response(204)
    assert {:error, :not_found} = Goals.get_company_goal(company.id, goal.id)
  end

  test "only an owner can delete the company itself", %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{role: "admin"})

    denied = delete(conn, ~p"/api/companies/#{company.id}")

    assert %{"errors" => [%{"detail" => "Forbidden"}]} = json_response(denied, 403)
    assert Companies.get_company!(company.id).id == company.id
  end
end
