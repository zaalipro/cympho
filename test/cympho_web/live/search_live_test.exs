defmodule CymphoWeb.SearchLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Companies
  alias Cympho.Goals
  alias Cympho.Issues
  alias Cympho.Projects

  describe "Search page" do
    test "renders starter command actions before a query", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/search")

      assert html =~ ~s(data-testid="search-command")
      assert html =~ "Search command"
      assert html =~ "Ready for scoped company search."
      assert html =~ "New issue"
      assert html =~ "Board"
      assert html =~ "Operations"
      assert html =~ "No top match."
      assert html =~ ~s(data-testid="search-core-filters")
      assert html =~ ~s(data-testid="search-advanced-filters")
      assert html =~ "Advanced filters"
      assert html =~ "Optional"
      refute advanced_filter_open?(html)
      assert html =~ ~s(data-testid="search-results-empty")
      assert html =~ "Search is ready"
      assert html =~ "Jump to current work, open the board, or create the next issue from here."
    end

    test "opens advanced filters when an advanced filter is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/search?role=engineer")

      assert html =~ "1 active advanced"
      assert advanced_filter_open?(html)
    end

    test "renders company-scoped results and scoped filter options", %{
      conn: conn,
      current_company: company
    } do
      unique = System.unique_integer([:positive])
      needle = "livefind#{unique}"

      {:ok, project} =
        Projects.create_project(%{
          name: "#{needle} project",
          prefix: unique_prefix(),
          company_id: company.id
        })

      {:ok, goal} =
        Goals.create_goal(%{
          title: "#{needle} goal",
          company_id: company.id,
          project_id: project.id,
          goal_type: :mission
        })

      {:ok, _issue} =
        Issues.create_issue(%{
          title: "#{needle} current issue",
          description: "Current company search result",
          company_id: company.id,
          project_id: project.id,
          goal_id: goal.id,
          status: :todo
        })

      {:ok, foreign_company} =
        Companies.create_company(%{
          name: "Foreign Search Live #{unique}",
          slug: "foreign-search-live-#{unique}"
        })

      {:ok, _foreign_issue} =
        Issues.create_issue(%{
          title: "#{needle} foreign issue",
          description: "Should not appear in the current company search.",
          company_id: foreign_company.id,
          status: :todo
        })

      {:ok, _view, html} = live(conn, "/search?q=#{needle}")

      # The subtitle used to end in "one scoped command surface", matching the
      # "COMMAND SURFACE" eyebrow above it.
      assert html =~ "Find issues, people, projects, and goals in this company."
      refute html =~ "command surface"
      assert html =~ "Filters"
      assert html =~ ~s(data-testid="search-command")
      assert html =~ "Search command"
      assert html =~ "3 total matches. Top match: Issue. No filters active."
      assert html =~ "Open top result"
      assert html =~ "Focus issues"
      assert html =~ "Results"
      assert html =~ "#{needle} current issue"
      assert html =~ "#{needle} project"
      assert html =~ "#{needle} goal"
      assert html =~ ~s(name="filter[goal_id]")
      refute html =~ "#{needle} foreign issue"

      {:ok, _view, issue_tab_html} = live(conn, "/search?q=#{needle}&tab=issues")

      assert issue_tab_html =~ "1 issue match for &quot;#{needle}&quot;"
    end

    test "finds an issue by ticket identifier", %{conn: conn, current_company: company} do
      {:ok, project} =
        Projects.create_project(%{
          name: "Ident Live Project",
          prefix: "ILP",
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "No ticket token in this title",
          description: "Owner should still find this by identifier.",
          company_id: company.id,
          project_id: project.id,
          status: :todo
        })

      {:ok, _view, html} = live(conn, "/search?q=#{issue.identifier}")

      assert html =~ issue.identifier
      assert html =~ "No ticket token in this title"
    end

    test "renders an actionable empty state when filters remove every match", %{
      conn: conn,
      current_company: company
    } do
      unique = System.unique_integer([:positive])
      needle = "filteredfind#{unique}"

      {:ok, _issue} =
        Issues.create_issue(%{
          title: "#{needle} todo issue",
          description: "The filter should hide this search hit.",
          company_id: company.id,
          status: :todo
        })

      {:ok, _view, html} = live(conn, "/search?q=#{needle}&status=blocked")

      assert html =~ "No matches under the current filters."
      assert html =~ ~s(data-testid="search-results-empty")
      assert html =~ "No matches inside these filters"
      assert html =~ "The query exists, but the active filters exclude every matching item."
      assert html =~ "Clear filters"
      assert html =~ "New issue"
      assert html =~ "Issues"
      refute html =~ "#{needle} todo issue"
    end
  end

  defp unique_prefix do
    unique = System.unique_integer([:positive])

    letters =
      0..5
      |> Enum.map(fn shift ->
        divisor = round(:math.pow(26, shift))
        <<?A + rem(div(unique, divisor), 26)>>
      end)
      |> Enum.join()

    "L" <> letters
  end

  defp advanced_filter_open?(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(details[data-testid="search-advanced-filters"]))
    |> case do
      [{"details", attrs, _children}] ->
        Enum.any?(attrs, fn {name, _value} -> name == "open" end)

      _ ->
        false
    end
  end
end
