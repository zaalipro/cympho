defmodule CymphoWeb.OrgChartLiveTest do
  use CymphoWeb.LiveCase, async: true

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

    {:ok, _view, html} = live(conn, "/org-chart")

    assert html =~ ~s(data-testid="org-health")
    assert html =~ "Org Health"
    assert html =~ "Org risk"
    assert html =~ "missing CEO, CTO coverage"
    assert html =~ "Role gaps"
    assert html =~ "Demand gaps"
    assert html =~ "Fill role coverage"
    assert html =~ "Solo Engineer"
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

    assert html =~ ~s(data-testid="org-demand-staffing")
    assert html =~ "Staff queued work"
    assert html =~ "Hire Marketer"
    assert html =~ "Reports to CEO"
    assert html =~ "/issues/#{issue.id}"
    assert html =~ issue.identifier
    assert html =~ "role=marketer"
    assert html =~ "name=Marketer"
    assert html =~ "parent_id=#{ceo.id}"
  end
end
