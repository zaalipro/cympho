defmodule CymphoWeb.HumanReviewLiveTest do
  use CymphoWeb.LiveCase, async: true
  alias Cympho.{Agents, Comments, Companies, Issues, Repo, WorkProducts}
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Wakes.AgentWake

  setup %{conn: conn} do
    {:ok, reviewer} =
      Agents.create_agent(
        scoped_attrs(%{
          name: "Older agent reviewer",
          role: :cto,
          status: :offline,
          adapter: :process,
          config: %{"command" => "/usr/bin/false"}
        })
      )

    {:ok, issue} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Review feedback target",
          status: :in_review,
          assigned_role: "cto",
          assignee_id: reviewer.id,
          last_reviewer_id: reviewer.id
        })
      )

    wake =
      Repo.insert!(
        AgentWake.changeset(%AgentWake{}, %{
          agent_id: reviewer.id,
          issue_id: issue.id,
          reason: "final_review_required",
          triggered_by_type: "system"
        })
      )

    %{issue: issue, wake: wake, user_id: Plug.Conn.get_session(conn, :user_id)}
  end

  for {path, event, id_key} <- [
        {"/reviews", "request_changes", "id"},
        {"/inbox", "request_review_changes", "issue_id"}
      ] do
    test "#{path} requires a reason, cancels without mutation, and ignores forged identity",
         ctx do
      {:ok, view, _} = live(ctx.conn, unquote(path))
      params = %{unquote(id_key) => ctx.issue.id, "wake_id" => ctx.wake.id}
      html = render_hook(view, unquote(event), params)
      assert html =~ "Reason for requesting changes"
      assert Issues.get_issue!(ctx.issue.id).status == :in_review

      for reason <- ["", " \n\t "] do
        html =
          render_submit(element(view, "#review-changes-form"), %{
            "review" => %{"reason" => reason}
          })

        assert html =~ "Enter a reason"
        assert Comments.list_comments(ctx.issue.id) == []
        assert Repo.get!(AgentWake, ctx.wake.id).status == "pending"
      end

      render_click(element(view, "button[phx-click='cancel_review_changes']"))
      refute has_element?(view, "#review-changes-form")
      assert Issues.get_issue!(ctx.issue.id).status == :in_review
      render_hook(view, unquote(event), params)

      render_submit(element(view, "#review-changes-form"), %{
        "review" => %{
          "reason" => "Correct the gap.\nVerify the fix.",
          "reviewer_id" => Ecto.UUID.generate(),
          "issue_id" => Ecto.UUID.generate()
        },
        "last_reviewer_id" => Ecto.UUID.generate()
      })

      updated = Issues.get_issue!(ctx.issue.id)
      assert updated.status == :todo
      assert updated.last_human_reviewer_id == ctx.user_id
      assert [comment] = Comments.list_comments(ctx.issue.id)
      assert comment.author_type == "user"
      assert comment.author_id == ctx.user_id
      assert comment.body =~ "Correct the gap.\nVerify the fix."
      assert Repo.get!(AgentWake, ctx.wake.id).status == "consumed"
      {:ok, _rework_view, html} = live(ctx.conn, "/reviews")
      assert html =~ "last reviewed by Live User"
      refute html =~ "last reviewed by Older agent reviewer"
    end

    @tag membership_role: "viewer"
    test "#{path} rejects both review decisions for a read-only member", ctx do
      {:ok, view, _} = live(ctx.conn, unquote(path))
      params = %{unquote(id_key) => ctx.issue.id, "wake_id" => ctx.wake.id}

      for event <- [unquote(event), "approve_review", "submit_review_changes"] do
        render_hook(view, event, params)
        assert render(view) =~ "does not allow"
      end

      assert Issues.get_issue!(ctx.issue.id).status == :in_review
      assert Comments.list_comments(ctx.issue.id) == []
      assert Repo.get!(AgentWake, ctx.wake.id).status == "pending"
    end

    test "#{path} rejects inaccessible issue parameters", ctx do
      unique = System.unique_integer([:positive])

      {:ok, company} =
        Companies.create_company(%{name: "Foreign #{unique}", slug: "foreign-#{unique}"})

      {:ok, foreign} =
        Issues.create_issue(%{
          title: "Foreign review",
          company_id: company.id,
          status: :in_review
        })

      {:ok, view, _} = live(ctx.conn, unquote(path))

      for event <- [unquote(event), "approve_review"] do
        render_hook(view, event, %{
          unquote(id_key) => foreign.id,
          "wake_id" => ctx.wake.id
        })

        assert render(view) =~ "Issue not found"
      end

      assert Issues.get_issue!(ctx.issue.id).status == :in_review
      assert Issues.get_issue!(foreign.id).status == :in_review
      assert Comments.list_comments(foreign.id) == []
      assert Comments.list_comments(ctx.issue.id) == []
      assert Repo.get!(AgentWake, ctx.wake.id).status == "pending"
    end

    test "#{path} approves with user attribution only after existing gates pass", ctx do
      {:ok, view, _} = live(ctx.conn, unquote(path))

      params = %{
        unquote(id_key) => ctx.issue.id,
        "wake_id" => ctx.wake.id,
        "last_human_reviewer_id" => Ecto.UUID.generate()
      }

      render_hook(view, "approve_review", params)
      assert render(view) =~ "Approval gates blocking closure"
      assert Issues.get_issue!(ctx.issue.id).status == :in_review
      assert Comments.list_comments(ctx.issue.id) == []
      assert Repo.get!(AgentWake, ctx.wake.id).status == "pending"

      {:ok, issue} =
        Issues.update_issue(ctx.issue, %{description: "Verify the requested document."})

      for body <- [
            "[delivery] What happened: completed work. Files changed: document. Evidence produced: document and process run. Verification: process passed. Risks: none. Current state: ready. Next decision: review. Restart packet: inspect document and process result.",
            "[review] Verdict: accepted. What happened: inspected work. Evidence inspected: document and process run. Verification: process passed. Gaps: none. Follow-up issues: none. Next decision: close. Restart packet: inspect accepted evidence."
          ] do
        Repo.insert!(
          Cympho.Comments.Comment.changeset(%Cympho.Comments.Comment{}, %{
            issue_id: issue.id,
            author_type: "agent",
            author_id: issue.assignee_id,
            body: body
          })
        )
      end

      Repo.insert!(%Run{
        agent_id: issue.assignee_id,
        company_id: issue.company_id,
        issue_id: issue.id,
        status: "completed",
        adapter: "process"
      })

      {:ok, _} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: issue.assignee_id,
          kind: "document",
          title: "Evidence",
          description: "Reviewed document"
        })

      {:ok, ready_view, _} = live(ctx.conn, unquote(path))
      render_hook(ready_view, "approve_review", params)
      updated = Issues.get_issue!(issue.id)
      assert updated.status == :done
      assert updated.last_human_reviewer_id == ctx.user_id
      assert updated.last_reviewer_id == ctx.issue.last_reviewer_id
      assert Repo.get!(AgentWake, ctx.wake.id).status == "consumed"

      assert Enum.any?(
               Comments.list_comments(issue.id),
               &(&1.author_type == "user" and &1.author_id == ctx.user_id)
             )
    end

    test "#{path} rejects a form snapshot changed before submission", ctx do
      {:ok, view, _} = live(ctx.conn, unquote(path))

      render_hook(view, unquote(event), %{
        unquote(id_key) => ctx.issue.id,
        "wake_id" => ctx.wake.id
      })

      {:ok, _} = Issues.update_issue(ctx.issue, %{description: "Changed after opening"})

      html =
        render_submit(element(view, "#review-changes-form"), %{
          "review" => %{"reason" => "Fix it"}
        })

      assert html =~ "This review changed"
      assert Issues.get_issue!(ctx.issue.id).status == :in_review
      assert Comments.list_comments(ctx.issue.id) == []
      assert Repo.get!(AgentWake, ctx.wake.id).status == "pending"
    end
  end
end
