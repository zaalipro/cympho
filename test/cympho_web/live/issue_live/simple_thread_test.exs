defmodule CymphoWeb.IssueLive.SimpleThreadTest do
  @moduledoc """
  Simple mode must always show the issue thread (comment bodies), pending
  interaction resolve controls, and a compact proof strip — without relying
  on the Advanced-only activity timeline.
  """
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.Agents
  alias Cympho.Comments
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.IssueThreadInteractions
  alias Cympho.Issues
  alias Cympho.Issues.IssueThreadInteraction
  alias Cympho.Repo
  alias Cympho.WorkProducts

  defp create_agent(attrs), do: Agents.create_agent(scoped_attrs(attrs))
  defp create_issue(attrs), do: Issues.create_issue(scoped_attrs(attrs))

  setup do
    {:ok, agent} =
      create_agent(%{
        name: "Thread Agent",
        role: :engineer,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      create_issue(%{
        title: "Simple thread issue",
        description: "Owners from Inbox need to read comments and answer interactions.",
        status: :in_progress,
        priority: :high,
        assignee_id: agent.id
      })

    %{issue: issue, agent: agent}
  end

  test "simple markup shows comment bodies, proof chips, and interaction resolve controls", %{
    issue: issue,
    agent: agent
  } do
    {:ok, _comment} =
      Comments.create_comment(%{
        issue_id: issue.id,
        author_type: "agent",
        author_id: agent.id,
        body: "Owner-visible note about the launch plan."
      })

    Repo.insert!(%Run{
      agent_id: agent.id,
      issue_id: issue.id,
      company_id: issue.company_id,
      status: "completed",
      adapter: "process",
      continuation_summary: "Finished draft."
    })

    {:ok, _wp} =
      WorkProducts.create_work_product(%{
        issue_id: issue.id,
        title: "Launch notes",
        kind: "url",
        url: "https://example.com/launch-notes",
        created_by_agent_id: agent.id
      })

    {:ok, confirmation} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: issue.id,
        kind: :request_confirmation,
        created_by_agent_id: agent.id,
        payload: %{"message" => "Approve shipping the draft?"}
      })

    {:ok, questions} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: issue.id,
        kind: :ask_user_questions,
        created_by_agent_id: agent.id,
        payload: %{
          "message" => "Need a decision:",
          "questions" => [%{"question" => "Ship this week?"}]
        }
      })

    {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

    # Simple thread + proof always present (CSS-gated via ui-simple-only).
    assert has_element?(view, "#issue-simple-thread.ui-simple-only")
    assert has_element?(view, "[data-testid='issue-simple-proof']")
    assert has_element?(view, "[data-testid='issue-simple-proof-run']")
    assert html =~ "Finished draft."
    assert has_element?(view, "[data-testid='issue-simple-proof-product']")
    assert html =~ "Launch notes"
    # Proof chips with URLs are clickable links (not inert spans).
    assert has_element?(
             view,
             "a[data-testid='issue-simple-proof-product'][href='https://example.com/launch-notes']"
           )

    # Comment bodies are readable outside the advanced timeline.
    assert has_element?(view, "[data-testid='simple-comment-body']")
    assert html =~ "Owner-visible note about the launch plan."
    assert html =~ "Thread Agent"

    # Pending interaction resolve controls.
    assert has_element?(view, "#simple-interaction-#{confirmation.id}")

    assert has_element?(
             view,
             "#simple-interaction-#{confirmation.id} [data-testid='simple-interaction-resolve']"
           )

    assert html =~ "Approve shipping the draft?"
    assert html =~ "Confirm"
    assert html =~ "Reject"

    assert has_element?(view, "#simple-interaction-#{questions.id}")

    assert has_element?(
             view,
             "#simple-interaction-#{questions.id} [data-testid='simple-interaction-response']"
           )

    assert html =~ "Ship this week?"
    assert html =~ "Respond"

    # Composer remains available below the thread.
    assert has_element?(view, "#issue-comments #comment-form")
  end

  test "user comments show the person's name, not their id", %{issue: issue} do
    conn = conn()
    user_id = Plug.Conn.get_session(conn, :user_id)
    {:ok, user} = Cympho.Users.get_user(user_id)

    {:ok, _comment} =
      Comments.create_comment(%{
        issue_id: issue.id,
        author_type: "user",
        author_id: user.id,
        body: "Owner follow-up from Simple mode."
      })

    {:ok, _view, html} = live(conn, "/issues/#{issue.id}")

    assert html =~ "Owner follow-up from Simple mode."
    assert html =~ user.name
    refute html =~ user.id
  end

  test "advanced-only panels stay gated; simple thread is simple-only", %{issue: issue} do
    {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

    assert has_element?(view, "#issue-simple-thread.ui-simple-only")
    assert html =~ ~r/class="[^"]*ui-advanced-only[^"]*"/

    # Activity timeline (full advanced feed) remains behind the advanced gate.
    assert has_element?(view, "#issue-activity")
    # Parent wrapper of the timeline is ui-advanced-only in show.html.heex.
    assert html =~ ~s(id="issue-activity")
  end

  test "resolve_interaction from simple confirmation card accepts and clears pending", %{
    issue: issue,
    agent: agent
  } do
    {:ok, interaction} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: issue.id,
        kind: :request_confirmation,
        created_by_agent_id: agent.id,
        payload: %{"message" => "Confirm the simple-card path?"}
      })

    {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

    assert has_element?(
             view,
             "#simple-interaction-#{interaction.id} button[phx-value-status='accepted']"
           )

    html =
      view
      |> element(
        "#simple-interaction-#{interaction.id} button[phx-value-status='accepted']",
        "Confirm"
      )
      |> render_click()

    reloaded = Repo.get!(IssueThreadInteraction, interaction.id)
    assert reloaded.status == :accepted
    refute html =~ ~s(data-interaction-status="pending")
    assert html =~ ~s(data-interaction-status="accepted")
  end

  test "resolve_interaction from simple card can reject", %{issue: issue, agent: agent} do
    {:ok, interaction} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: issue.id,
        kind: :suggest_tasks,
        created_by_agent_id: agent.id,
        payload: %{
          "message" => "Proposed follow-ups",
          "tasks" => [%{"title" => "Write follow-up", "description" => "Owner-visible task"}]
        }
      })

    {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

    html =
      view
      |> element(
        "#simple-interaction-#{interaction.id} button[phx-value-status='rejected']",
        "Reject"
      )
      |> render_click()

    reloaded = Repo.get!(IssueThreadInteraction, interaction.id)
    assert reloaded.status == :rejected
    assert html =~ ~s(data-interaction-status="rejected")

    refute has_element?(
             view,
             "#simple-interaction-#{interaction.id} [data-testid='simple-interaction-resolve']"
           )
  end

  test "respond_questions from simple card stores the response", %{issue: issue, agent: agent} do
    {:ok, interaction} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: issue.id,
        kind: :ask_user_questions,
        created_by_agent_id: agent.id,
        payload: %{
          "message" => "Quick question",
          "questions" => [%{"question" => "Which market first?"}]
        }
      })

    {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

    assert has_element?(view, "#simple-respond-form-#{interaction.id}")

    html =
      render_hook(view, "respond_questions", %{
        "_id" => interaction.id,
        "response" => "Start with the US market."
      })

    reloaded = Repo.get!(IssueThreadInteraction, interaction.id)
    assert reloaded.status == :responded
    # Response is posted as a thread comment (not written onto payload).
    assert Enum.any?(Comments.list_comments(issue.id), &(&1.body == "Start with the US market."))
    assert html =~ "Start with the US market."
    assert html =~ ~s(data-interaction-status="responded")
  end

  test "simple attach-proof gate opens form and attaches work product", %{issue: issue} do
    {:ok, issue} =
      Issues.update_issue(issue, %{
        description: "Owner request is clear.",
        status: :in_progress
      })

    {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

    assert has_element?(view, "[data-testid='issue-simple-gate-work_product']", "Attach proof")
    assert html =~ "Attach proof"

    html =
      view
      |> element("[data-testid='issue-simple-gate-work_product']")
      |> render_click()

    assert html =~ "Work product form opened"
    assert has_element?(view, "#issue-simple-work-product-form")
    assert has_element?(view, "#simple-work-product-form")

    html =
      view
      |> form("#simple-work-product-form", %{
        "work_product" => %{
          "title" => "Simple Proof Bundle",
          "kind" => "url",
          "url" => "https://example.com/simple-proof",
          "description" => "Owner-visible proof from Simple mode."
        }
      })
      |> render_submit()

    assert html =~ "Work product attached"
    assert html =~ "Simple Proof Bundle"

    assert has_element?(
             view,
             "a[data-testid='issue-simple-proof-product'][href='https://example.com/simple-proof']"
           )

    [wp] = WorkProducts.list_work_products(issue.id)
    assert wp.title == "Simple Proof Bundle"
    assert wp.url == "https://example.com/simple-proof"
  end

  test "simple set-PR gate opens form, saves URL, and proof chip links to PR", %{issue: issue} do
    {:ok, _issue} =
      Issues.update_issue(issue, %{
        description: "Owner request is clear.",
        status: :in_progress,
        assigned_role: "engineer"
      })

    {:ok, view, _html} = live(conn(), "/issues/#{issue.id}")

    # Drive the gate event directly so the form path is covered even when PR
    # is not currently listed as the primary digest action.
    html = render_click(view, "resolve_review_gate", %{"action" => "code_reference"})

    assert html =~ "Set the pull request URL below"
    assert has_element?(view, "#issue-simple-pr-form")
    assert has_element?(view, "#simple-pr-form")

    pr_url = "https://github.com/acme/app/pull/99"

    html =
      view
      |> form("#simple-pr-form", %{"url" => pr_url})
      |> render_submit()

    assert html =~ "PR link saved"
    assert has_element?(view, "a[data-testid='issue-simple-proof-pr'][href='#{pr_url}']")

    reloaded = Issues.get_issue!(issue.id)
    assert reloaded.github_pr_url == pr_url
  end
end
