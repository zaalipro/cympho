defmodule CymphoWeb.OrgChartLiveTest do
  use CymphoWeb.LiveCase, async: true

  import CymphoWeb.R3PageHelpers

  alias Cympho.{Agents, Issues}

  test "renders org health diagnostics above the reporting tree", %{
    conn: conn,
    current_company: company
  } do
    {:ok, _agent} =
      Agents.create_agent(%{
        name: "Solo Engineer",
        role: :engineer,
        status: :idle,
        adapter: :process,
        company_id: company.id
      })

    {:ok, view, html} = live(conn, "/org-chart")
    doc = main_doc(html)

    # r3 (v7 G5): a root page under Team; Hire is the one header pill.
    assert_r3_page(doc, page: "org-chart", h1: "Org chart", kind: :root, primaries: 0)
    assert Floki.attribute(doc, ".ctx-end a.pl", "href") == ["/agents/new"]
    # The export hook and its area stay where app.js looks for them.
    assert Floki.find(doc, ~s(.frame#org-chart-page[phx-hook="OrgChartExport"])) != []
    assert Floki.find(doc, ~s(#org-chart-export-area.org-scroll ul.org-tree)) != []

    # Each agent is a button tile with its status as a word.
    tile = ~s(button.org-t[phx-click="select_agent"][aria-label="Solo Engineer details"])
    assert text(doc, tile <> " .org-s") =~ "Idle"

    # Problems first: the health band leads the tray.
    assert texts(doc, ".tray > section .card-h .h2") |> hd() == "Org health"
    assert text(doc, ~s([data-testid="org-health"] .card-h)) =~ "Org risk"
    assert texts(doc, ~s([data-testid="org-health"] .strip .l)) |> length() <= 4

    html = render_click(element(view, tile))
    assert html =~ ~s(role="dialog")
    assert text(main_doc(html), "#agent-stats-modal .dlg-h .h2") == "Agent statistics"

    assert html =~ ~s(data-testid="org-health")
    assert html =~ "Org health"
    assert html =~ "Org risk"
    assert html =~ "missing CEO, CTO coverage"
    assert html =~ "Role gaps"
    assert html =~ "Demand gaps"
    assert html =~ "Fill role coverage"
    assert html =~ "Solo Engineer"
  end

  # The heartbeat skips a sleeping agent (agent_heartbeat.ex), so "Idle" would say it takes work.
  test "a sleeping agent's tile says Sleeping, not Idle", %{conn: conn, current_company: company} do
    {:ok, _agent} =
      Agents.create_agent(%{
        name: "Dozing Engineer",
        role: :engineer,
        status: :sleeping,
        adapter: :process,
        company_id: company.id
      })

    {:ok, _view, html} = live(conn, "/org-chart")

    assert text(main_doc(html), ~s(button.org-t[aria-label="Dozing Engineer details"] .org-s)) ==
             "Sleeping"
  end

  test "links demand gaps to a prefilled agent hire form", %{
    conn: conn,
    current_company: company
  } do
    {:ok, ceo} =
      Agents.create_agent(%{
        name: "CEO",
        role: :ceo,
        status: :idle,
        adapter: :process,
        company_id: company.id
      })

    {:ok, _cto} =
      Agents.create_agent(%{
        name: "CTO",
        role: :cto,
        status: :idle,
        adapter: :process,
        company_id: company.id
      })

    {:ok, _engineer} =
      Agents.create_agent(%{
        name: "Engineer",
        role: :engineer,
        status: :idle,
        adapter: :process,
        company_id: company.id
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Plan SEO launch campaign",
        status: :todo,
        company_id: company.id
      })

    {:ok, _view, html} = live(conn, "/org-chart")

    # The staffing gaps are their own band (the hire form's return_to anchor).
    assert Floki.find(main_doc(html), ~s(section#org-demand-staffing .lrow a.pl)) != []
    assert html =~ ~s(data-testid="org-demand-staffing")
    assert html =~ "Staff queued work"
    assert html =~ "Hire Marketer"
    assert html =~ "Reports to CEO"
    assert html =~ "/issues/#{issue.id}"
    assert html =~ issue.identifier
    assert html =~ "role=marketer"
    assert html =~ "name=Marketer"
    assert html =~ "runtime_profile_id=openai-chat-qwen-dashscope-flash"
    assert html =~ "return_to=%2Forg-chart%23org-demand-staffing"
    assert html =~ "parent_id=#{ceo.id}"
  end
end
