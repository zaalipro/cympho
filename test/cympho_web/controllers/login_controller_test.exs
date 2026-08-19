defmodule CymphoWeb.LoginControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Companies
  alias Cympho.Repo
  alias Cympho.UserAuthJWT

  test "API login selects a real membership when users.company_id is stale", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Cympho.Authentication.register_user(%{
        email: "api-login-#{unique}@example.com",
        name: "API Login",
        password: "password1234"
      })

    {:ok, member_company} =
      Companies.create_company(%{name: "Member #{unique}", slug: "member-api-#{unique}"})

    {:ok, stale_company} =
      Companies.create_company(%{name: "Stale #{unique}", slug: "stale-api-#{unique}"})

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: member_company.id,
        role: "member"
      })

    {:ok, _user} = user |> Ecto.Changeset.change(company_id: stale_company.id) |> Repo.update()

    conn =
      post(conn, "/api/login", %{
        "user" => %{
          "email" => " API-LOGIN-#{unique}@EXAMPLE.COM ",
          "password" => "password1234"
        }
      })

    response = json_response(conn, 200)
    assert response["data"]["company_id"] == member_company.id
    assert {:ok, claims} = UserAuthJWT.verify_token(response["token"])
    assert claims["company_id"] == member_company.id
  end
end
