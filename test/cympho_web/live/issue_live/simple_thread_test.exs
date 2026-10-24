defmodule CymphoWeb.IssueLive.SimpleThreadTest do
  @moduledoc """
  Simple mode must always show the issue thread (comment bodies), pending
  interaction resolve controls, and the deliverables — without relying on the
  Advanced-only activity timeline.

  r3: the Simple thread, proof strip and interaction cards became the r3 Task
  page's Thread card, Deliverables card and Next step (plan P2); the same
  behaviours are asserted on the new markup.
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

    # r3: the thread, deliverables and runs are the page itself (both modes).
    assert has_element?(view, "[data-testid='issue-simple-proof']")
    assert has_element?(view, "#runs li.step", "Run finished")
    assert html =~ "Finished draft."
    assert html =~ "Launch notes"
    # Deliverables with URLs are clickable links (not inert spans).
    assert has_element?(view, "#deliverables a[href='https://example.com/launch-notes']")

    # Comment bodies are readable outside the advanced timeline.
    assert has_element?(view, "#thread .msg-b", "Owner-visible note about the launch plan.")
    assert has_element?(view, "#thread .msg-h", "Thread Agent")

    # The oldest pending interaction is the Next step, with its resolve controls;
    # the next one waits in the thread and becomes the Next step after it.
    assert has_element?(view, ".next .paper", "Approve shipping the draft?")

    assert has_element?(
             view,
             ".next .ink button[phx-value-id='#{confirmation.id}'][phx-value-status='accepted']",
             "Confirm"
           )

    assert has_element?(
             view,
             ".next .ink button[phx-value-id='#{confirmation.id}'][phx-value-status='rejected']",
             "Decline"
           )

    assert has_element?(view, "#thread .thread-old", "Asked you something that is still open.")

    view
    |> element(".next .ink button[phx-value-status='accepted']")
    |> render_click()

    assert has_element?(view, ".next .paper .quote", "Ship this week?")
    assert has_element?(view, ".next form.ink input[name='_id'][value='#{questions.id}']")
    assert has_element?(view, ".next form.ink textarea[name='own_response']")
    assert has_element?(view, ".next .pw", "Send answer")

    # Composers remain available: the thread's reply box and Advanced's template composer.
    assert has_element?(view, "#thread form.composer[phx-submit='add_comment']")
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

    {:ok, view, html} = live(conn, "/issues/#{issue.id}")

    assert html =~ "Owner follow-up from Simple mode."
    assert html =~ user.name
    # r3: the thread names people by first name, as the mockups do.
    assert has_element?(view, "#thread .msg-h b", hd(String.split(user.name)))
    refute html =~ user.id
  end

  test "advanced-only panels stay gated; the r3 page shows in both modes", %{issue: issue} do
    {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

    # r3: the Task page itself is not mode-gated; the operator panels are.
    assert has_element?(view, "[data-ui-complex-page] #thread")
    refute has_element?(view, ".ui-advanced-only #thread")
    assert has_element?(view, ".ui-advanced-only #issue-activity")
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

    # r3: the confirmation is the Next step.
    selector = ".next .ink button[phx-value-id='#{interaction.id}'][phx-value-status='accepted']"
    assert has_element?(view, selector)

    view
    |> element(selector, "Confirm")
    |> render_click()

    reloaded = Repo.get!(IssueThreadInteraction, interaction.id)
    assert reloaded.status == :accepted
    refute has_element?(view, ".next .ink button[phx-value-id='#{interaction.id}']")
    assert has_element?(view, "#thread .thread-old", "Asked you to confirm · Accepted")
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

    # r3: the task proposal is the Next step.
    assert has_element?(view, ".next .paper", "Write follow-up")

    view
    |> element(
      ".next .ink button[phx-value-id='#{interaction.id}'][phx-value-status='rejected']",
      "Reject"
    )
    |> render_click()

    reloaded = Repo.get!(IssueThreadInteraction, interaction.id)
    assert reloaded.status == :rejected
    assert has_element?(view, "#thread .thread-old", "Proposed tasks · Rejected")
    refute has_element?(view, ".next .ink button[phx-value-id='#{interaction.id}']")
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

    # r3: the question is the Next step's answer form.
    assert has_element?(view, ".next form#ns-answer input[name='_id'][value='#{interaction.id}']")

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
    assert has_element?(view, "#thread .thread-old", "Asked you: “Which market first?”")
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

    assert has_element?(view, "#deliverables a[href='https://example.com/simple-proof']")

    [wp] = WorkProducts.list_work_products(issue.id)
    assert wp.title == "Simple Proof Bundle"
    assert wp.url == "https://example.com/simple-proof"
  end

  test "simple set-PR gate opens form, saves URL, and proof chip links to PR", %{issue: issue} do
    {:ok, project} =
      Cympho.Projects.create_project(
        scoped_attrs(%{
          name: "Simple thread PR project",
          prefix: "STPR",
          repo_url: "https://github.com/acme/app"
        })
      )

    {:ok, _issue} =
      Issues.update_issue(issue, %{
        description: "Owner request is clear.",
        status: :in_progress,
        assigned_role: "engineer",
        project_id: project.id
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
    assert has_element?(view, "#deliverables a[href='#{pr_url}']", "PR")

    reloaded = Issues.get_issue!(issue.id)
    assert reloaded.github_pr_url == pr_url
  end
end
