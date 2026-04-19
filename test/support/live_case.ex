defmodule CymphoWeb.LiveCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require Phoenix.LiveView
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.LiveViewTest
      import CymphoWeb.LiveCase

      @endpoint CymphoWeb.Endpoint
    end
  end

  setup tags do
    Cympho.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
