defmodule CymphoWeb.LabelControllerTest do
  use CymphoWeb.ConnCase
  alias Cympho.Labels

  test "index lists labels", %{conn: conn} do
    Labels.create_label(%{name: "Test"})
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

  test "show returns label", %{conn: conn} do
    {:ok, label} = Labels.create_label(%{name: "ShowMe"})
    conn = get(conn, ~p"/api/labels/#{label.id}")
    assert json_response(conn, 200)["data"]["name"] == "ShowMe"
  end

  test "show 404", %{conn: conn} do
    conn = get(conn, ~p"/api/labels/#{Ecto.UUID.generate()}")
    assert json_response(conn, 404)
  end

  test "update changes label", %{conn: conn} do
    {:ok, label} = Labels.create_label(%{name: "Old"})
    conn = patch(conn, ~p"/api/labels/#{label.id}", label: %{name: "New"})
    assert json_response(conn, 200)["data"]["name"] == "New"
  end

  test "delete removes label", %{conn: conn} do
    {:ok, label} = Labels.create_label(%{name: "Bye"})
    conn = delete(conn, ~p"/api/labels/#{label.id}")
    assert conn.status == 204
  end
end
