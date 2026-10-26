defmodule CymphoWeb.ApprovalLiveTest do
  use CymphoWeb.LiveCase, async: true

  import CymphoWeb.R3PageHelpers

  alias Cympho.{Agents, Approvals, Companies, Issues}

  describe "Approvals index" do
    test "renders a decision queue for company-scoped approvals", %{
      conn: conn,
      current_company: company
    } do
      grant_resolver(conn, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Approval Owner",
          role: :ceo,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Approve launch plan",
          description: "Needs owner decision before agents proceed.",
          company_id: company.id,
          status: :in_review
        })

      {:ok, pending} =
        Approvals.create_approval(%{
          type: "launch_gate",
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id]
        })

      {:ok, _approved} =
        Approvals.create_approval(%{
          type: "review_gate",
          status: :approved,
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id]
        })

      {:ok, _denied} =
        Approvals.create_approval(%{
          type: "budget_gate",
          status: :denied,
          requested_by_agent_id: agent.id
        })

      {:ok, _view, html} = live(conn, "/approvals")
      doc = main_doc(html)

      # r3 (v7 G1): a root page under Inbox, no primary; the lanes are the Status segments.
      assert_r3_page(doc, page: "approvals", h1: "Approval history", kind: :root, primaries: 0)

      assert texts(doc, ~s(nav.seg[aria-label="Status"] a)) ==
               ["All 3", "Waiting 1", "Approved 1", "Denied 1", "Cancelled 0"]

      assert html =~ ~s(data-testid="approval-command")
      assert html =~ ~s(data-testid="approvals-responsive-queue")
      assert html =~ ~s(data-testid="approval-row-#{pending.id}")
      assert html =~ "Decision queue"
      assert html =~ "Resolve 1 pending approval before agents proceed."
      assert html =~ "Oldest: Launch gate"
      assert html =~ "Review pending"
      assert html =~ ~s(href="/approvals?status=pending")
      # "Queue pressure" repeated the Pending count from two tiles to its left;
      # the oldest pending gate now sits on the Pending tile itself.
      refute html =~ "Queue pressure"
      refute html =~ "Approved path"
      # r3: no Simple stat tiles (the segments carry the counts).
      refute html =~ "ui-simple-card"
      assert html =~ "launch_gate"

      pending_row = ~s([data-testid="approval-row-#{pending.id}"])
      # The title opens the record; the meta says who asked and what waits on it.
      assert Floki.attribute(doc, pending_row <> " a.rt2", "href") == ["/approvals/#{pending.id}"]
      assert text(doc, pending_row <> " .rm") =~ "Requested by Approval Owner"
      assert text(doc, pending_row <> " .rm") =~ "1 linked task"
      assert text(doc, pending_row <> " .lr-st") == "Waiting for you"
      assert html =~ ~s(data-testid="approval-approve-#{pending.id}")
      assert html =~ ~s(data-testid="approval-deny-#{pending.id}")

      assert Floki.find(doc, ~s(#approval-issues-#{pending.id} a[href="/issues/#{issue.id}"])) !=
               []

      assert html =~ "review_gate"
      assert html =~ "budget_gate"

      assert texts(doc, ".lrow .lr-st") |> Enum.sort() == [
               "Approved",
               "Denied",
               "Waiting for you"
             ]

      {:ok, _view, filtered_html} = live(conn, "/approvals?status=pending")

      assert filtered_html =~ "Filtered to Pending approvals."
      assert filtered_html =~ "Clear filter"
      assert filtered_html =~ "launch_gate"
      assert filtered_html =~ ~s(data-testid="approval-approve-#{pending.id}")
      assert filtered_html =~ "1 linked task"

      assert texts(main_doc(filtered_html), ~s(nav.seg a[aria-current])) == ["Waiting 1"]
      refute filtered_html =~ "review_gate"
      refute filtered_html =~ "budget_gate"

      {:ok, _view, empty_filtered_html} = live(conn, "/approvals?status=cancelled")

      assert empty_filtered_html =~ "Filtered to Cancelled approvals."
      assert empty_filtered_html =~ "No cancelled approvals in this lane"
      assert empty_filtered_html =~ "Clear the filter to see everything"
      assert empty_filtered_html =~ ~s(href="/approvals")
      assert empty_filtered_html =~ "Activity"
      refute empty_filtered_html =~ "No approvals yet."
    end

    test "approves an approval inline from the queue", %{
      conn: conn,
      current_company: company
    } do
      grant_resolver(conn, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Inline Approver",
          role: :ceo,
          company_id: company.id
        })

      {:ok, approval} =
        Approvals.create_approval(%{
          type: "inline_gate",
          requested_by_agent_id: agent.id
        })

      {:ok, view, _html} = live(conn, "/approvals")

      html = render_click(view, :approve, %{"id" => approval.id})

      refute html =~ ~s(data-testid="approval-approve-#{approval.id}")

      assert text(main_doc(html), ~s([data-testid="approval-row-#{approval.id}"] .lr-st)) ==
               "Approved"

      # The handler's flash is now drawn (v7 §1.7).
      assert text(main_doc(html), ".flash-line [role=status]") == "Approved"

      resolved = Approvals.get_approval!(approval.id)
      assert resolved.status == :approved
      assert resolved.resolved_by_user_id == Plug.Conn.get_session(conn, :user_id)
    end

    test "denies an approval inline from the queue", %{
      conn: conn,
      current_company: company
    } do
      grant_resolver(conn, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Inline Denier",
          role: :ceo,
          company_id: company.id
        })

      {:ok, approval} =
        Approvals.create_approval(%{
          type: "deny_gate",
          requested_by_agent_id: agent.id
        })

      {:ok, view, _html} = live(conn, "/approvals")

      html = render_click(view, :deny, %{"id" => approval.id})

      refute html =~ ~s(data-testid="approval-deny-#{approval.id}")

      assert text(main_doc(html), ~s([data-testid="approval-row-#{approval.id}"] .lr-st)) ==
               "Denied"

      resolved = Approvals.get_approval!(approval.id)
      assert resolved.status == :denied
    end

    test "ordinary members cannot resolve from the queue, including forged events", %{
      conn: conn,
      current_company: company
    } do
      set_resolver_role(conn, company, "member")

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Read-only Approval Member",
          role: :ceo,
          company_id: company.id
        })

      {:ok, approval} =
        Approvals.create_approval(%{
          type: "member_gate",
          requested_by_agent_id: agent.id
        })

      {:ok, view, html} = live(conn, "/approvals")

      refute html =~ ~s(data-testid="approval-approve-#{approval.id}")
      refute html =~ ~s(data-testid="approval-deny-#{approval.id}")

      html = render_click(view, :approve, %{"id" => approval.id})

      flash = :sys.get_state(view.pid).socket.assigns.flash

      assert Phoenix.Flash.get(flash, :error) ==
               "Only company owners, admins, and board members can resolve approvals."

      assert text(main_doc(html), ".flash-line [role=alert]") ==
               "Only company owners, admins, and board members can resolve approvals."

      assert text(main_doc(html), ~s([data-testid="approval-row-#{approval.id}"] .lr-st)) ==
               "Waiting for a decision"

      assert Approvals.get_approval!(approval.id).status == :pending
    end

    test "status filter event patches to the selected status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/approvals")

      render_change(view, :filter_status, %{"status" => "approved"})

      assert_patch(view, "/approvals?status=approved")
    end

    test "invalid status params fall back to all approvals", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/approvals?status=not-real")

      assert html =~ "Approval history"
      assert html =~ "Decision queue"
      refute html =~ "Filtered to"
    end
  end

  describe "Approval detail" do
    test "renders an owner decision packet and attributes approval to the current user", %{
      conn: conn,
      current_company: company
    } do
      grant_resolver(conn, company)

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Detail Approval Owner",
          role: :ceo,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Ship detail flow",
          description: "Approval detail should explain the decision.",
          company_id: company.id,
          status: :in_review
        })

      {:ok, approval} =
        Approvals.create_approval(%{
          type: "release_gate",
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id],
          payload: %{"action" => "ship", "risk" => "medium"}
        })

      {:ok, view, html} = live(conn, "/approvals/#{approval.id}")
      doc = main_doc(html)

      # r3 (v7 G2): a deep page under Approval history whose Next step is the decision.
      assert_r3_page(doc,
        page: "approval",
        h1: "Release gate",
        kind: :deep,
        parent: "Approval history",
        primaries: 1
      )

      assert page_title(view) =~ "Release gate"
      assert html =~ ~s(data-testid="approval-decision-packet")
      assert text(doc, ".head .sub") =~ "Requested by Detail Approval Owner"
      assert text(doc, ".head .chips") == "Waiting for you"
      assert text(doc, ".next .paper .nt") == "Decide on Detail Approval Owner's request"
      assert html =~ "Your decision"
      assert text(doc, ".next .ink .conseq") =~ "After you approve: the linked work can continue."

      assert text(doc, ".next .ink .conseq") =~
               "After you deny: Detail Approval Owner is told to stop or revise."

      assert texts(doc, ".next .ink .pw") == ["Approve"]
      assert Floki.attribute(doc, ".next .ink .pd", "phx-click") == ["deny"]
      assert Floki.attribute(doc, ".next .ink .pd", "data-confirm") != []
      assert html =~ "Ship detail flow"
      # A "Payload keys" panel listed the same labels the Evidence list already
      # prints beside their values.
      refute html =~ "Payload keys"
      assert html =~ "Risk"
      assert html =~ "release_gate"

      approved_html = render_click(view, :approve)
      approved_doc = main_doc(approved_html)

      assert_r3_page(approved_doc,
        page: "approval",
        h1: "Release gate",
        kind: :deep,
        parent: "Approval history",
        primaries: 0
      )

      assert text(approved_doc, ".head .chips") == "Approved"
      assert approved_html =~ "Approved via UI"
      assert approved_html =~ ~s(data-testid="approval-decision-packet")
      refute approved_html =~ "Deny"

      approval = Approvals.get_approval!(approval.id)

      assert approval.status == :approved
      assert approval.resolved_by_user_id == Plug.Conn.get_session(conn, :user_id)
    end

    test "ordinary members cannot resolve from approval detail events", %{
      conn: conn,
      current_company: company
    } do
      set_resolver_role(conn, company, "member")

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Read-only Detail Member",
          role: :ceo,
          company_id: company.id
        })

      {:ok, approval} =
        Approvals.create_approval(%{
          type: "detail_member_gate",
          requested_by_agent_id: agent.id
        })

      {:ok, view, html} = live(conn, "/approvals/#{approval.id}")

      refute has_element?(view, "button[phx-click='approve']")
      refute has_element?(view, "button[phx-click='deny']")
      # The problem card stands alone: no resolution card, no primary.
      assert_r3_page(main_doc(html),
        page: "approval",
        h1: "Detail member gate",
        kind: :deep,
        parent: "Approval history",
        primaries: 0
      )

      assert text(main_doc(html), ".head .chips") == "Waiting for a decision"
      assert html =~ "Only owners, admins and board members can decide this."

      html = render_click(view, :deny)

      flash = :sys.get_state(view.pid).socket.assigns.flash

      assert Phoenix.Flash.get(flash, :error) ==
               "Only company owners, admins, and board members can resolve approvals."

      # The handler's flash is drawn now (v7 §1.7, G2).
      assert text(main_doc(html), ".flash-line [role=alert]") ==
               "Only company owners, admins, and board members can resolve approvals."

      assert Approvals.get_approval!(approval.id).status == :pending
    end

    test "reads acronyms in capitals and names the resolver, not their email", %{
      conn: conn,
      current_company: company
    } do
      grant_resolver(conn, company)
      resolver = Cympho.Users.get_user!(Plug.Conn.get_session(conn, :user_id))

      {:ok, agent} =
        Agents.create_agent(%{name: "Acronym Agent", role: :cto, company_id: company.id})

      {:ok, approval} =
        Approvals.create_approval(%{
          type: "external_api_access",
          requested_by_agent_id: agent.id,
          payload: %{"amount_usd" => 40}
        })

      {:ok, list_view, _html} = live(conn, "/approvals")

      assert text(main_doc(list_view), ~s([data-testid="approval-row-#{approval.id}"] .rt2)) ==
               "External API access"

      {:ok, view, html} = live(conn, "/approvals/#{approval.id}")
      doc = main_doc(html)

      assert texts(doc, "h1") == ["External API access"]
      assert "Amount USD" in texts(doc, ~s(section[aria-labelledby="ap-evidence-t"] dt))

      approved = view |> render_click(:approve) |> main_doc()
      aside = ~s(section[aria-labelledby="ap-det-t"])

      details =
        Enum.zip(texts(approved, aside <> " dt"), texts(approved, aside <> " dd")) |> Map.new()

      assert details["Resolved by"] == resolver.name
    end
  end

  describe "Approval detail navigation" do
    setup %{current_company: company} do
      {:ok, agent} =
        Agents.create_agent(%{name: "Nav Owner", role: :ceo, company_id: company.id})

      {:ok, approval} =
        Approvals.create_approval(%{type: "nav_gate", requested_by_agent_id: agent.id})

      %{approval: approval}
    end

    test "goes back to Approval history by default", %{conn: conn, approval: approval} do
      {:ok, _view, html} = live(conn, "/approvals/#{approval.id}")
      doc = main_doc(html)

      assert Floki.attribute(doc, ".crumb .back", "href") == ["/approvals"]
      assert Floki.find(doc, ".ctx .ret") == []
    end

    test "offers Back to the page it was opened from", %{conn: conn, approval: approval} do
      {:ok, _view, html} = live(conn, "/approvals/#{approval.id}?from=/inbox")
      doc = main_doc(html)

      assert Floki.attribute(doc, ".crumb .back", "href") == ["/approvals"]
      assert text(doc, ".ctx .ret") == "Back to Inbox"
      assert Floki.attribute(doc, ".ctx .ret", "href") == ["/inbox"]
    end

    test "ignores a from that is not on the allow-list", %{conn: conn, approval: approval} do
      {:ok, _view, html} = live(conn, "/approvals/#{approval.id}?from=https://evil.example")

      assert Floki.find(main_doc(html), ".ctx .ret") == []
    end
  end

  defp grant_resolver(conn, company) do
    set_resolver_role(conn, company, "owner")
  end

  defp set_resolver_role(conn, company, role) do
    user_id = Plug.Conn.get_session(conn, :user_id)
    membership = Companies.get_membership(user_id, company.id)
    {:ok, _membership} = Companies.update_membership(membership, %{role: role})
  end
end
