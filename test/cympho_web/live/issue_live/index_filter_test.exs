defmodule CymphoWeb.IssueLive.IndexFilterTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Issues
  alias Cympho.Agents
  alias Cympho.Projects
  alias Cympho.Labels

  setup do
    {:ok, project} =
      Projects.create_project(%{name: "Test Project", prefix: "TP"})

    {:ok, agent} =
      Agents.create_agent(%{name: "Filter Agent", role: :engineer, status: :idle})

    {:ok, label} =
      Labels.create_label(%{name: "bug", color: "#ff0000"})

    {:ok, issue1} =
      Issues.create_issue(%{
        title: "Pagination test issue one",
        description: "First issue for testing",
        status: :backlog,
        priority: :high,
        project_id: project.id,
        assignee_id: agent.id
      })

    {:ok, _label} = Issues.add_label_to_issue(issue1, label)

    {:ok, _issue2} =
      Issues.create_issue(%{
        title: "Pagination test issue two",
        description: "Second issue for testing",
        status: :in_progress,
        priority: :low
      })

    {:ok, _issue3} =
      Issues.create_issue(%{
        title: "Another completely different title",
        description: "Third issue for testing",
        status: :todo,
        priority: :medium
      })

    %{
      project: project,
      agent: agent,
      label: label,
      issue1: issue1
    }
  end

  describe "Index - Search" do
    test "renders search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/issues")

      assert html =~ "Search issues..."
      assert html =~ ~s(phx-submit="search")
    end

    test "search filters issues by text", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/issues")

      view
      |> form("form[phx-submit='search']", %{"search" => "Pagination"})
      |> render_submit()

      html = render(view)
      assert html =~ "Pagination test issue one"
      assert html =~ "Pagination test issue two"
      refute html =~ "Another completely different"
    end

    test "search with no results shows empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/issues")

      view
      |> form("form[phx-submit='search']", %{"search" => "nonexistent xyzzy"})
      |> render_submit()

      html = render(view)
      assert html =~ "No issues found"
    end

    test "search query persists in URL params", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/issues")

      view
      |> form("form[phx-submit='search']", %{"search" => "Pagination"})
      |> render_submit()

      assert_patched(view, ~r/search=Pagination/)
    end
  end

  describe "Index - Status Filter" do
    test "renders status filter dropdown", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/issues")

      assert html =~ "All Statuses"
      assert html =~ ~s(phx-change="filter_status")
    end

    test "filtering by status shows only matching issues", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/issues")

      view
      |> element("form[phx-change='filter_status']")
      |> render_change(%{"status" => "in_progress"})

      html = render(view)
      assert html =~ "Pagination test issue two"
      refute html =~ "Pagination test issue one"
      refute html =~ "Another completely different"
    end

    test "status filter persists in URL params", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/issues")

      view
      |> element("form[phx-change='filter_status']")
      |> render_change(%{"status" => "backlog"})

      assert_patched(view, ~r/status=backlog/)
    end
  end

  describe "Index - Priority Filter" do
    test "renders priority filter dropdown", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/issues")

      assert html =~ "All Priorities"
      assert html =~ ~s(phx-change="filter_priority")
    end

    test "filtering by priority shows only matching issues", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/issues")

      view
      |> element("form[phx-change='filter_priority']")
      |> render_change(%{"priority" => "low"})

      html = render(view)
      assert html =~ "Pagination test issue two"
      refute html =~ "Pagination test issue one"
    end
  end

  describe "Index - Assignee Filter" do
    test "renders assignee filter dropdown", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/issues")

      assert html =~ "All Assignees"
      assert html =~ "Filter Agent"
      assert html =~ ~s(phx-change="filter_assignee")
    end

    test "filtering by assignee shows only their issues", %{conn: conn, agent: agent} do
      {:ok, view, _html} = live(conn, "/issues")

      view
      |> element("form[phx-change='filter_assignee']")
      |> render_change(%{"assignee_id" => agent.id})

      html = render(view)
      assert html =~ "Pagination test issue one"
      refute html =~ "Pagination test issue two"
      refute html =~ "Another completely different"
    end
  end

  describe "Index - Project Filter" do
    test "renders project filter dropdown", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/issues")

      assert html =~ "All Projects"
      assert html =~ "Test Project"
      assert html =~ ~s(phx-change="filter_project")
    end

    test "filtering by project shows only its issues", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, "/issues")

      view
      |> element("form[phx-change='filter_project']")
      |> render_change(%{"project_id" => project.id})

      html = render(view)
      assert html =~ "Pagination test issue one"
      refute html =~ "Pagination test issue two"
    end
  end

  describe "Index - Label Filter" do
    test "renders label filter dropdown", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/issues")

      assert html =~ "All Labels"
      assert html =~ "bug"
      assert html =~ ~s(phx-change="filter_label")
    end

    test "filtering by label shows only matching issues", %{conn: conn, label: label} do
      {:ok, view, _html} = live(conn, "/issues")

      view
      |> element("form[phx-change='filter_label']")
      |> render_change(%{"label_id" => label.id})

      html = render(view)
      assert html =~ "Pagination test issue one"
      refute html =~ "Pagination test issue two"
    end
  end

  describe "Index - Clear Filters" do
    test "clear filters button removes all filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/issues?status=backlog&priority=high")

      html = render(view)
      assert html =~ "Clear all"

      view
      |> element("button[phx-click='clear_filters']")
      |> render_click()

      assert_patched(view, "/issues")
    end

    test "clear filters not shown when no filters active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/issues")

      refute html =~ "Clear all"
    end
  end

  describe "Index - Pagination" do
    test "shows pagination controls when multiple pages", %{conn: conn} do
      for i <- 1..30 do
        Issues.create_issue(%{
          title: "Bulk issue #{i}",
          description: "Bulk test"
        })
      end

      {:ok, view, _html} = live(conn, "/issues?per_page=10")

      html = render(view)
      assert html =~ "Next"
      assert html =~ "Page"

      view
      |> element("button[phx-click='change_page'][phx-value-page='2']")
      |> render_click()

      assert_patched(view, ~r/page=2/)
    end

    test "pagination resets to page 1 when filter changes", %{conn: conn} do
      for i <- 1..15 do
        Issues.create_issue(%{
          title: "More issues #{i}",
          description: "Bulk"
        })
      end

      {:ok, view, _html} = live(conn, "/issues?per_page=5&page=2")

      view
      |> element("form[phx-change='filter_status']")
      |> render_change(%{"status" => "backlog"})

      assert_patched(view, ~r/page=1/)
    end
  end

  describe "Index - Combined Filters" do
    test "multiple filters work together", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/issues?status=backlog&priority=high")

      html = render(view)
      assert html =~ "Pagination test issue one"
      refute html =~ "Pagination test issue two"
    end

    test "filter and search work together via URL", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, "/issues?search=Pagination&project_id=#{project.id}")

      html = render(view)
      assert html =~ "Pagination test issue one"
      refute html =~ "Pagination test issue two"
    end
  end
end
