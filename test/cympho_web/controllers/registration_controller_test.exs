defmodule CymphoWeb.RegistrationControllerTest do
  use CymphoWeb.ConnCase, async: false

  alias Cympho.Companies

  @params %{
    "user" => %{"name" => "New", "email" => "new@example.com", "password" => "longenough1"}
  }

  test "returns 403 when registration is closed (default)", %{conn: conn} do
    conn = post(conn, "/api/register", @params)
    assert json_response(conn, 403)["error"] == "registration is invite-only"
    assert {:error, :not_found} = Cympho.Users.get_user_by_email("new@example.com")
  end

  test "creates a user when open_registration is enabled", %{conn: conn} do
    Application.put_env(:cympho, :open_registration, true)
    on_exit(fn -> Application.delete_env(:cympho, :open_registration) end)

    conn = post(conn, "/api/register", @params)
    assert json_response(conn, 201)
    assert {:ok, _user} = Cympho.Users.get_user_by_email("new@example.com")
  end

  test "closed registration atomically signs up a new invited recipient", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{name: "Invite Co #{unique}", slug: "invite-co-#{unique}"})

    {:ok, inviter} =
      Cympho.Authentication.register_user(%{
        email: "inviter-#{unique}@example.com",
        name: "Inviter",
        password: "password1234"
      })

    {:ok, invite} =
      Companies.create_invite(%{
        company_id: company.id,
        inviter_id: inviter.id,
        email: "  New.Recipient-#{unique}@Example.COM ",
        role: "member"
      })

    conn =
      post(conn, "/api/register", %{
        "invite_token" => invite.token,
        "user" => %{
          "name" => "New Recipient",
          "email" => "new.recipient-#{unique}@example.com",
          "password" => "password1234"
        }
      })

    assert %{"data" => %{"company_id" => company_id, "email" => email}} =
             json_response(conn, 201)

    assert company_id == company.id
    assert email == "new.recipient-#{unique}@example.com"
    assert {:ok, user} = Cympho.Users.get_user_by_email(" NEW.RECIPIENT-#{unique}@EXAMPLE.COM ")
    assert Companies.has_access?(user.id, company.id)
    assert {:ok, ^user} = Cympho.Authentication.authenticate_user(email, "password1234")
    assert Companies.get_invite_by_token(invite.token).status == "accepted"
  end

  test "an invite cannot register a different email", %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{name: "Bound Co #{unique}", slug: "bound-co-#{unique}"})

    {:ok, inviter} =
      Cympho.Authentication.register_user(%{
        email: "bound-inviter-#{unique}@example.com",
        name: "Inviter",
        password: "password1234"
      })

    intended_email = "intended-#{unique}@example.com"

    {:ok, invite} =
      Companies.create_invite(%{
        company_id: company.id,
        inviter_id: inviter.id,
        email: intended_email
      })

    conn =
      post(conn, "/api/register", %{
        "invite_token" => invite.token,
        "user" => %{
          "name" => "Attacker",
          "email" => "attacker-#{unique}@example.com",
          "password" => "password1234"
        }
      })

    assert json_response(conn, 422)["error"] == "email does not match invitation"
    assert {:error, :not_found} = Cympho.Users.get_user_by_email(intended_email)

    assert {:error, :not_found} =
             Cympho.Users.get_user_by_email("attacker-#{unique}@example.com")

    assert Companies.get_invite_by_token(invite.token).status == "pending"
  end

  test "an invite cannot replace an existing account's password", %{conn: conn} do
    unique = System.unique_integer([:positive])
    email = "existing-invite-#{unique}@example.com"

    {:ok, company} =
      Companies.create_company(%{name: "Existing Co #{unique}", slug: "existing-co-#{unique}"})

    {:ok, inviter} =
      Cympho.Authentication.register_user(%{
        email: "existing-inviter-#{unique}@example.com",
        name: "Inviter",
        password: "password1234"
      })

    {:ok, existing_user} =
      Cympho.Authentication.register_user(%{
        email: email,
        name: "Existing",
        password: "original-password"
      })

    {:ok, invite} =
      Companies.create_invite(%{
        company_id: company.id,
        inviter_id: inviter.id,
        email: email
      })

    conn =
      post(conn, "/api/register", %{
        "invite_token" => invite.token,
        "user" => %{
          "name" => "Existing",
          "email" => email,
          "password" => "attacker-password"
        }
      })

    assert json_response(conn, 422)["error"] =~ "account already exists"

    assert {:ok, authenticated} =
             Cympho.Authentication.authenticate_user(email, "original-password")

    assert authenticated.id == existing_user.id

    assert {:error, :invalid_credentials} =
             Cympho.Authentication.authenticate_user(email, "attacker-password")

    refute Companies.has_access?(existing_user.id, company.id)
    assert Companies.get_invite_by_token(invite.token).status == "pending"
  end

  test "open registration stores and authenticates a canonical email", %{conn: conn} do
    Application.put_env(:cympho, :open_registration, true)
    on_exit(fn -> Application.delete_env(:cympho, :open_registration) end)
    unique = System.unique_integer([:positive])
    canonical = "case-#{unique}@example.com"

    conn =
      post(conn, "/api/register", %{
        "user" => %{
          "name" => "Case User",
          "email" => "  CASE-#{unique}@Example.COM ",
          "password" => "password1234"
        }
      })

    assert get_in(json_response(conn, 201), ["data", "email"]) == canonical

    assert {:ok, user} =
             Cympho.Authentication.authenticate_user(
               " CASE-#{unique}@EXAMPLE.COM ",
               "password1234"
             )

    assert user.email == canonical
  end
end
