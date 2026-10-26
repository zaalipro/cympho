defmodule CymphoWeb.R3PageHelpers do
  @moduledoc """
  Page-level assertions for the Paper & Ink pages (v7 spec §3.1 C).

      import CymphoWeb.R3PageHelpers

      {:ok, view, _html} = live(conn, "/goals/\#{goal.id}")
      doc = main_doc(view)
      assert_r3_page(doc, page: "goal", h1: goal.title, kind: :deep, parent: "Goals", primaries: 0)

  `main_doc/1` takes a LiveView (rendered with `render/1`) or an HTML string.
  """
  import ExUnit.Assertions

  @doc "The rendered page as a Floki document."
  def main_doc(%Phoenix.LiveViewTest.View{} = view),
    do: view |> Phoenix.LiveViewTest.render() |> main_doc()

  def main_doc(html) when is_binary(html), do: Floki.parse_document!(html)

  @doc "The text of everything `selector` matches, whitespace squished."
  def text(doc, selector), do: doc |> Floki.find(selector) |> Floki.text() |> squish()

  @doc "The squished text of each element `selector` matches."
  def texts(doc, selector),
    do: doc |> Floki.find(selector) |> Enum.map(&(&1 |> Floki.text() |> squish()))

  @doc """
  Asserts the r3 page contract: the frame (`page`, `data-ui-complex-page`),
  exactly one H1 reading `h1`, a deep page's breadcrumb parent, and the number of
  primaries (`.pw`), every one of them on an ink card.

  Options: `page:`, `h1:`, `kind:` (`:root` | `:deep`), `parent:` (the parent's
  label, deep pages), `primaries:` (0 or 1).
  """
  def assert_r3_page(doc, opts) do
    page = Keyword.fetch!(opts, :page)

    assert Floki.find(doc, ~s(.frame[data-page="#{page}"][data-ui-complex-page])) != [],
           "no .frame[data-page=#{inspect(page)}][data-ui-complex-page]"

    assert texts(doc, "h1") == [Keyword.fetch!(opts, :h1)]

    case Keyword.get(opts, :kind, :root) do
      :deep ->
        assert Floki.find(doc, ~s(header.ctx[data-ctx="deep"])) != [], "not a deep page header"
        assert texts(doc, ".crumb .back") == [Keyword.fetch!(opts, :parent)]

      :root ->
        assert Floki.find(doc, ~s(header.ctx[data-ctx="root"])) != [], "not a root page header"
    end

    if Keyword.has_key?(opts, :primaries) do
      primaries = Floki.find(doc, ".pw")
      assert length(primaries) == Keyword.fetch!(opts, :primaries)

      assert length(Floki.find(doc, ".ink .pw")) == length(primaries),
             "a .pw outside an .ink card"
    end

    doc
  end

  defp squish(text), do: text |> String.split() |> Enum.join(" ")
end
