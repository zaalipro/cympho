defmodule CymphoWeb.SearchLiveTest do
  use CymphoWeb.LiveCase, async: true

  import CymphoWeb.R3PageHelpers

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Goals
  alias Cympho.Issues
  alias Cympho.Labels
  alias Cympho.Projects

  describe "Search page" do
    test "renders starter command actions before a query", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/search")
      doc = main_doc(html)

      # r3 (v7 G6): an unfiled root page; the filters sit behind one Filter chip.
      assert_r3_page(doc, page: "search", h1: "Search", kind: :root, primaries: 0)
      assert Floki.find(doc, ~s(form[phx-submit="search"] input[name="search[query]"])) != []
      assert Floki.find(doc, ~s(details#search-filter [data-testid="search-core-filters"])) != []
      assert Floki.find(doc, ~s(details#search-filter #search-advanced-filters)) != []
      # The tabs are segmented buttons; All is pressed.
      assert texts(doc, ~s(.seg button[aria-pressed="true"])) == ["All"]

      assert html =~ ~s(data-testid="search-command")
      assert html =~ "Search Overview"
      assert html =~ "Ready for scoped company search."
      assert html =~ "New task"
      assert html =~ "Board"
      assert html =~ "Operations"
      # Operations is an Advanced-only page: its link stays Advanced-only.
      assert [_ | _] =
               doc
               |> Floki.find(~s([data-testid="search-results-empty"] .ui-advanced-only a))
               |> Floki.attribute("href")
               |> Enum.filter(&(&1 == "/operations"))

      assert html =~ "No top match."
      assert html =~ ~s(data-testid="search-core-filters")
      assert html =~ ~s(data-testid="search-advanced-filters")
      assert html =~ "Advanced filters"
      assert html =~ "Optional"
      refute advanced_filter_open?(html)
      assert html =~ ~s(data-testid="search-results-empty")
      assert html =~ "Search is ready"
      assert html =~ "Jump to current work, open the board, or create the next task from here."
    end

    test "opens advanced filters when an advanced filter is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/search?role=engineer")

      assert html =~ "1 active advanced"
      assert advanced_filter_open?(html)
    end

    # The patch ignores `open` (the reader's toggle holds); data-open carries the
    # server's value, which the ServerOpen hook applies when it changes.
    test "advanced filters follow a URL that sets or clears one (Back, Forward)", %{conn: conn} do
      {:ok, view, html} = live(conn, "/search")

      assert %{"phx-hook" => "ServerOpen", "data-open" => "false"} = advanced_filter_attrs(html)

      assert %{"data-open" => "true"} =
               view |> render_patch("/search?role=engineer") |> advanced_filter_attrs()

      assert %{"data-open" => "false"} =
               view |> render_patch("/search") |> advanced_filter_attrs()
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
      # "COMMAND SURFACE" eyebrow above it; r3 keeps the purpose as the field's label.
      assert html =~ "Find tasks, people, projects and goals in this company"
      refute html =~ "command surface"
      assert html =~ ~s(id="search-filter")
      assert html =~ ~s(data-testid="search-command")
      assert html =~ "Search Overview"
      assert html =~ "3 total matches. Top match: Task. No filters active."
      assert html =~ "Open top result"
      assert html =~ "Focus tasks"
      assert html =~ "Results"

      # Results are rows: a title link, the kind as a tag.
      doc = main_doc(html)
      assert texts(doc, "#search-results .lrow .lr-tr .tag") == ["Task", "Project", "Goal"]
      # The overview does not repeat the tab counts (Argon IMP-4).
      assert Floki.find(doc, "#search-command .strip") == []
      assert html =~ "#{needle} current issue"
      assert html =~ "#{needle} project"
      assert html =~ "#{needle} goal"
      assert html =~ ~s(name="filter[goal_id]")
      refute html =~ "#{needle} foreign issue"

      {:ok, _view, issue_tab_html} = live(conn, "/search?q=#{needle}&tab=issues")

      assert issue_tab_html =~ "1 task match for &quot;#{needle}&quot;"
    end

    test "a task row keeps what the old card said: project, priority, description; goal and labels in Advanced",
         %{conn: conn, current_company: company} do
      unique = System.unique_integer([:positive])
      needle = "rowfind#{unique}"

      {:ok, project} =
        Projects.create_project(%{
          name: "Row project #{unique}",
          prefix: unique_prefix(),
          company_id: company.id
        })

      {:ok, goal} =
        Goals.create_goal(%{
          title: "Row goal #{unique}",
          company_id: company.id,
          project_id: project.id,
          goal_type: :mission
        })

      {:ok, label} = Labels.create_label(%{name: "Row label #{unique}", company_id: company.id})

      {:ok, issue} =
        Issues.create_issue(%{
          title: "#{needle} task",
          description: "Why this task matched the search",
          company_id: company.id,
          project_id: project.id,
          goal_id: goal.id,
          priority: :high,
          status: :in_progress
        })

      {:ok, _issue} = Issues.add_label_to_issue(issue, label)

      {:ok, sleeper} =
        Agents.create_agent(%{
          name: "#{needle} sleeper",
          role: :engineer,
          status: :sleeping,
          adapter: :process,
          company_id: company.id
        })

      {:ok, _view, html} = live(conn, "/search?q=#{needle}")
      doc = main_doc(html)
      row = "#search-issue-#{issue.id}"

      # The Task page's words for the state; the project after the assignee slot.
      assert text(doc, row <> " .rm") =~ "Working · Row project #{unique}"
      assert [description, _advanced] = texts(doc, row <> " .rm .srch-snip")
      assert description == "Why this task matched the search"
      # Priority as the Tasks list draws it (bars and the word, High and Critical only).
      assert text(doc, row <> " .lr-tr .prio") == "High"

      advanced = text(doc, row <> " .rm .ui-advanced-only")
      assert advanced =~ "Goal: Row goal #{unique}"
      assert advanced =~ "Labels: Row label #{unique}"

      # The heartbeat skips a sleeping agent, so it does not read as Idle.
      assert text(doc, "#search-agent-#{sleeper.id} .lr-st") == "Sleeping"
    end

    test "a goal row keeps what the old card said: type, priority and the description that matched",
         %{conn: conn, current_company: company} do
      unique = System.unique_integer([:positive])
      needle = "goalfind#{unique}"

      {:ok, project} =
        Projects.create_project(%{
          name: "Goal project #{unique}",
          prefix: unique_prefix(),
          company_id: company.id
        })

      # The needle is only in the description: the snippet is what explains the match.
      {:ok, goal} =
        Goals.create_goal(%{
          title: "Improve retention #{unique}",
          description: "Keep #{needle} customers past their first month",
          company_id: company.id,
          project_id: project.id,
          goal_type: :mission,
          priority: "critical"
        })

      for tab <- ["all", "goals"] do
        {:ok, _view, html} = live(conn, "/search?q=#{needle}&tab=#{tab}")
        doc = main_doc(html)
        row = "#search-goal-#{goal.id}"

        assert text(doc, row <> " .rm") =~ "Mission · Active · Goal project #{unique}"

        assert text(doc, row <> " .rm .srch-snip") ==
                 "Keep #{needle} customers past their first month"

        # Priority as the Tasks and Goals lists draw it (bars and the word, High and Critical only).
        assert text(doc, row <> " .lr-tr .prio") == "Critical"
      end
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
      assert html =~ "New task"
      assert html =~ "Tasks"
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

  defp advanced_filter_attrs(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(details[data-testid="search-advanced-filters"]))
    |> then(fn [{"details", attrs, _children}] -> Map.new(attrs) end)
  end
end
