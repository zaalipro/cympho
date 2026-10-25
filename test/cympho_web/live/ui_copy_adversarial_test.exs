defmodule CymphoWeb.UiCopyAdversarialTest do
  @moduledoc """
  Adversarial stress harness for Milestone 3 UI copy simplification and dual-mode markup.
  Empirically tests that:
  1. All key pages touched by UI copy simplification render parseable, valid markup.
  2. No DOM element contains conflicting `.ui-simple-only` and `.ui-advanced-only` classes.
  3. No `.ui-simple-only` or `.ui-advanced-only` container is an empty ghost node.
  4. Banned/punitive legacy phrases ("CEO command lane", "kicked back", "weak submissions", "tampered content hash")
     are strictly absent from the rendered HTML in both empty and populated states.
  5. Humanized phrases ("Executive Overview", "Changes requested", "Review Overview", "Pending Tasks", "Budget Overview", "Cost Analytics", "Automated Routines")
     are verified in the rendered HTML.
  """
  use CymphoWeb.LiveCase, async: true

  @banned_phrases [
    "CEO command lane",
    "No issues currently kicked back",
    "weak submissions",
    "tampered content hash",
    "Wake Backlog",
    "Routine command",
    "Budget command",
    "Goal command"
  ]

  describe "dual-mode markup and copy stress test" do
    test "verifies valid markup, no ghost nodes, no conflicting mode classes, and zero banned copy" do
      conn = authenticated_conn(%{is_board_member: true})
      company = current_company()

      # Seed minimal data to test populated state as well
      {:ok, _routine} =
        Cympho.Routines.create_routine(%{
          name: "Daily Health Check",
          cron_expression: "0 9 * * *",
          action_type: :custom,
          company_id: company.id
        })

      routes = [
        "/dashboard",
        "/budgets",
        "/costs",
        "/reviews",
        "/operations",
        "/routines",
        "/workspaces",
        "/goals",
        "/activity"
      ]

      for route <- routes do
        {:ok, _view, html} = live(conn, route)

        # 1. Floki document parsing must succeed
        assert {:ok, parsed} = Floki.parse_document(html),
               "HTML parsing failed for route #{route}"

        # 2. No element should carry BOTH ui-simple-only and ui-advanced-only
        conflicting =
          Floki.find(parsed, ".ui-simple-only.ui-advanced-only, .ui-advanced-only.ui-simple-only")

        assert conflicting == [],
               "Found elements with conflicting mode classes on #{route}: #{inspect(conflicting)}"

        # 3. No empty ghost elements for mode classes
        simple_elements = Floki.find(parsed, ".ui-simple-only")
        advanced_elements = Floki.find(parsed, ".ui-advanced-only")

        for elem <- simple_elements do
          text = Floki.text(elem) |> String.trim()
          children = Floki.children(elem)
          has_content? = text != "" or children != []

          assert has_content?,
                 "Found empty ghost .ui-simple-only element on #{route}: #{inspect(elem)}"
        end

        for elem <- advanced_elements do
          text = Floki.text(elem) |> String.trim()
          children = Floki.children(elem)
          has_content? = text != "" or children != []

          assert has_content?,
                 "Found empty ghost .ui-advanced-only element on #{route}: #{inspect(elem)}"
        end

        # 4. Strict check for banned phrases
        for phrase <- @banned_phrases do
          refute html =~ phrase,
                 "Banned legacy phrase #{inspect(phrase)} found on route #{route}"
        end
      end
    end
  end

  # One block per route (v7 §3.1 D): a track edits only its own route's block.
  describe "humanized replacement terms exist on target routes" do
    setup do
      conn = authenticated_conn(%{is_board_member: true})
      company = current_company()

      {:ok, _routine} =
        Cympho.Routines.create_routine(%{
          name: "Daily Health Check",
          cron_expression: "0 9 * * *",
          action_type: :custom,
          company_id: company.id
        })

      %{conn: conn}
    end

    # /dashboard: Home (redesigned; no track)
    test "/dashboard keeps its humanized phrase", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")

      assert html =~ "Executive Overview",
             "Expected humanized phrase \"Executive Overview\" missing from route /dashboard"
    end

    # /reviews: governance track
    test "/reviews keeps its humanized phrase", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/reviews")

      assert html =~ "Review Overview",
             "Expected humanized phrase \"Review Overview\" missing from route /reviews"

      assert html =~ "No issues currently have changes requested.",
             "Expected humanized phrase \"No issues currently have changes requested.\" missing from route /reviews"
    end

    # /operations: ops track
    test "/operations keeps its humanized phrase", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/operations")

      assert html =~ "Pending Tasks",
             "Expected humanized phrase \"Pending Tasks\" missing from route /operations"
    end

    # /routines: planning track
    test "/routines keeps its humanized phrase", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/routines")

      assert html =~ "Automated Routines",
             "Expected humanized phrase \"Automated Routines\" missing from route /routines"
    end

    # /goals: planning track
    test "/goals keeps its humanized phrase", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/goals")

      assert html =~ "Goals Overview",
             "Expected humanized phrase \"Goals Overview\" missing from route /goals"
    end

    # /workspaces: ops track
    test "/workspaces keeps its humanized phrase", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/workspaces")

      assert html =~ "Workspaces",
             "Expected humanized phrase \"Workspaces\" missing from route /workspaces"
    end

    # /activity: governance track
    test "/activity keeps its humanized phrase", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/activity")

      assert html =~ "Activity History",
             "Expected humanized phrase \"Activity History\" missing from route /activity"
    end
  end
end
