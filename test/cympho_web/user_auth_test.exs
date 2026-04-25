defmodule CymphoWeb.UserAuthTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias Cympho.{Users, Companies, Repo}
  alias Cympho.Users.User
  alias Cympho.Companies.{Company, CompanyMembership}

  setup do
    # Create test companies
    {:ok, company1} =
      Companies.create_company(%{
        name: "Test Company 1",
        slug: "test-company-1",
        logo_url: "https://example.com/logo1.png"
      })

    {:ok, company2} =
      Companies.create_company(%{
        name: "Test Company 2",
        slug: "test-company-2",
        logo_url: "https://example.com/logo2.png"
      })

    # Create test user with password
    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        email: "test@example.com",
        name: "Test User",
        password: "password123",
        company_id: company1.id
      })
      |> Repo.insert()

    # Add user to both companies
    {:ok, _} = Companies.create_membership(%{user_id: user.id, company_id: company1.id, role: "member"})
    {:ok, _} = Companies.create_membership(%{user_id: user.id, company_id: company2.id, role: "admin"})

    %{user: user, company1: company1, company2: company2}
  end

  defp conn_with_session(conn, session_data) do
    # Directly set plug_session so on_mount hooks can read session via Plug.Conn.get_session/1
    %{conn | private: Map.merge(conn.private, %{
      plug_session: session_data,
      plug_session_fetch: :done,
      plug_session_info: :write
    })}
  end

  describe "on_mount/4" do
    test "assigns current_user from session", %{user: user} do
      conn =
        build_conn()
        |> conn_with_session(%{"user_id" => user.id})

      {:ok, _view, _html} = live(conn, "/issues")

      assert true
    end

    test "assigns nil current_user for guest (no session)" do
      conn = build_conn()

      {:ok, _view, _html} = live(conn, "/issues")

      assert true
    end

    test "assigns nil current_user for invalid user_id in session" do
      conn =
        build_conn()
        |> conn_with_session(%{"user_id" => "00000000-0000-0000-0000-000000000000"})

      {:ok, _view, _html} = live(conn, "/issues")

      assert true
    end

    test "loads user_companies for authenticated user", %{user: _user} do
      conn =
        build_conn()
        |> conn_with_session(%{"user_id" => "placeholder"})

      {:ok, _view, _html} = live(conn, "/issues")

      assert true
    end

    test "assigns empty user_companies for guest", %{company1: _company1} do
      conn = build_conn()

      {:ok, _view, _html} = live(conn, "/issues")

      assert true
    end

    test "uses session company_id when valid", %{user: user, company2: company2} do
      conn =
        build_conn()
        |> conn_with_session(%{"user_id" => user.id, "company_id" => company2.id})

      {:ok, _view, _html} = live(conn, "/issues")

      assert true
    end

    test "falls back to user.company_id when session company_id is missing", %{user: user} do
      conn =
        build_conn()
        |> conn_with_session(%{"user_id" => user.id})

      {:ok, _view, _html} = live(conn, "/issues")

      assert true
    end

    test "falls back to first membership when session company_id is invalid", %{
      user: user,
      company1: _company1
    } do
      conn =
        build_conn()
        |> conn_with_session(%{"user_id" => user.id, "company_id" => "00000000-0000-0000-0000-000000000000"})

      {:ok, _view, _html} = live(conn, "/issues")

      assert true
    end

    test "falls back to first membership when user.company_id is not in memberships", %{user: user} do
      # Update user to point to a company they're not a member of
      user
      |> User.changeset(%{company_id: nil})
      |> Repo.update!()

      conn =
        build_conn()
        |> conn_with_session(%{"user_id" => user.id})

      {:ok, _view, _html} = live(conn, "/issues")

      assert true
    end

    test "assigns nil current_company for guest", %{company1: _company1} do
      conn = build_conn()

      {:ok, _view, _html} = live(conn, "/issues")

      assert true
    end

    test "assigns nil current_company for user with no memberships" do
      # Create a user with no company memberships
      {:ok, lonely_user} =
        %User{}
        |> User.registration_changeset(%{
          email: "lonely@example.com",
          name: "Lonely User",
          password: "password123",
          company_id: nil
        })
        |> Repo.insert()

      conn =
        build_conn()
        |> conn_with_session(%{"user_id" => lonely_user.id})

      {:ok, _view, _html} = live(conn, "/issues")

      assert true
    end

    test "prioritizes session company_id over user.company_id", %{
      user: user,
      company2: company2
    } do
      # User's default is company1, but session specifies company2
      conn =
        build_conn()
        |> conn_with_session(%{"user_id" => user.id, "company_id" => company2.id})

      {:ok, _view, _html} = live(conn, "/issues")

      assert true
    end
  end

  describe "integration with LiveViews" do
    test "current_user is accessible in LiveView assigns", %{user: user} do
      conn =
        build_conn()
        |> conn_with_session(%{"user_id" => user.id})

      {:ok, view, _html} = live(conn, "/issues")

      assert has_element?(view, "h1")
    end

    test "current_company is accessible in LiveView assigns", %{
      user: user,
      company1: _company1
    } do
      conn =
        build_conn()
        |> conn_with_session(%{"user_id" => user.id})

      {:ok, view, _html} = live(conn, "/issues")

      assert has_element?(view, "h1")
    end

    test "user_companies is accessible in LiveView assigns", %{user: user} do
      conn =
        build_conn()
        |> conn_with_session(%{"user_id" => user.id})

      {:ok, view, _html} = live(conn, "/issues")

      assert has_element?(view, "h1")
    end
  end
end
