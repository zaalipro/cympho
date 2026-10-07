defmodule CymphoWeb.CompanySwitcherControllerTest do
  use CymphoWeb.ConnCase, async: false

  alias Cympho.Companies
  alias Cympho.Users.User

  setup %{conn: conn} do
    unique = System.unique_integer([:positive])

    user =
      %User{}
      |> User.registration_changeset(%{
        email: "switcher-#{unique}@example.com",
        name: "Switcher #{unique}",
        password: "password123"
      })
      |> Cympho.Repo.insert!()

    {:ok, company} =
      Companies.create_company(%{
        name: "Switcher Co #{unique}",
        slug: "switcher-co-#{unique}"
      })

    {:ok, _} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: "admin"
      })

    conn = Plug.Test.init_test_session(conn, user_id: user.id)

    %{conn: conn, user: user, company: company}
  end

  describe "switch/2 return_to handling" do
    test "overview workflow links switch authorized companies only", %{
      conn: conn,
      user: user,
      company: company
    } do
      unique = System.unique_integer([:positive])
      {:ok, b} = Companies.create_company(%{name: "Authorized B", slug: "authorized-b-#{unique}"})

      {:ok, c} =
        Companies.create_company(%{name: "Unauthorized C", slug: "unauthorized-c-#{unique}"})

      {:ok, membership} =
        Companies.create_membership(%{user_id: user.id, company_id: b.id, role: "viewer"})

      conn = put_session(conn, :company_id, company.id)
      switched = get(conn, "/switch-company/#{b.id}?return_to=%2Fissues")
      assert redirected_to(switched) == "/issues"
      assert get_session(switched, :company_id) == b.id
      forged = get(conn, "/switch-company/#{c.id}?return_to=%2Fissues%2F#{Ecto.UUID.generate()}")
      assert redirected_to(forged) == "/"
      assert get_session(forged, :company_id) == company.id
      Cympho.Repo.delete!(membership)
      revoked = get(conn, "/switch-company/#{b.id}?return_to=%2Freviews")
      assert redirected_to(revoked) == "/"
      assert get_session(revoked, :company_id) == company.id
    end

    test "follows a genuine relative path", %{conn: conn, company: company} do
      conn = get(conn, ~p"/switch-company/#{company.id}", %{"return_to" => "/issues"})
      assert redirected_to(conn) == "/issues"
    end

    # `//evil.com` satisfies String.starts_with?(path, "/") but browsers treat
    # it as a protocol-relative URL and leave the site.
    test "rejects a protocol-relative //host redirect", %{conn: conn, company: company} do
      conn = get(conn, ~p"/switch-company/#{company.id}", %{"return_to" => "//evil.com"})
      assert redirected_to(conn) == "/"
    end

    test "rejects a backslash protocol-relative redirect", %{conn: conn, company: company} do
      conn = get(conn, ~p"/switch-company/#{company.id}", %{"return_to" => "/\\evil.com"})
      assert redirected_to(conn) == "/"
    end

    test "rejects an absolute external URL", %{conn: conn, company: company} do
      conn = get(conn, ~p"/switch-company/#{company.id}", %{"return_to" => "https://evil.com"})
      assert redirected_to(conn) == "/"
    end
  end
end
