defmodule CymphoWeb.IssueLive.R3TaskTest do
  @moduledoc """
  The r3 Task page (plan P2) on the Northwind dataset: the deep page frame, the
  header chips, the Next step by task state (question, review, retry,
  cancelled, all clear), the thread, deliverables, runs and the details rail.
  """
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.{Comments, Companies, IssueThreadInteractions, Issues, R3Fixtures, Repo, Users}
  alias Cympho.Issues.IssueThreadInteraction

  setup do
    nw = R3Fixtures.northwind!()
    %{nw: nw, conn: session_conn(nw.user, nw.company)}
  end

  defp open(conn, nw, key, query \\ ""),
    do: live(conn, "/issues/#{nw.issues[key].id}#{query}")

  describe "NW-6: a question parks the task" do
    test "deep frame, chips, now capsule, the question pair and one primary", %{
      conn: conn,
      nw: nw
    } do
      {:ok, view, _html} = open(conn, nw, "NW-6", "?from=/")
      doc = doc(view)

      assert [_] = Floki.find(doc, ".frame[data-page='task']")
      assert [_] = Floki.find(doc, "[data-page='task'] header[data-ctx='deep']")
      assert [_] = Floki.find(doc, "[data-page='task'] .tray.split")
      assert text(doc, "nav[aria-label='Breadcrumb'] a.back") == "Tasks"
      assert text(doc, "nav[aria-label='Breadcrumb'] [aria-current='page']") == "NW-6"
      assert hrefs(Floki.find(doc, "a.ret")) == ["/"]
      assert text(doc, "a.ret") == "Back to Home"

      assert [h1] = Floki.find(doc, "h1")
      assert squish(Floki.text(h1)) == "Connect Stripe payments"

      assert text(doc, "#issue-status-chip button.chip.st-wait") == "Waiting on you"
      assert text(doc, "#issue-assignee-chip button.chip") =~ "Ravi"
      assert text(doc, "#issue-priority-chip button.chip") == "High"
      assert text(doc, "details.brief > summary") =~ "Maya's brief"
      assert text(doc, "details.brief blockquote") == nw.issues["NW-6"].description

      now = text(doc, ".head .now.waiting")
      assert now =~ "Ravi is waiting for your answer"
      assert now =~ "No run is live on NW-6"

      assert text(doc, ".next .paper .nt") == "Answer Ravi's question"
      eyebrow = text(doc, ".next .paper .eyebrow")
      assert eyebrow =~ "Question"
      assert eyebrow =~ hhmm(nw, 208)

      assert text(doc, ".next .paper .quote") ==
               "When a customer's card payment fails, what should happen first?"

      foot = text(doc, ".next .paper .pf")
      assert foot =~ "Ravi"
      assert foot =~ "Engineer"
      assert hrefs(Floki.find(doc, ".next .paper .pf a")) == ["#thread"]

      [form] = Floki.find(doc, ".next form.ink[phx-submit='respond_questions']")
      radios = Floki.find(form, "input[type='radio'][name='response']")

      assert Enum.flat_map(radios, &Floki.attribute(&1, "value")) == [
               "Retry automatically after 3 days",
               "Email the customer first",
               "Both: email now, retry in 3 days",
               "own"
             ]

      assert Floki.find(form, "input[checked]") == []
      assert [_] = Floki.find(form, "textarea[name='own_response']")

      assert text(form, ".ink-note") ==
               "After you send: Ravi gets your answer as a comment and is asked to carry on with NW-6."

      assert [primary] = Floki.find(doc, ".pw")
      assert squish(Floki.text(primary)) == "Send answer"
    end

    test "thread, deliverables, runs and details", %{conn: conn, nw: nw} do
      {:ok, view, _html} = open(conn, nw, "NW-6")
      doc = doc(view)

      latest = text(doc, "#thread > .msg")
      assert latest =~ "While you decide on retries, I'm wiring the webhook handler"
      assert latest =~ "Latest update"
      assert latest =~ "Ravi"

      assert text(doc, "#thread details.earlier > summary") ==
               "Earlier in the thread · 4 messages · 3 finished runs"

      earlier = text(doc, "#thread details.earlier .thread-old")
      assert earlier =~ "Use idempotency keys on the webhook"
      assert earlier =~ "Asked you a question. It is open in the Next step above."
      assert earlier =~ "Run finished · 22 min · $2.31"

      assert text(doc, "#thread form.composer label") == "Reply to Ravi"

      assert text(doc, "#thread form.composer .help") ==
               "Ravi sees this the next time they work on this task."

      tiles = Floki.find(doc, "#deliverables .objt")
      assert length(tiles) == 2
      assert text(doc, "#deliverables") =~ "Payment flow spec"
      assert text(doc, "#deliverables") =~ "PR #44 Stripe Checkout (draft)"

      assert "https://github.com/northwind-demo/invoicing-app/pull/44" in hrefs(
               Floki.find(doc, "#deliverables a")
             )

      # The time in each deliverable's line is set in mono, as in the mockup.
      assert Enum.map(Floki.find(doc, "#deliverables .objt-s .mono"), &squish(Floki.text(&1))) ==
               [hhmm(nw, 2416), hhmm(nw, 509)]

      assert text(doc, "#deliverables .objt-d .objt-s") =~ ~r/^Document · Ravi · \S+ \d\d:\d\d$/

      steps = Floki.find(doc, "#runs li.step")
      assert Enum.map(steps, &text(&1, ".step-c")) == ["$2.31", "$3.42", "$1.12"]
      assert text(hd(steps), ".step-t") =~ "Run finished · 22 min"

      details = text(doc, "aside.task-aside")
      assert details =~ "Invoicing app"
      assert details =~ "Ship the Northwind invoicing app to its first 10 paying customers"
      assert details =~ "$6.85 so far"
      assert details =~ "by Maya"

      assert hrefs(Floki.find(doc, "aside.task-aside a")) == [
               "/workspace/#{nw.issues["NW-6"].id}",
               "/tool-call-traces"
             ]

      # The Advanced timeline lists the numbered answers of the question (B3).
      render_click(view, "set_timeline_filter", %{"filter" => "all"})
      assert text(doc(view), "#timeline-stream") =~ "1. Retry automatically after 3 days"
    end

    test "Back appears only for an allow-listed origin other than the parent", %{
      conn: conn,
      nw: nw
    } do
      for query <- ["?from=//evil.example", "?from=https://evil.example", "?from=/issues", ""] do
        {:ok, view, _html} = open(conn, nw, "NW-6", query)
        assert Floki.find(doc(view), "a.ret") == [], "unexpected Back for #{inspect(query)}"
      end

      {:ok, view, _html} = open(conn, nw, "NW-6", "?from=/inbox")
      assert text(doc(view), "a.ret") == "Back to Inbox"
    end

    test "sending a numbered answer posts it, moves the task to To do and clears the step", %{
      conn: conn,
      nw: nw
    } do
      q1 = nw.questions["Q1"]
      {:ok, view, _html} = open(conn, nw, "NW-6")

      html =
        view
        |> form(".next form.ink", %{"_id" => q1.id, "response" => "Email the customer first"})
        |> render_submit()

      assert html =~ "Answer sent."
      assert Repo.get!(IssueThreadInteraction, q1.id).status == :responded
      assert Issues.get_issue!(nw.issues["NW-6"].id).status == :todo

      assert Enum.any?(
               Comments.list_comments(nw.issues["NW-6"].id),
               &(&1.body == "Email the customer first" and &1.author_type == "user")
             )

      doc = doc(view)
      assert text(doc, ".next .paper .nt") == "Nothing needed from you"
      assert text(doc, ".next .paper .eyebrow") =~ "Queued"
      assert text(doc, "#issue-status-chip button.chip") == "To do"
    end

    test "the own answer is sent when that row is chosen", %{conn: conn, nw: nw} do
      q1 = nw.questions["Q1"]
      {:ok, view, _html} = open(conn, nw, "NW-6")

      view
      |> form(".next form.ink", %{
        "_id" => q1.id,
        "response" => "own",
        "own_response" => "Retry once tomorrow, then email."
      })
      |> render_submit()

      assert Enum.any?(
               Comments.list_comments(nw.issues["NW-6"].id),
               &(&1.body == "Retry once tomorrow, then email.")
             )
    end

    test "an empty answer is refused", %{conn: conn, nw: nw} do
      q1 = nw.questions["Q1"]
      {:ok, view, _html} = open(conn, nw, "NW-6")

      html =
        view
        |> form(".next form.ink", %{"_id" => q1.id, "response" => "own", "own_response" => "  "})
        |> render_submit()

      assert html =~ "Choose an answer or write your own."
      assert Repo.get!(IssueThreadInteraction, q1.id).status == :pending
    end

    test "a question of another task cannot be answered from this page", %{conn: conn, nw: nw} do
      q2 = nw.questions["Q2"]
      {:ok, view, _html} = open(conn, nw, "NW-6")

      html = render_submit(view, "respond_questions", %{"_id" => q2.id, "response" => "One plan"})

      assert html =~ "Interaction not found"
      assert Repo.get!(IssueThreadInteraction, q2.id).status == :pending

      html = render_submit(view, "respond_questions", %{"_id" => "not-a-uuid", "response" => "x"})
      assert html =~ "Interaction not found"
    end
  end

  describe "NW-4: review" do
    test "the review pair decides here, with the evidence first", %{conn: conn, nw: nw} do
      {:ok, view, _html} = open(conn, nw, "NW-4")
      doc = doc(view)

      assert text(doc, "#issue-status-chip button.chip.st-wait") == "Waiting on you"
      assert text(doc, ".next .paper .nt") == "Review Ravi's work"
      assert text(doc, ".next .paper .obj") =~ "Invoice creation and PDF export — PR #42"
      assert hrefs(Floki.find(doc, ".next .paper .pf a")) == ["#deliverables"]

      ink = text(doc, ".next .ink")
      assert ink =~ "Decide on NW-4"
      assert ink =~ "After you accept: NW-4 is marked Done."

      assert ink =~
               "After you send it: NW-4 goes back to To do with your note, for the next free engineer."

      assert [primary] = Floki.find(doc, ".pw")
      assert squish(Floki.text(primary)) == "Accept & close"
      assert Floki.attribute(primary, "phx-click") == ["approve_review"]
      assert text(doc, ".next .ink .pd") == "Request changes"

      # The dataset's NW-4 lacks the evidence gates HumanReview keeps, so the page
      # says what closing needs instead of offering a button that is refused.
      assert text(doc, ".next .paper .gate") =~ "Closing needs:"
      assert text(doc, ".next .paper .gate") =~ "CTO/CEO review decision"
      assert Floki.attribute(primary, "disabled") != []
    end

    test "Accept & close marks a review with its evidence done", %{conn: conn, nw: nw} do
      issue = closable_review!(nw)
      {:ok, view, _html} = live(conn, "/issues/#{issue.id}")
      doc = doc(view)

      assert text(doc, ".next .paper .nt") == "Review Ravi's work"
      assert Floki.find(doc, ".next .paper .gate") == []
      assert [primary] = Floki.find(doc, ".pw")
      assert Floki.attribute(primary, "disabled") == []

      html = view |> element(".next .ink .pw") |> render_click()

      assert html =~ "#{issue.identifier} is marked Done."
      closed = Issues.get_issue!(issue.id)
      assert closed.status == :done
      assert closed.completed_at
      assert text(doc(view), "#issue-status-chip button.chip") == "Done"
    end

    test "Request changes needs a note, then sends the task back to To do", %{
      conn: conn,
      nw: nw
    } do
      {:ok, view, _html} = open(conn, nw, "NW-4")

      view |> element(".next .ink .pd", "Request changes") |> render_click()
      assert [_] = Floki.find(doc(view), ".next form.ink textarea[name='review[reason]']")
      assert [primary] = Floki.find(doc(view), ".pw")
      assert squish(Floki.text(primary)) == "Send it"

      html = view |> form(".next form.ink", %{"review" => %{"reason" => " "}}) |> render_submit()
      assert html =~ "Enter a reason for requesting changes."
      assert Issues.get_issue!(nw.issues["NW-4"].id).status == :in_review

      html =
        view
        |> form(".next form.ink", %{"review" => %{"reason" => "Add the tax line to the PDF."}})
        |> render_submit()

      assert html =~ "NW-4 went back to To do with your note."
      issue = Issues.get_issue!(nw.issues["NW-4"].id)
      assert issue.status == :todo
      assert is_nil(issue.assignee_id)
    end
  end

  describe "NW-10: decide who retries" do
    test "unassigned, was Mira; the assignee choice with paused agents disabled", %{
      conn: conn,
      nw: nw
    } do
      {:ok, view, _html} = open(conn, nw, "NW-10")
      doc = doc(view)

      assert text(doc, "#issue-assignee-chip button.chip") == "Unassigned · was Mira"
      assert text(doc, "#issue-status-chip button.chip") == "Blocked"
      assert text(doc, ".next .paper .nt") == "Decide who retries NW-10"
      assert text(doc, ".next .paper .obj") =~ "3 runs failed;"
      assert text(doc, ".next .paper .obj") =~ "nobody is assigned now (was Mira)."

      [form] = Floki.find(doc, ".next form.ink[phx-submit='assign_and_retry']")
      ravi = nw.agents["Ravi"].id
      mira = nw.agents["Mira"].id
      theo = nw.agents["Theo"].id

      values =
        form
        |> Floki.find("input[name='agent_id']")
        |> Enum.flat_map(&Floki.attribute(&1, "value"))

      assert values == [ravi, theo, mira]
      assert Floki.attribute(Floki.find(form, "input[value='#{ravi}']"), "checked") != []
      assert Floki.attribute(Floki.find(form, "input[value='#{mira}']"), "disabled") != []
      assert text(form, "label[for='agent_id-1'] .ot-s") == "Engineer · Idle"

      assert text(form, ".ink-note") ==
               "After you assign: NW-10 goes to Ravi and starts when they're free; this band then says Queued or Started."

      assert [primary] = Floki.find(doc, ".pw")
      assert squish(Floki.text(primary)) == "Assign and retry"

      render_change(view, "pick_retry_agent", %{"agent_id" => theo})
      assert text(doc(view), ".next .ink-note") =~ "NW-10 goes to Theo and starts when"
    end

    test "Assign and retry assigns, reopens and prioritises the task", %{conn: conn, nw: nw} do
      ravi = nw.agents["Ravi"]
      {:ok, view, _html} = open(conn, nw, "NW-10")

      html = view |> form(".next form.ink", %{"agent_id" => ravi.id}) |> render_submit()

      assert html =~ "NW-10 goes to Ravi."
      issue = Issues.get_issue!(nw.issues["NW-10"].id)
      assert issue.assignee_id == ravi.id
      assert issue.status == :todo
      assert Issues.dispatch_pinned?(issue)
    end

    test "a paused agent or another company's agent is refused", %{conn: conn, nw: nw} do
      other = R3Fixtures.northwind!()
      {:ok, view, _html} = open(conn, nw, "NW-10")

      html = render_submit(view, "assign_and_retry", %{"agent_id" => nw.agents["Mira"].id})
      assert html =~ "Mira is paused. Choose someone else."

      html = render_submit(view, "assign_and_retry", %{"agent_id" => other.agents["Ravi"].id})
      assert html =~ "Agent not found"

      html = render_submit(view, "assign_and_retry", %{})
      assert html =~ "Choose who should retry it."
      render_change(view, "pick_retry_agent", %{"_target" => ["agent_id"]})

      issue = Issues.get_issue!(nw.issues["NW-10"].id)
      assert is_nil(issue.assignee_id)
      assert issue.status == :blocked
      refute Issues.dispatch_pinned?(issue)
    end

    test "a viewer cannot assign and retry", %{nw: nw} do
      {:ok, viewer} =
        Users.create_user(%{
          email: "viewer-#{System.unique_integer([:positive])}@northwind.example",
          name: "Vic Viewer",
          password: "password1234"
        })

      {:ok, _} =
        Companies.create_membership(%{
          user_id: viewer.id,
          company_id: nw.company.id,
          role: "viewer"
        })

      {:ok, view, _html} = open(session_conn(viewer, nw.company), nw, "NW-10")

      html = render_submit(view, "assign_and_retry", %{"agent_id" => nw.agents["Ravi"].id})
      assert html =~ "Your company role does not allow that action."
      assert is_nil(Issues.get_issue!(nw.issues["NW-10"].id).assignee_id)
    end
  end

  describe "NW-11: cancelled" do
    test "reads Cancelled, never Done, and offers Reopen", %{conn: conn, nw: nw} do
      {:ok, view, html} = open(conn, nw, "NW-11")
      doc = doc(view)

      assert text(doc, "#issue-status-chip button.chip") == "Cancelled"
      refute text(doc, "#issue-status-chip button.chip") =~ "Done"
      assert text(doc, ".next .paper .eyebrow") == "Cancelled"
      assert text(doc, ".next .paper .nt") =~ "Cancelled on"
      assert text(doc, ".next .paper .obj") =~ "Not before the first 10 customers"
      assert text(doc, ".next .paper .obj") =~ "Maya"
      refute html =~ ~s(class="chip st-wait")

      assert [primary] = Floki.find(doc, ".pw")
      assert squish(Floki.text(primary)) == "Reopen"

      view |> element(".next .ink .pw") |> render_click()
      assert Issues.get_issue!(nw.issues["NW-11"].id).status == :todo
    end
  end

  describe "NW-9: all clear" do
    test "nothing needed; the live review run shows in the now capsule", %{conn: conn, nw: nw} do
      {:ok, view, _html} = open(conn, nw, "NW-9")
      doc = doc(view)

      assert text(doc, ".next .paper .nt") == "Nothing needed from you"
      assert text(doc, ".next .paper .eyebrow") =~ "All clear"
      assert text(doc, ".head .now.working") =~ "Theo is reviewing Jun's work"
      assert text(doc, ".next .ink .ink-note") == "Sending asks Jun to read it now."
      assert text(doc, "#thread form.composer .help") == "Sending asks Jun to read it now."

      assert [primary] = Floki.find(doc, ".pw")
      assert squish(Floki.text(primary)) == "Add a comment"
      assert Floki.find(doc, "#issue-priority-chip") == []
    end
  end

  test "a reply from the thread composer is posted and the box clears", %{conn: conn, nw: nw} do
    {:ok, view, _html} = open(conn, nw, "NW-9")
    [textarea] = Floki.find(doc(view), "#thread form.composer textarea")
    [before_id] = Floki.attribute(textarea, "id")

    view
    |> form("#thread form.composer", %{"comment" => %{"body" => "Looks close; ship it."}})
    |> render_submit()

    assert Enum.any?(
             Comments.list_comments(nw.issues["NW-9"].id),
             &(&1.body == "Looks close; ship it.")
           )

    [after_id] = Floki.attribute(Floki.find(doc(view), "#thread form.composer textarea"), "id")
    refute after_id == before_id
  end

  test "a CEO update handed back for sign-off is decided from the Next step", %{
    conn: conn,
    nw: nw
  } do
    ada = nw.agents["Ada"]

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: nw.company.id,
        title: "Verify the launch plan",
        description: "Owner should verify the CEO first turn.",
        status: :blocked,
        priority: :high,
        assignee_id: ada.id,
        assigned_role: "ceo"
      })

    Repo.insert!(%Cympho.HeartbeatEngine.Run{
      agent_id: ada.id,
      issue_id: issue.id,
      company_id: nw.company.id,
      status: "completed",
      adapter: "claude_code",
      continuation_summary: "CEO owner update produced."
    })

    for body <- [
          "[owner_update] What happened: CEO produced the first turn. Business status: not shipped. Current state: waiting on owner verification. Next decision: owner accepts and closes. Owner decision needed: verify.",
          "[blocked] Cause: Waiting for owner to verify the smoke test output. Current state: blocked on owner verification. Next decision: owner closes after verification."
        ] do
      {:ok, _} =
        Comments.create_comment(%{
          body: body,
          author_type: "agent",
          author_id: ada.id,
          issue_id: issue.id
        })
    end

    {:ok, view, _html} = live(conn, "/issues/#{issue.id}")
    doc = doc(view)

    assert text(doc, ".next .paper .nt") == "Review Ada's update"
    assert text(doc, "#issue-status-chip button.chip.st-wait") == "Waiting on you"

    assert text(doc, ".next .ink") =~
             "After you ask for a revision: #{issue.identifier} goes back to To do for Ada."

    assert [primary] = Floki.find(doc, ".pw")
    assert squish(Floki.text(primary)) == "Accept and close"

    view |> element(".next .ink .pw") |> render_click()
    assert Issues.get_issue!(issue.id).status == :done
  end

  test "several questions are answered together and keep their offered answers visible", %{
    conn: conn,
    nw: nw
  } do
    issue = nw.issues["NW-5"]

    {:ok, ask} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: issue.id,
        kind: :ask_user_questions,
        created_by_agent_id: nw.agents["Ada"].id,
        payload: %{
          "questions" => [
            %{"question" => "Which day should the demo run?", "options" => ["Friday", "Monday"]},
            %{"question" => "Who should attend?"}
          ]
        }
      })

    {:ok, view, _html} = open(conn, nw, "NW-5")
    doc = doc(view)

    assert text(doc, ".next .paper .nt") == "Answer Ada's questions"
    assert [first, second] = Floki.find(doc, ".next .paper .qs > li")

    assert first |> Floki.find(".qs-o li") |> Enum.map(&squish(Floki.text(&1))) == [
             "1. Friday",
             "2. Monday"
           ]

    assert Floki.find(second, ".qs-o") == []
    assert [_] = Floki.find(doc, ".next form.ink textarea[name='own_response']")
    assert Floki.find(doc, ".next form.ink input[type='radio']") == []

    view
    |> form(".next form.ink", %{"_id" => ask.id, "own_response" => "1. Friday 2. Ada and Theo"})
    |> render_submit()

    assert Repo.get!(IssueThreadInteraction, ask.id).status == :responded
  end

  test "pending confirmations decide from the Next step", %{conn: conn, nw: nw} do
    issue = nw.issues["NW-5"]

    {:ok, confirmation} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: issue.id,
        kind: :request_confirmation,
        created_by_agent_id: nw.agents["Ada"].id,
        payload: %{
          "message" => "Ship the demo on Friday?",
          "details" => "Stakeholders meet Friday."
        }
      })

    {:ok, view, _html} = open(conn, nw, "NW-5")
    doc = doc(view)
    assert text(doc, ".next .paper .nt") == "Confirm Ada's request"
    assert text(doc, ".next .paper") =~ "Ship the demo on Friday?"
    assert [primary] = Floki.find(doc, ".pw")
    assert squish(Floki.text(primary)) == "Confirm"

    view |> element(".next .ink .pw") |> render_click()
    assert Repo.get!(IssueThreadInteraction, confirmation.id).status == :accepted
  end

  # An in-review task with the evidence the review gates need (a tagged
  # delivery note, a tagged review note, a finished run, a deliverable) and a
  # pending final-review wake, so the owner can close it.
  defp closable_review!(nw) do
    ravi = nw.agents["Ravi"]

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: nw.company.id,
        title: "Export invoices as CSV",
        description: "Add a CSV export of invoices.",
        status: :in_review,
        priority: :medium,
        assigned_role: "engineer",
        assignee_id: ravi.id
      })

    for body <- [
          "[delivery] What happened: completed work. Files changed: export. Evidence produced: CSV and process run. Verification: process passed. Risks: none. Current state: ready. Next decision: review. Restart packet: inspect the CSV.",
          "[review] Verdict: accepted. What happened: inspected work. Evidence inspected: CSV and process run. Verification: process passed. Gaps: none. Follow-up issues: none. Next decision: close. Restart packet: inspect accepted evidence."
        ] do
      {:ok, _} =
        Comments.create_comment(%{
          issue_id: issue.id,
          author_type: "agent",
          author_id: ravi.id,
          body: body
        })
    end

    Repo.insert!(%Cympho.HeartbeatEngine.Run{
      agent_id: ravi.id,
      company_id: nw.company.id,
      issue_id: issue.id,
      status: "completed",
      adapter: "process"
    })

    {:ok, _} =
      Cympho.WorkProducts.create_work_product(%{
        issue_id: issue.id,
        created_by_agent_id: ravi.id,
        kind: "document",
        title: "CSV sample",
        description: "Exported invoices"
      })

    Repo.insert!(%Cympho.Wakes.AgentWake{
      agent_id: ravi.id,
      issue_id: issue.id,
      reason: "final_review_required",
      status: "pending",
      triggered_by_type: "system",
      triggered_by_id: issue.id
    })

    Issues.get_issue!(issue.id)
  end

  defp session_conn(user, company) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_id", user.id)
    |> Plug.Conn.put_session("company_id", company.id)
  end

  defp doc(view), do: view |> render() |> Floki.parse_fragment!()
  defp text(node, selector), do: node |> Floki.find(selector) |> Floki.text() |> squish()
  defp squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
  defp hrefs(nodes), do: Enum.flat_map(nodes, &Floki.attribute(&1, "href"))

  defp hhmm(nw, minutes),
    do: nw.anchor |> R3Fixtures.at(minutes) |> Calendar.strftime("%H:%M")
end
