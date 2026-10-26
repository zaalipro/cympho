defmodule CymphoWeb.AdapterLiveTest do
  use CymphoWeb.LiveCase, async: true

  import CymphoWeb.R3PageHelpers

  alias Cympho.Agents

  describe "Adapters index" do
    test "renders runtime readiness guidance before agents are assigned", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/adapters")

      assert html =~ ~s(data-testid="adapter-runtime-readiness")
      assert html =~ "no agents are assigned to a runtime yet"
      assert html =~ "Add agent"
      assert html =~ ~s(href="/settings/secrets")
      # The duplicate "Healthy adapters / Degraded / Unhealthy / Unavailable"
      # lane row was removed; the stat row is now the single health tally.
      # Assert the row's own note strings, not the bare word "Healthy" — that
      # matches almost any markup and would pass even if the tally vanished.
      assert html =~ "Needs attention"
      assert html =~ ~r/Healthy.*registered/s
      assert html =~ ~r/\d+ unavailable/
    end

    test "summarizes assigned adapter usage for the current company", %{
      conn: conn,
      current_company: company
    } do
      {:ok, _agent} =
        Agents.create_agent(%{
          name: "Adapter Live Agent",
          role: :engineer,
          company_id: company.id,
          adapter: :process
        })

      {:ok, view, html} = live(conn, "/settings/adapters")

      assert html =~ "Assigned agents"
      assert html =~ "1 adapter is in use"
      # Health (/operations) is Advanced-only: its link stays out of Simple.
      assert has_element?(view, ".ui-advanced-only a[href='/operations']", "Health")
      assert has_element?(view, "#adapter-process .rm", "Adapter Live Agent")
      refute html =~ "check Agrenting"
    end

    test "invalid adapter health events do not crash the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/adapters")

      html = render_click(view, "test_adapter", %{"key" => "definitely_not_registered"})

      assert html =~ "Unknown adapter"
      assert has_element?(view, ".set-main p.err[role=alert]", "Unknown adapter")
      assert html =~ ~s(data-testid="adapter-runtime-readiness")
    end

    # v7 S5: one "How agents run" band; each runtime is a row whose title opens it.
    test "lists each runtime as a row in the How agents run band", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/adapters")
      doc = main_doc(view)

      assert_r3_page(doc, page: "settings", h1: "Settings", kind: :root, primaries: 0)
      assert text(doc, ".set-main section[aria-labelledby=ad-t] .card-h h2") == "How agents run"

      assert Floki.find(doc, ".set-main .card-h button.pl[phx-click=refresh_health]") != []

      assert [row] = Floki.find(doc, "#adapter-claude_code.lrow")

      assert Floki.attribute(Floki.find(row, "a.rt2"), "href") == [
               "/settings/adapters/claude_code"
             ]

      assert Floki.find(row, ".lr-st svg.g") != []

      assert Floki.find(
               row,
               ".lr-acts button.pl[phx-click=test_adapter][phx-value-key=claude_code]"
             ) !=
               []

      refute render(view) =~ ~r/ember-|font-serif|card-lift/
    end
  end
end
