defmodule CymphoWeb.IssueLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Issues
  alias Cympho.Comments
  alias Cympho.Agents

  setup do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Test Issue",
        description: "Test description for the issue",
        status: :backlog,
        priority: :high
      })

    %{issue: issue}
  end

  describe "Index - Issue List" do
    test "renders all issues", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "All Issues"
      assert html =~ issue.title
    end

    test "shows issue status badges", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "backlog"
      assert html =~ "high"
    end

    test "shows comment count", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "0 comments"
    end
  end

  describe "Show - Issue Detail" do
    test "renders issue detail", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ issue.title
      assert html =~ issue.description
      assert html =~ "backlog"
      assert html =~ "high"
    end

    test "renders comments section", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Comments"
      assert html =~ "Add Comment"
    end

    test "shows existing comments", %{issue: issue} do
      {:ok, _comment} =
        Comments.create_comment(%{
          body: "Test comment body",
          author_type: "user",
          author_id: "test-author",
          issue_id: issue.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Test comment body"
      assert html =~ "test-author"
    end

    test "comment form accepts input", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      form =
        form(view, "#comment-form", %{
          "comment" => %{
            "author_type" => "user",
            "author_id" => "new-author",
            "body" => "New comment body"
          }
        })

      assert form
    end
  end

  describe "Show - Inline Title Edit" do
    test "shows edit button for title", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "start_editing"
      assert html =~ ~s(field="title")
    end

    test "enters edit mode and saves title", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='title']")
      |> render_click()

      assert render(view) =~ "Save"
      assert render(view) =~ "Cancel"

      view
      |> form("form[phx-submit='save_title']", %{"title" => "Updated Title"})
      |> render_submit()

      assert render(view) =~ "Updated Title"
      assert render(view) =~ "Title updated"
    end

    test "rejects empty title", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='title']")
      |> render_click()

      view
      |> form("form[phx-submit='save_title']", %{"title" => "   "})
      |> render_submit()

      assert render(view) =~ "Title cannot be empty"
    end

    test "cancels title editing", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='title']")
      |> render_click()

      assert render(view) =~ "Cancel"

      view
      |> element("button[phx-click='cancel_editing']")
      |> render_click()

      refute render(view) =~ ~s(phx-submit="save_title")
    end
  end

  describe "Show - Inline Description Edit" do
    test "enters edit mode and saves description", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("button[phx-click='start_editing'][phx-value-field='description']")
      |> render_click()

      assert render(view) =~ ~s(phx-submit="save_description")

      view
      |> form("form[phx-submit='save_description']", %{"description" => "New description"})
      |> render_submit()

      assert render(view) =~ "New description"
      assert render(view) =~ "Description updated"
    end
  end

  describe "Show - Status Dropdown" do
    test "shows status dropdown with valid transitions", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "update_status"
      # backlog can transition to todo, in_progress, blocked
      assert html =~ ~s(value="todo")
      assert html =~ ~s(value="in_progress")
      assert html =~ ~s(value="blocked")
    end

    test "valid status transition succeeds", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> form("form[phx-change='update_status']", %{"status" => "todo"})
      |> render_change()

      assert render(view) =~ "Status updated to todo"

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :todo
    end

    test "invalid status transition shows error", %{issue: _issue} do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Blocked Issue",
          description: "Test",
          status: :in_review
        })

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      # in_review -> backlog is not valid
      view
      |> form("form[phx-change='update_status']", %{"status" => "backlog"})
      |> render_change()

      assert render(view) =~ "Invalid transition"
    end
  end

  describe "Show - Priority Dropdown" do
    test "shows priority dropdown", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "update_priority"
      assert html =~ ~s(value="low")
      assert html =~ ~s(value="medium")
      assert html =~ ~s(value="high")
    end

    test "priority change succeeds", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> form("form[phx-change='update_priority']", %{"priority" => "low"})
      |> render_change()

      assert render(view) =~ "Priority updated"

      updated = Issues.get_issue!(issue.id)
      assert updated.priority == :low
    end
  end

  describe "Show - Assignee Management" do
    test "shows search input when no assignee", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Search agents..."
      assert html =~ "search_assignee"
    end

    test "assigns an agent to the issue", %{issue: issue} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Test Agent",
          role: :engineer,
          status: :idle
        })

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("input[name='q']")
      |> render_change(%{"q" => "Test"})

      html = render(view)
      assert html =~ "Test Agent"

      view
      |> element("button[phx-click='assign_issue'][phx-value-agent_id='#{agent.id}']")
      |> render_click()

      html = render(view)
      assert html =~ "Test Agent"
      assert html =~ "Assignee updated"

      updated = Issues.get_issue!(issue.id)
      assert updated.assignee_id == agent.id
    end

    test "unassigns an agent from the issue", %{issue: issue} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Remove Me",
          role: :engineer,
          status: :running
        })

      {:ok, _} = Issues.update_issue(issue, %{assignee_id: agent.id})

      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      html = render(view)
      assert html =~ "Remove Me"

      view
      |> element("button[phx-click='unassign_issue']")
      |> render_click()

      html = render(view)
      assert html =~ "Assignee removed"

      updated = Issues.get_issue!(issue.id)
      assert updated.assignee_id == nil
    end

    test "shows agent status badge when assigned", %{issue: issue} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Busy Agent",
          role: :cto,
          status: :running
        })

      {:ok, _} = Issues.update_issue(issue, %{assignee_id: agent.id})

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Busy Agent"
      assert html =~ "running"
      assert html =~ "Remove"
    end
  end
end
