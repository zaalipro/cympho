defmodule CymphoWeb.UserAuthTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias Cympho.{Companies, Repo}
  alias Cympho.Users.User

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
    Companies.create_membership!(%{user_id: user.id, company_id: company1.id, role: "member"})
    Companies.create_membership!(%{user_id: user.id, company_id: company2.id, role: "admin"})

    %{user: user, company1: company1, company2: company2}
  end

  describe "on_mount/4" do
    test "assigns current_user from session", %{user: user} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_user.id == user.id
    end

    test "assigns nil current_user for guest (no session)" do
      conn = build_conn() |> Plug.Test.init_test_session(%{})

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_user == nil
    end

    test "assigns nil current_user for invalid user_id in session" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", "00000000-0000-0000-0000-000000000000")

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_user == nil
    end

    test "loads user_companies for authenticated user", %{user: user} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert length(live_assigns(view).user_companies) == 2
    end

    test "guest user gets empty company list (no cross-tenant enumeration)", %{
      company1: _company1,
      company2: _company2
    } do
      conn = build_conn() |> Plug.Test.init_test_session(%{})

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).user_companies == []
    end

    test "uses session company_id when valid", %{user: user, company2: company2} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company2.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_company.id == company2.id
    end

    test "falls back to user.company_id when session company_id is missing", %{
      user: user,
      company1: company1
    } do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_company.id == company1.id
    end

    test "falls back to first membership when session company_id is invalid", %{
      user: user,
      company1: company1
    } do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", "00000000-0000-0000-0000-000000000000")

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_company.id == company1.id
    end

    test "falls back to first membership when user.company_id is not in memberships", %{
      user: user,
      company1: company1
    } do
      # Update user to point to a company they're not a member of
      user
      |> User.changeset(%{company_id: nil})
      |> Repo.update!()

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, _html} = live(conn, "/issues")

      # Should fall back to first company in memberships
      assert live_assigns(view).current_company.id == company1.id
    end

    test "guest user gets nil current_company (no cross-tenant access)", %{company1: _company1} do
      conn = build_conn() |> Plug.Test.init_test_session(%{})

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_company == nil
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
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", lonely_user.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_company == nil
    end

    test "prioritizes session company_id over user.company_id", %{
      user: user,
      company2: company2
    } do
      # User's default is company1, but session specifies company2
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company2.id)

      {:ok, view, _html} = live(conn, "/issues")

      # Should use company2 from session, not user's default
      assert live_assigns(view).current_company.id == company2.id
    end
  end

  describe "integration with LiveViews" do
    test "current_user is accessible in LiveView assigns", %{user: user} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_user.id == user.id
    end

    test "current_company is accessible in LiveView assigns", %{
      user: user,
      company1: company1
    } do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert live_assigns(view).current_company.id == company1.id
    end

    test "user_companies is accessible in LiveView assigns", %{user: user} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)

      {:ok, view, _html} = live(conn, "/issues")

      assert length(live_assigns(view).user_companies) == 2
    end
  end

  defp live_assigns(view) do
    :sys.get_state(view.pid).socket.assigns
  end
end
