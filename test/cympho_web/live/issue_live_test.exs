defmodule CymphoWeb.IssueLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Issues
  alias Cympho.Comments
  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Projects
  alias Cympho.Repo
  alias Cympho.Users
  alias Cympho.WorkProducts

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

    test "shows issue status badges", %{issue: _issue} do
      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "backlog"
      assert html =~ "high"
    end

    test "shows comment count", %{issue: _issue} do
      {:ok, _view, html} = live(conn(), "/issues")

      assert html =~ "0 comments"
    end
  end

  describe "New - Owner request routing" do
    test "creates authenticated company issues as CEO-owned todo work" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Owner Route Co",
          slug: "owner-route-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Projects.create_project(%{
          name: "Operating Project",
          prefix: "OR",
          company_id: company.id
        })

      {:ok, launch_project} =
        Projects.create_project(%{
          name: "Launch Project",
          prefix: "LP",
          company_id: company.id
        })

      {:ok, user} =
        Users.create_user(%{
          email: "owner-route-#{System.unique_integer([:positive])}@example.com",
          name: "Owner"
        })

      {:ok, _membership} =
        Companies.create_membership(%{
          user_id: user.id,
          company_id: company.id,
          role: "owner",
          is_board_member: true
        })

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "CEO",
          role: :ceo,
          status: :idle,
          company_id: company.id,
          project_id: project.id
        })

      conn =
        conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session("user_id", user.id)
        |> Plug.Conn.put_session("company_id", company.id)

      {:ok, view, html} = live(conn, "/issues/new")

      assert html =~ "Owner intake"
      assert html =~ "First stop:"
      assert html =~ "CEO"
      assert html =~ "Project"
      assert html =~ "Operating Project"
      assert html =~ "Launch Project"

      view
      |> form("form", %{
        "issue" => %{
          "title" => "Owner asks for onboarding",
          "description" => "CEO should decompose this.",
          "project_id" => launch_project.id
        }
      })
      |> render_submit()

      [created] = Issues.list_issues(%{company_id: company.id})
      assert created.title == "Owner asks for onboarding"
      assert created.status == :todo
      assert created.assignee_id == ceo.id
      assert created.assigned_role == "ceo"
      assert created.project_id == launch_project.id
      assert created.created_by_user_id == user.id
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

    test "renders execution brief and per-agent contribution cards", %{issue: issue} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} = Issues.update_issue(issue, %{assignee_id: agent.id})

      {:ok, _comment} =
        Comments.create_comment(%{
          body: "Implemented the smoke path and verified the LiveView renders.",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        status: "completed",
        adapter: "claude_code",
        continuation_summary: "Tests passed for the smoke path."
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: agent.id,
          kind: "code_change",
          title: "Smoke implementation",
          description: "Changed the issue detail page and added coverage."
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Execution brief"
      assert html =~ "Owner update"
      assert html =~ "Agent contributions"
      assert html =~ "Runtime Agent"
      assert html =~ "Implemented the smoke path"
      assert html =~ "Smoke implementation"
      assert html =~ "Code work exists but no PR link is set."
    end

    test "shows direct sub-issues", %{issue: issue} do
      {:ok, _child} =
        Issues.create_issue(%{
          title: "Child execution task",
          description: "Engineer-owned acceptance criteria",
          status: :todo,
          priority: :medium,
          parent_id: issue.id
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Sub-issues"
      assert html =~ "Child execution task"
      assert html =~ "Engineer-owned acceptance criteria"
    end

    test "renders work products in the activity timeline", %{issue: issue} do
      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          kind: "code_change",
          title: "Implementation diff",
          description: "Changed the LiveView and added tests."
        })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Work product"
      assert html =~ "Implementation diff"
      assert html =~ "Changed the LiveView and added tests."
    end

    test "shows failed run reason in the activity timeline", %{issue: issue} do
      {:ok, agent} =
        Agents.create_agent(%{
          name: "Runtime Agent",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      Repo.insert!(%Run{
        agent_id: agent.id,
        issue_id: issue.id,
        status: "failed",
        adapter: "claude_code",
        error_reason: "Adapter command exited with code 1",
        log_excerpt: "missing provider configuration"
      })

      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "Adapter command exited with code 1"
      assert html =~ "missing provider configuration"
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

  describe "Show - Status Combobox" do
    test "shows status combobox with valid transitions", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "combobox_status"
      # backlog can transition to todo, in_progress, blocked
      assert html =~ ~s(data-combobox-id="todo")
      assert html =~ ~s(data-combobox-id="in_progress")
      assert html =~ ~s(data-combobox-id="blocked")
    end

    test "valid status transition succeeds", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "todo"})

      assert render(view) =~ "Status updated to todo"

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :todo
    end

    test "invalid status transition shows error", %{issue: _issue} do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Done Issue",
          description: "Test",
          status: :backlog
        })

      # backlog -> done is not a valid direct transition
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-status-combobox")
      |> render_hook("combobox_status", %{"selected" => "done"})

      assert render(view) =~ "Invalid transition"
    end
  end

  describe "Show - Priority Combobox" do
    test "shows priority combobox", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "combobox_priority"
      assert html =~ ~s(data-combobox-id="low")
      assert html =~ ~s(data-combobox-id="medium")
      assert html =~ ~s(data-combobox-id="high")
    end

    test "priority change succeeds", %{issue: issue} do
      {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

      view
      |> element("#issue-priority-combobox")
      |> render_hook("combobox_priority", %{"selected" => "low"})

      assert render(view) =~ "Priority updated"

      updated = Issues.get_issue!(issue.id)
      assert updated.priority == :low
    end
  end

  describe "Show - Assignee Management" do
    test "shows assignee combobox when no assignee", %{issue: issue} do
      {:ok, _view, html} = live(conn(), "/issues/#{issue.id}")

      assert html =~ "combobox_assignee"
      assert html =~ "Unassigned"
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
      |> element("#issue-assignee-combobox")
      |> render_hook("combobox_assignee", %{"selected" => agent.id})

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
      |> element("#issue-assignee-combobox")
      |> render_hook("combobox_assignee", %{"selected" => nil})

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
    end
  end
end
