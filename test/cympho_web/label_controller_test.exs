defmodule CymphoWeb.LabelControllerTest do
  use CymphoWeb.ConnCase
  alias Cympho.Labels

  setup %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn)
    {:ok, conn: conn, company: company}
  end

  test "index lists labels", %{conn: conn, company: company} do
    Labels.create_label(%{name: "Test", company_id: company.id})
    conn = get(conn, ~p"/api/labels")
    assert length(json_response(conn, 200)["data"]) >= 1
  end

  test "create returns label", %{conn: conn} do
    conn = post(conn, ~p"/api/labels", label: %{name: "New", color: "#FF0000"})
    assert json_response(conn, 201)["data"]["name"] == "New"
  end

  test "create invalid returns errors", %{conn: conn} do
    conn = post(conn, ~p"/api/labels", label: %{name: ""})
    assert json_response(conn, 422)["errors"] != %{}
  end

  test "show returns label", %{conn: conn, company: company} do
    {:ok, label} = Labels.create_label(%{name: "ShowMe", company_id: company.id})
    conn = get(conn, ~p"/api/labels/#{label.id}")
    assert json_response(conn, 200)["data"]["name"] == "ShowMe"
  end

  test "show 404", %{conn: conn} do
    conn = get(conn, ~p"/api/labels/#{Ecto.UUID.generate()}")
    assert json_response(conn, 404)
  end

  test "update changes label", %{conn: conn, company: company} do
    {:ok, label} = Labels.create_label(%{name: "Old", company_id: company.id})
    conn = patch(conn, ~p"/api/labels/#{label.id}", label: %{name: "New"})
    assert json_response(conn, 200)["data"]["name"] == "New"
  end

  test "delete removes label", %{conn: conn, company: company} do
    {:ok, label} = Labels.create_label(%{name: "Bye", company_id: company.id})
    conn = delete(conn, ~p"/api/labels/#{label.id}")
    assert conn.status == 204
  end
end
