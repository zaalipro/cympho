defmodule CymphoWeb.OwnAnswerFocusTest do
  @moduledoc """
  Choosing "Or write your own answer" moves the caret into its text box (smoke
  B9). A delegated listener in app.js does it (its behaviour is covered by
  test/js/own_answer_focus_test.mjs); this keeps it in app.js and pins the
  markup it relies on, on the pages that ask: the own radio and its text box
  share one `.opt-w` row.
  """
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.R3Fixtures

  setup do
    nw = R3Fixtures.northwind!()
    %{nw: nw, conn: session_conn(nw.user, nw.company)}
  end

  test "app.js moves the caret on change and on click" do
    js = File.read!(Path.join(File.cwd!(), "assets/js/app.js"))

    assert js =~ "function focusOwnAnswer(e)"
    assert js =~ "radio.closest('.opt-w')?.querySelector('.own-box textarea')?.focus();"
    assert js =~ "document.addEventListener('change', focusOwnAnswer);"
    assert js =~ "document.addEventListener('click', focusOwnAnswer);"
  end

  test "the Inbox question keeps the own radio and its text box in one row", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/inbox?kind=question")
    assert_own_row(view)
  end

  test "the task's question keeps the own radio and its text box in one row", %{
    conn: conn,
    nw: nw
  } do
    {:ok, view, _html} = live(conn, "/issues/#{nw.issues["NW-6"].id}")
    assert_own_row(view)
  end

  defp assert_own_row(view) do
    form = view |> render() |> Floki.parse_fragment!() |> Floki.find(".next form.ink")

    assert [row] =
             form
             |> Floki.find(".opt-w")
             |> Enum.filter(&(Floki.find(&1, "input.opt-in[value='own']") != []))

    assert [_] = Floki.find(row, ".own-box textarea[name='own_response']")
    # The numbered rows have no text box of their own, so choosing one keeps its focus.
    assert form |> Floki.find(".own-box textarea") |> length() == 1
  end

  defp session_conn(user, company) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_id", user.id)
    |> Plug.Conn.put_session("company_id", company.id)
  end
end
