defmodule CymphoWeb.CompanyControllerTest do
  use CymphoWeb.ConnCase, async: true

  test "regular members cannot export a company", %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{role: "member"})

    conn = get(conn, ~p"/api/companies/#{company.id}/export")

    assert %{"errors" => [%{"detail" => "Forbidden"}]} = json_response(conn, 403)
  end

  test "company admins can export a company", %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{role: "admin"})

    conn = get(conn, ~p"/api/companies/#{company.id}/export")

    assert %{"data" => %{"company" => %{"id" => company_id}}} = json_response(conn, 200)
    assert company_id == company.id
  end

  test "board members can export a company", %{conn: conn} do
    {conn, _user, company} =
      register_and_log_in_user(conn, %{role: "member", is_board_member: true})

    conn = get(conn, ~p"/api/companies/#{company.id}/export")

    assert %{"data" => %{"company" => %{"id" => company_id}}} = json_response(conn, 200)
    assert company_id == company.id
  end
end
