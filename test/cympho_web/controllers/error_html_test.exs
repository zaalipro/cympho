defmodule CymphoWeb.ErrorHTMLTest do
  use CymphoWeb.ConnCase, async: true

  test "renders a forbidden response" do
    html =
      CymphoWeb.ErrorHTML
      |> apply(:"403", [%{}])
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ "You do not have permission to perform this action."
  end
end
