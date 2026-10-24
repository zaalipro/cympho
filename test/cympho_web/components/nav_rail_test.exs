defmodule CymphoWeb.Components.NavRailTest do
  # r3: rewritten for the n2 Main navigation (six destinations with their pages,
  # one Inbox count); the old sidebar sections, agent rows and Approvals badge are gone.
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias CymphoWeb.Components.NavRail

  defp render_rail(opts) do
    render_component(&NavRail.nav_rail/1, Keyword.merge([current_path: "/"], opts))
  end

  defp nav(opts), do: opts |> render_rail() |> Floki.parse_fragment!()

  defp current(doc) do
    doc
    |> Floki.find("a.d[aria-current]")
    |> Enum.map(fn a ->
      {a |> Floki.find(".lbl") |> Floki.text(), a |> Floki.attribute("aria-current") |> hd()}
    end)
  end

  test "renders the six destinations in N1 order as the Main navigation" do
    doc = nav([])

    assert [_] = Floki.find(doc, ~s(nav.dest[aria-label="Main"]))
    labels = doc |> Floki.find("a.d .lbl") |> Enum.map(&Floki.text/1)
    assert labels == ~w(Home Inbox Tasks Team Spending Settings)

    hrefs = doc |> Floki.find("a.d") |> Enum.map(&(Floki.attribute(&1, "href") |> hd()))
    assert hrefs == ~w(/ /inbox /issues /agents /costs /settings)
  end

  test "marks exactly one destination: page on its root pages, true below them" do
    for {path, expected} <- [
          {"/", {"Home", "page"}},
          {"/dashboard", {"Home", "page"}},
          {"/issues", {"Tasks", "page"}},
          {"/kanban", {"Tasks", "page"}},
          {"/issues/x", {"Tasks", "true"}},
          {"/projects/p1", {"Tasks", "true"}},
          {"/board-approvals/b1", {"Inbox", "true"}},
          {"/budgets", {"Spending", "true"}},
          {"/settings/appearance", {"Settings", "page"}},
          {"/companies/c1", {"Settings", "true"}}
        ] do
      assert current(nav(current_path: path)) == [expected], "on #{path}"
    end

    assert current(nav(current_path: "/search")) == []
  end

  test "lists each destination's pages; Advanced pages carry ui-advanced-only" do
    doc = nav(current_path: "/issues")

    kids = doc |> Floki.find(".kids a") |> Enum.map(&Floki.text/1)

    for label <-
          ["Activity", "Needs you", "Approval history", "All tasks", "Projects", "Goals"] ++
            ["Repeating tasks", "Launch checklist", "People", "Org chart", "Spending limit"] do
      assert label in kids
    end

    for href <- ~w(/reviews /workspaces /skills /operations /tool-call-traces) do
      [li] =
        doc
        |> Floki.find(".kids li")
        |> Enum.filter(&(Floki.find(&1, ~s(a[href="#{href}"])) != []))

      assert "ui-advanced-only" in (li |> Floki.attribute("class") |> hd() |> String.split())
    end

    assert [all_tasks] = Floki.find(doc, ~s(.kids a[aria-current="page"]))
    assert Floki.text(all_tasks) =~ "All tasks"
  end

  test "marks a destination's page: page on its path, true on the pages below it" do
    marked = fn path ->
      nav(current_path: path)
      |> Floki.find(".kids a[aria-current]")
      |> Enum.map(&{Floki.text(&1), &1 |> Floki.attribute("aria-current") |> hd()})
    end

    assert marked.("/issues") == [{"All tasks", "page"}]
    assert marked.("/issues/x") == [{"All tasks", "true"}]
    assert marked.("/agents/a1") == [{"People", "true"}]
    assert marked.("/projects/p1") == [{"Projects", "true"}]
    assert marked.("/kanban") == []
    assert marked.("/issuesx") == []
  end

  test "Compare companies appears only with more than one company" do
    refute render_rail(company_count: 1) =~ "Compare companies"
    assert render_rail(company_count: 2) =~ "Compare companies"
  end

  test "renders the Inbox count as one live node with the number and a spoken suffix" do
    doc = nav(inbox_count: 7)

    assert [count] = Floki.find(doc, ~s(a.d[href="/inbox"] .count[data-nav-badge="inbox"]))
    assert Floki.attribute(count, "data-count") == ["7"]
    assert [num] = Floki.find(count, "[data-badge-num][data-testid='nav-badge-inbox']")
    assert String.trim(Floki.text(num)) == "7"
    assert Floki.text(Floki.find(count, ".sr")) == " need you"
  end

  test "keeps a hidden Inbox count node at zero and shows no other badge" do
    html = render_rail(inbox_count: 0)

    refute html =~ ~s(data-testid="nav-badge-inbox")
    assert html =~ ~s(data-nav-badge="inbox")
    assert html =~ ~s(data-count="0")
    assert html =~ "hidden"
    refute html =~ ~s(data-nav-badge="approvals")
  end

  test "renders the destination table for the client-side highlight" do
    doc = nav([])

    [tasks] = Floki.find(doc, ~s(a.d[href="/issues"]))

    assert Floki.attribute(tasks, "data-nav-matches")
           |> hd()
           |> String.split(",")
           |> Enum.member?("/kanban")

    assert Floki.attribute(tasks, "data-nav-roots") == ["/issues,/kanban"]

    [settings] = Floki.find(doc, ~s(a.d[href="/settings"]))
    assert Floki.attribute(settings, "data-nav-roots") == ["/settings,/settings/*"]
  end

  test "keeps runtime controls and mode switching out of the navigation" do
    html = render_rail([])

    refute html =~ "/runtime-control/"
    refute html =~ "data-ui-mode-toggle"
  end
end
