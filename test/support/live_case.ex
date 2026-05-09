defmodule CymphoWeb.LiveCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require Phoenix.LiveView
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import CymphoWeb.LiveCase

      @endpoint CymphoWeb.Endpoint
    end
  end

  def conn, do: Process.get(:cympho_live_case_conn) || authenticated_conn()

  setup tags do
    Cympho.DataCase.setup_sandbox(tags)
    conn = authenticated_conn()
    {:ok, conn: conn, current_company: current_company()}
  end

  def authenticated_conn(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Cympho.Users.create_user(%{
        email: Map.get(attrs, :email, "live-user-#{unique}@example.com"),
        name: Map.get(attrs, :name, "Live User #{unique}"),
        password: Map.get(attrs, :password, "password1234")
      })

    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: Map.get(attrs, :company_name, "Live Co #{unique}"),
        slug: Map.get(attrs, :company_slug, "live-co-#{unique}")
      })

    {:ok, _membership} =
      Cympho.Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: Map.get(attrs, :role, "member"),
        is_board_member: Map.get(attrs, :is_board_member, false)
      })

    Process.put(:cympho_live_case_company, company)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)
      |> Plug.Conn.put_session(:company_id, company.id)

    Process.put(:cympho_live_case_conn, conn)
    conn
  end

  def current_company, do: Process.get(:cympho_live_case_company)

  def current_company_id do
    case current_company() do
      %{id: id} -> id
      _ -> nil
    end
  end

  def scoped_attrs(attrs, company_id \\ current_company_id()) do
    cond do
      is_nil(company_id) -> attrs
      Map.has_key?(attrs, :company_id) or Map.has_key?(attrs, "company_id") -> attrs
      true -> Map.put(attrs, :company_id, company_id)
    end
  end
end
