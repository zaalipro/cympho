defmodule CymphoWeb.DocsLiveTest do
  use CymphoWeb.LiveCase, async: true
  import Phoenix.LiveViewTest

  describe "In-App /docs Documentation Hub mounting & authentication" do
    test "authenticated user can mount /docs with company context", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/docs")

      assert html =~ "What is Cympho?"
      assert html =~ "Documentation Topics"
      assert html =~ "Getting Started"
      assert html =~ "On this page"
    end

    test "unauthenticated visitor can mount /docs in guest mode without login redirect" do
      guest_conn = Phoenix.ConnTest.build_conn()
      {:ok, _view, html} = live(guest_conn, "/docs")

      assert html =~ "What is Cympho?"
      assert html =~ "Documentation Topics"
      assert html =~ "Guest"
      refute html =~ "Sign in to continue."
    end
  end

  describe "Topic navigation & deep linking" do
    test "navigating to /docs/:topic renders default document for that topic", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/docs/ai-agents")

      assert html =~ "Agent Roles &amp; Contracts"
      assert html =~ "Role-Based Specialization"
      assert html =~ "Chief Executive Officer"
    end

    test "deep-linking directly to /docs/:topic/:section renders specific document", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/docs/ai-agents/swarm-mode")

      assert html =~ "Swarm Mode Orchestration"
      assert html =~ "High-Concurrency Swarm Execution"
      assert html =~ "The CTO Gate"
    end

    test "clicking sidebar link updates URL and swaps content via push_patch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")

      html = render_patch(view, "/docs/workspaces/git-worktrees")
      assert html =~ "Git Worktrees &amp; Isolation"
      assert html =~ "dynamic git worktrees"
    end

    test "invalid topic slug gracefully falls back to overview document", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/docs/nonexistent-topic-slug")

      assert html =~ "What is Cympho?"
    end

    test "invalid section slug gracefully falls back to topic default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/docs/ai-agents/bad-section-slug")

      assert html =~ "Agent Roles &amp; Contracts"
    end
  end

  describe "Sequential pagination" do
    test "overview document renders Next link to quickstart", %{conn: conn} do
      {:ok, view, html} = live(conn, "/docs/getting-started/overview")

      assert html =~ "Next"
      assert html =~ "Quickstart Guide"

      html = render_patch(view, "/docs/getting-started/quickstart")
      assert html =~ "Quickstart Guide"
      assert html =~ "Previous"
      assert html =~ "What is Cympho?"
    end
  end

  describe "In-App Search Index & Modal" do
    test "opens search modal and finds documents matching query", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")

      # Open modal
      render_click(view, "open_search")
      assert render(view) =~ "Search across all 8 tracks"

      # Search for MCP
      render_change(view, "search", %{"query" => "mcp"})
      html = render(view)
      assert html =~ "Model Context Protocol (MCP) Overview"
      assert html =~ "MCP Built-In Tools Reference"

      # Submit search to select first result
      render_submit(view, "search_submit", %{})
      assert_patch(view, "/docs/mcp-api/mcp-overview")
    end

    test "search suggestion chips trigger fast search", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")

      render_click(view, "open_search")
      render_click(view, "search_suggest", %{"query" => "swarm mode"})

      html = render(view)
      assert html =~ "Swarm Mode Orchestration"
    end

    test "empty search query displays prompt message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")

      render_click(view, "open_search")
      render_change(view, "search", %{"query" => ""})

      assert render(view) =~ "Search across all 8 tracks"
    end

    test "unmatched query displays no matches found message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")

      render_click(view, "open_search")
      render_change(view, "search", %{"query" => "xyzzy_unmatched_term_98765"})

      assert render(view) =~ "No documentation matches found"
    end

    test "keyboard navigation through search results and escape dismissal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")

      render_click(view, "open_search")
      render_change(view, "search", %{"query" => "agent"})

      # Navigate down and up with arrow keys
      render_keydown(view, "search_keydown", %{"key" => "ArrowDown"})
      render_keydown(view, "search_keydown", %{"key" => "ArrowUp"})

      # Dismiss with Escape
      render_keydown(view, "search_keydown", %{"key" => "Escape"})
      refute render(view) =~ "docs-search-modal"
    end
  end

  describe "MCP documentation accuracy" do
    test "covers all 9 static MCP tools with input schemas and permissions", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/docs/mcp-api/mcp-tools")

      assert html =~ "list_issues"
      assert html =~ "get_issue"
      assert html =~ "list_issue_comments"
      assert html =~ "create_issue_comment"
      assert html =~ "create_issue"
      assert html =~ "list_projects"
      assert html =~ "list_agents"
      assert html =~ "get_kanban_state"
      assert html =~ "search"
    end
  end

  describe "Paper & Ink frame" do
    test "renders in the root frame with the article title under the H1", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs/ai-agents/swarm-mode")
      doc = CymphoWeb.R3PageHelpers.main_doc(view)

      CymphoWeb.R3PageHelpers.assert_r3_page(doc,
        page: "docs",
        h1: "Documentation",
        kind: :root,
        primaries: 0
      )

      assert CymphoWeb.R3PageHelpers.text(doc, "article h2.nt") == "Swarm Mode Orchestration"

      assert Floki.find(
               doc,
               ~s(.dc-nav a[aria-current="page"][href="/docs/ai-agents/swarm-mode"])
             ) != []

      assert Floki.find(doc, "main") == []
    end

    test "the Topics pill opens the topic nav as a dialog and a topic closes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")

      view |> element("button.dc-topics") |> render_click()
      assert has_element?(view, ~s(#docs-topics-sheet [role="dialog"] .dc-nav))

      render_patch(view, "/docs/workspaces/git-worktrees")
      refute has_element?(view, "#docs-topics-sheet")
    end

    # The sheet renders after the article, so the keyboard needs to be moved into it; Escape
    # closes it as it closes the search dialog, but not while the search is open on top of it.
    test "the Topics sheet takes focus and closes on Escape", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")

      view |> element("button#docs-topics-btn.dc-topics") |> render_click()

      keys = ~s(#docs-topics-sheet [phx-window-keydown][phx-key="Escape"])
      assert has_element?(view, ~s(#docs-topics-sheet [phx-mounted*="focus_first"]))
      assert has_element?(view, keys)

      render_click(view, "open_search")
      refute has_element?(view, keys)
      render_click(view, "close_search")

      view |> element(keys) |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#docs-topics-sheet")
    end

    # `autofocus` does nothing on a field a patch inserts, so the search dialog opened with the
    # keyboard still on its trigger; the trigger keeps its place to get it back on close.
    test "the search dialog takes focus and gives it back", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")

      assert has_element?(view, ~s(.dc-side button.dc-find[phx-click*="push_focus"]))
      view |> element(".dc-side:not(.m) button.dc-find") |> render_click()

      assert has_element?(view, ~s(#docs-search-input[phx-mounted*="focus"]))
      assert has_element?(view, ~s(#docs-search-modal [phx-click*="pop_focus"]))

      assert has_element?(
               view,
               ~s(#docs-search-modal [phx-window-keydown*="pop_focus"][phx-key="Escape"])
             )
    end
  end

  describe "App shell navigation integration" do
    test "NavRail includes Documentation link", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/docs")

      assert html =~ ~s(href="/docs")
      assert html =~ "Documentation"
    end
  end
end
