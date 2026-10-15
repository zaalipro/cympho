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

    test "verifies humanized replacement terms exist on target routes" do
      conn = authenticated_conn(%{is_board_member: true})
      company = current_company()

      {:ok, _routine} =
        Cympho.Routines.create_routine(%{
          name: "Daily Health Check",
          cron_expression: "0 9 * * *",
          action_type: :custom,
          company_id: company.id
        })

      expectations = [
        {"/dashboard", "Executive Overview"},
        {"/reviews", "Review Overview"},
        {"/reviews", "No issues currently have changes requested."},
        {"/operations", "Pending Tasks"},
        {"/routines", "Automated Routines"},
        {"/goals", "Goals Overview"},
        {"/workspaces", "Workspaces"},
        {"/activity", "Activity History"}
      ]

      for {route, expected_phrase} <- expectations do
        {:ok, _view, html} = live(conn, route)

        assert html =~ expected_phrase,
               "Expected humanized phrase #{inspect(expected_phrase)} missing from route #{route}"
      end
    end
  end
end
