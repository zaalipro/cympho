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

  test "API login refuses an address after repeated failures, even with the right password",
       %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Cympho.Authentication.register_user(%{
        email: "api-throttle-#{unique}@example.com",
        name: "API Throttle",
        password: "password1234"
      })

    ip = {198, 18, rem(div(unique, 256), 256), rem(unique, 256)}

    attempt = fn conn, password, ip ->
      post(%{conn | remote_ip: ip}, "/api/login", %{
        "user" => %{"email" => user.email, "password" => password}
      })
    end

    for _ <- 1..10 do
      assert json_response(attempt.(conn, "wrong-password", ip), 401)
    end

    assert %{"errors" => %{"detail" => error}} =
             json_response(attempt.(conn, "password1234", ip), 429)

    assert error =~ "Too many failed sign-in attempts"

    other_ip = {198, 19, rem(div(unique, 256), 256), rem(unique, 256)}
    assert json_response(attempt.(conn, "password1234", other_ip), 200)
  end
end
