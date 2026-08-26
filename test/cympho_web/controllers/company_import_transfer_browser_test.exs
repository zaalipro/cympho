defmodule CymphoWeb.CompanyImportTransferBrowserTest do
  use CymphoWeb.ConnCase, async: true

  test "browser transfer boundary uses the session and board guard without a bearer token", %{
    conn: conn
  } do
    {conn, _user, _company} =
      register_and_log_in_user(conn, %{role: "owner", is_board_member: true})

    conn =
      conn
      |> delete_req_header("authorization")
      |> put_req_header("accept", "application/json")
      |> post("/companies/import/transfers", %{})

    assert json_response(conn, 422) == %{"error" => "Invalid transfer declaration"}
  end

  test "browser transfer boundary rejects a non-board member", %{conn: conn} do
    {conn, _user, _company} = register_and_log_in_user(conn, %{role: "member"})

    conn =
      conn
      |> delete_req_header("authorization")
      |> put_req_header("accept", "application/json")
      |> post("/companies/import/transfers", %{})

    assert json_response(conn, 403) == %{
             "errors" => [%{"detail" => "No board members configured for this company"}]
           }
  end

  test "browser transfer boundary redirects an unauthenticated session", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post("/companies/import/transfers", %{})

    assert redirected_to(conn) == "/login?return_to=%2Fcompanies%2Fimport%2Ftransfers"
  end
end
