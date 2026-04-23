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
      import Phoenix.VerifiedRoutes
      import CymphoWeb.ConnCase

      alias CymphoWeb.Router.Helpers, as: Routes

      @endpoint CymphoWeb.Endpoint
      @router CymphoWeb.Router
    end
  end

  setup tags do
    Cympho.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
