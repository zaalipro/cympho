defmodule CymphoWeb.DocsLiveAdversarialTest do
  use CymphoWeb.LiveCase, async: false
  import Phoenix.LiveViewTest

  alias Cympho.Docs.Content

  # ---------------------------------------------------------------------------
  # 1. Mount Tests: Authenticated & Guest
  # ---------------------------------------------------------------------------
  describe "Adversarial Mounting & Authentication" do
    test "mounts /docs as authenticated user", %{conn: conn} do
      {:ok, view, html} = live(conn, "/docs")
      assert html =~ "What is Cympho?"
      assert html =~ "Documentation Topics"
      assert render(view) =~ "What is Cympho?"
    end

    test "mounts /docs as unauthenticated guest", %{conn: _conn} do
      guest_conn = Phoenix.ConnTest.build_conn()
      {:ok, view, html} = live(guest_conn, "/docs")
      assert html =~ "What is Cympho?"
      assert html =~ "Guest"
      assert render(view) =~ "What is Cympho?"
    end

    test "mounts /docs/getting-started as authenticated user", %{conn: conn} do
      {:ok, view, html} = live(conn, "/docs/getting-started")
      assert html =~ "What is Cympho?"
      assert render(view) =~ "What is Cympho?"
    end

    test "mounts /docs/getting-started as guest", %{conn: _conn} do
      guest_conn = Phoenix.ConnTest.build_conn()
      {:ok, view, html} = live(guest_conn, "/docs/getting-started")
      assert html =~ "What is Cympho?"
      assert render(view) =~ "What is Cympho?"
    end

    test "mounts /docs/ai-agents/swarm-mode as authenticated user", %{conn: conn} do
      {:ok, view, html} = live(conn, "/docs/ai-agents/swarm-mode")
      assert html =~ "Swarm Mode Orchestration"
      assert render(view) =~ "Swarm Mode Orchestration"
    end

    test "mounts /docs/ai-agents/swarm-mode as guest", %{conn: _conn} do
      guest_conn = Phoenix.ConnTest.build_conn()
      {:ok, view, html} = live(guest_conn, "/docs/ai-agents/swarm-mode")
      assert html =~ "Swarm Mode Orchestration"
      assert render(view) =~ "Swarm Mode Orchestration"
    end

    test "mounts /docs as authenticated user without company memberships" do
      # Create an orphaned user with no company
      unique_id = System.unique_integer([:positive])

      {:ok, user} =
        Cympho.Users.create_user(%{
          email: "orphan_user_#{unique_id}@example.com",
          password: "password1234!",
          name: "Orphan User"
        })

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user_id, user.id)

      {:ok, view, html} = live(conn, "/docs")
      assert html =~ "What is Cympho?"
      assert render(view) =~ "What is Cympho?"
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Slug Resilience & Fallback Tests
  # ---------------------------------------------------------------------------
  describe "Adversarial Slug Resilience" do
    test "nonexistent topic and nonexistent section falls back gracefully", %{conn: conn} do
      {:ok, view, html} = live(conn, "/docs/nonexistent/bad-slug")
      assert html =~ "What is Cympho?"
      assert render(view) =~ "What is Cympho?"
    end

    test "nonexistent topic slug falls back gracefully", %{conn: conn} do
      {:ok, view, html} = live(conn, "/docs/totally-bogus-topic-slug-xyz")
      assert html =~ "What is Cympho?"
      assert render(view) =~ "What is Cympho?"
    end

    test "valid topic with nonexistent section falls back to topic default", %{conn: conn} do
      {:ok, view, html} = live(conn, "/docs/ai-agents/bogus-section")
      # ai-agents default doc is roles
      assert html =~ "Agent Roles &amp; Contracts"
      assert render(view) =~ "Agent Roles &amp; Contracts"
    end

    test "handles extreme length slugs without crashing", %{conn: conn} do
      long_topic = String.duplicate("a", 200)
      long_section = String.duplicate("b", 200)
      {:ok, _view, html} = live(conn, "/docs/#{long_topic}/#{long_section}")
      assert html =~ "What is Cympho?"
    end

    test "handles special characters in slugs without crashing", %{conn: conn} do
      for bad_slug <- ["---", "...", "%20", "12345"] do
        {:ok, _view, html} = live(conn, "/docs/#{bad_slug}/#{bad_slug}")
        assert html =~ "What is Cympho?"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Pagination Links Verification
  # ---------------------------------------------------------------------------
  describe "Pagination Links & Sequential Flow" do
    test "first doc has next link and no previous link", %{conn: conn} do
      first = Content.first_doc()
      assert is_nil(first.prev_doc)
      assert first.next_doc != nil

      {:ok, _view, html} = live(conn, "/docs/#{first.topic_slug}/#{first.section_slug}")
      refute html =~ "Previous"
      assert html =~ "Next"
    end

    test "last doc has previous link and no next link", %{conn: conn} do
      all = Content.all_docs()
      last = List.last(all)
      assert last.prev_doc != nil
      assert is_nil(last.next_doc)

      {:ok, _view, html} = live(conn, "/docs/#{last.topic_slug}/#{last.section_slug}")
      assert html =~ "Previous"
      refute html =~ "<span>Next</span>"
    end

    test "traversing sequential next links via patch across all docs in a topic", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs/getting-started/overview")

      html = render_patch(view, "/docs/getting-started/quickstart")
      assert html =~ "Quickstart Guide"

      html = render_patch(view, "/docs/getting-started/onboarding")
      assert html =~ "First-Run Onboarding"

      html = render_patch(view, "/docs/getting-started/interface-modes")
      assert html =~ "Interface Modes"
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Search Events & Fuzzing
  # ---------------------------------------------------------------------------
  describe "Adversarial Search Events" do
    test "empty string and whitespace-only searches do not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")
      render_click(view, "open_search")

      html1 = render_change(view, "search", %{"query" => ""})
      assert html1 =~ "Quick Documentation Search"

      html2 = render_change(view, "search", %{"query" => "    "})
      assert html2 =~ "No documentation matches found"
    end

    test "punctuation-only queries do not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")
      render_click(view, "open_search")

      for punct <- ["???", "!!!", "///", ":::", "...---...", "@#$%^&*()_+"] do
        html = render_change(view, "search", %{"query" => punct})
        assert is_binary(html)
      end
    end

    test "extreme length query does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")
      render_click(view, "open_search")

      giant_query = String.duplicate("orchestration ", 100)
      html = render_change(view, "search", %{"query" => giant_query})
      assert is_binary(html)
    end

    test "non-ASCII / unicode queries do not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")
      render_click(view, "open_search")

      for unicode_query <- ["日本語", "🚀🌟🔥", "müller", "états-unis", "привет"] do
        html = render_change(view, "search", %{"query" => unicode_query})
        assert is_binary(html)
      end
    end

    test "keyboard event handling in search modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")

      # Shortcut "/" opens search
      render_keydown(view, "search_keydown", %{"key" => "/"})
      assert render(view) =~ "Quick Documentation Search"

      # Arrow keys and navigation
      render_change(view, "search", %{"query" => "agent"})
      render_keydown(view, "search_keydown", %{"key" => "ArrowDown"})
      render_keydown(view, "search_keydown", %{"key" => "ArrowUp"})

      # Escape dismisses
      render_keydown(view, "search_keydown", %{"key" => "Escape"})
      refute render(view) =~ "docs-search-modal"

      # Reopen and enter submits
      render_click(view, "open_search")
      render_change(view, "search", %{"query" => "swarm mode"})
      render_keydown(view, "search_keydown", %{"key" => "Enter"})
      assert_patch(view, "/docs/ai-agents/swarm-mode")
    end

    test "search_submit with empty results does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")
      render_click(view, "open_search")
      render_change(view, "search", %{"query" => "unmatched_query_xyz_123456789"})

      # Submit when search_results is empty
      render_submit(view, "search_submit", %{})
      assert render(view) =~ "No documentation matches found"
    end

    test "queries that match diagrams with unicode characters (e.g., 'blocked', 'view', 'todo')",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/docs")
      render_click(view, "open_search")

      # Testing the exact queries that trigger unicode snippet slicing
      for query <- ["blocked", "view", "review", "done", "todo"] do
        html = render_change(view, "search", %{"query" => query})
        assert is_binary(html)

        results = Cympho.Docs.SearchIndex.search(query)

        for r <- results do
          assert String.valid?(r.snippet),
                 "Snippet for query '#{query}' on doc '#{r.doc.id}' is not valid UTF-8: #{inspect(r.snippet)}"

          assert {:ok, _} = Jason.encode(%{snippet: r.snippet}),
                 "Snippet for query '#{query}' on doc '#{r.doc.id}' cannot be JSON-encoded"
        end
      end
    end
  end
end
