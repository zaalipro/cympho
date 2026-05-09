defmodule CymphoWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import CymphoWeb.ConnCase

      use Phoenix.VerifiedRoutes,
        endpoint: CymphoWeb.Endpoint,
        router: CymphoWeb.Router,
        statics: CymphoWeb.static_paths()

      alias CymphoWeb.Router.Helpers, as: Routes

      @endpoint CymphoWeb.Endpoint
      @router CymphoWeb.Router
    end
  end

  setup tags do
    Cympho.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Creates a user, company, and membership, and authenticates the conn with a
  Bearer JWT issued for that user/company. Returns `{conn, user, company}`.
  """
  def register_and_log_in_user(conn, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: Map.get(attrs, :company_name, "Test Co #{unique}"),
        slug: Map.get(attrs, :company_slug, "test-co-#{unique}")
      })

    {:ok, user} =
      Cympho.Users.create_user(%{
        email: "user-#{unique}@example.com",
        name: "Test User #{unique}",
        password: "password1234"
      })

    {:ok, _membership} =
      Cympho.Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: Map.get(attrs, :role, "member"),
        is_board_member: Map.get(attrs, :is_board_member, false)
      })

    {:ok, token} = Cympho.UserAuthJWT.generate_token(user, company.id)

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)
      |> Plug.Conn.put_session(:company_id, company.id)
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)

    {conn, user, company}
  end
end
