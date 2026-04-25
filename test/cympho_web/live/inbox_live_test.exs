defmodule CymphoWeb.InboxLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Issues
  alias Cympho.Agents
  alias Cympho.Inbox

  setup do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "Test Agent",
        role: :engineer,
        adapter: :claude_code
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Inbox Test Issue",
        description: "Issue for inbox testing",
        status: :todo,
        priority: :high
      })

    %{agent: agent, issue: issue}
  end

  describe "Index" do
    test "renders inbox page", %{agent: agent} do
      {:ok, _view, html} = live(conn(), "/inbox?agent_id=#{agent.id}")

      assert html =~ "Inbox"
    end

    test "shows prompt to select agent when none selected" do
      {:ok, _view, html} = live(conn(), "/inbox")

      assert html =~ "Select an agent to view their inbox"
    end

    test "shows empty state when no inbox items", %{agent: agent} do
      {:ok, _view, html} = live(conn(), "/inbox?agent_id=#{agent.id}")

      assert html =~ "No inbox items found"
    end

    test "shows inbox items for agent", %{agent: agent, issue: issue} do
      {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)

      {:ok, _view, html} = live(conn(), "/inbox?agent_id=#{agent.id}")

      assert html =~ issue.title
      assert html =~ "Unread"
    end

    test "marks item as read", %{agent: agent, issue: issue} do
      {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)

      {:ok, view, _html} = live(conn(), "/inbox?agent_id=#{agent.id}")

      view
      |> element("button[phx-click='mark_read']")
      |> render_click()

      html = render(view)
      assert html =~ "Read"
      refute html =~ ~r/>Unread</
    end

    test "dismisses item", %{agent: agent, issue: issue} do
      {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)

      {:ok, view, _html} = live(conn(), "/inbox?agent_id=#{agent.id}")

      view
      |> element("button[phx-click='dismiss']")
      |> render_click()

      html = render(view)
      assert html =~ "Dismissed"
    end

    test "archives item", %{agent: agent, issue: issue} do
      {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)

      {:ok, view, _html} = live(conn(), "/inbox?agent_id=#{agent.id}")

      view
      |> element("button[phx-click='archive']")
      |> render_click()

      html = render(view)
      assert html =~ "Archived"
    end

    test "restores archived item", %{agent: agent, issue: issue} do
      {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)
      {:ok, _} = Inbox.archive(issue.id, agent.id)

      {:ok, view, _html} = live(conn(), "/inbox?agent_id=#{agent.id}&status=archived")

      view
      |> element("button[phx-click='restore']")
      |> render_click()

      html = render(view)
      assert html =~ "Unread"
    end

    test "filters by status", %{agent: agent, issue: issue} do
      {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)
      {:ok, _} = Inbox.mark_read(issue.id, agent.id)

      {:ok, view, _html} = live(conn(), "/inbox?agent_id=#{agent.id}")

      view
      |> element("form[phx-change='filter_status'] select")
      |> render_change(%{"status" => "read"})

      html = render(view)
      assert html =~ issue.title

      view
      |> element("form[phx-change='filter_status'] select")
      |> render_change(%{"status" => "unread"})

      html = render(view)
      assert html =~ "No inbox items found"
    end

    test "issue links to detail page", %{agent: agent, issue: issue} do
      {:ok, _} = Inbox.ensure_inbox_entry(issue.id, agent.id)

      {:ok, _view, html} = live(conn(), "/inbox?agent_id=#{agent.id}")

      assert html =~ "/issues/#{issue.id}"
    end
  end
end
