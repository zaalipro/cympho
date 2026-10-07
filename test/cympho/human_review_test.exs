defmodule Cympho.HumanReviewTest do
  use CymphoWeb.LiveCase, async: false

  alias Cympho.{Activities, AgentActions, Agents, Comments, Companies, Issues, Repo, WorkProducts}
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Wakes.AgentWake

  setup %{conn: conn} do
    user_id = Plug.Conn.get_session(conn, :user_id)

    {:ok, reviewer} =
      Agents.create_agent(
        scoped_attrs(%{
          name: "Agent reviewer",
          role: :cto,
          status: :offline,
          adapter: :process,
          config: %{"command" => "/usr/bin/false"}
        })
      )

    {:ok, issue} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Human review",
          description: "Verify the requested document against acceptance criteria.",
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

    %{issue: issue, reviewer: reviewer, user_id: user_id, wake: wake}
  end

  test "blank reasons leave issue, conversation, identity and wakes unchanged", ctx do
    for reason <- [nil, "", " \n\t "] do
      assert {:error, :reason_required} =
               Issues.review_issue(ctx.issue, current_company_id(), ctx.user_id, :request_changes,
                 reason: reason,
                 wake_id: ctx.wake.id
               )

      assert Issues.get_issue!(ctx.issue.id).status == :in_review
      assert Comments.list_comments(ctx.issue.id) == []
      assert Repo.get!(AgentWake, ctx.wake.id).status == "pending"
    end
  end

  test "feedback and user identity commit with rework and all matching review wakes", ctx do
    reason = "Fix the acceptance gap.\nKeep this second line intact."

    assert {:ok, updated} =
             Issues.review_issue(ctx.issue, current_company_id(), ctx.user_id, :request_changes,
               reason: reason
             )

    assert updated.status == :todo
    assert updated.assigned_role == "engineer"
    assert updated.assignee_id == nil
    assert updated.last_reviewer_id == ctx.reviewer.id
    assert updated.last_human_reviewer_id == ctx.user_id
    assert Repo.get!(AgentWake, ctx.wake.id).status == "consumed"
    assert [comment] = Comments.list_comments(ctx.issue.id)
    assert comment.author_type == "user"
    assert comment.author_id == ctx.user_id
    assert comment.body == "[review] Verdict: changes requested.\nReason: " <> reason

    assert Enum.any?(Activities.list_activities(ctx.issue.id), fn a ->
             a.action == "approval_requested_changes" and a.actor_type == "user" and
               a.actor_id == ctx.user_id
           end)
  end

  test "duplicates and stale snapshots do not create another comment or consume a wake", ctx do
    {:ok, newer} = Issues.update_issue(ctx.issue, %{description: "Updated evidence"})

    assert {:error, :stale_review} =
             Issues.review_issue(ctx.issue, current_company_id(), ctx.user_id, :request_changes,
               reason: "Fix it"
             )

    assert Comments.list_comments(ctx.issue.id) == []
    assert Repo.get!(AgentWake, ctx.wake.id).status == "pending"

    assert {:ok, _} =
             Issues.review_issue(newer, current_company_id(), ctx.user_id, :request_changes,
               reason: "Fix it"
             )

    assert {:error, :stale_review} =
             Issues.review_issue(newer, current_company_id(), ctx.user_id, :request_changes,
               reason: "Duplicate"
             )

    assert length(Comments.list_comments(ctx.issue.id)) == 1
  end

  test "read-only and inaccessible companies fail closed", ctx do
    membership = Companies.get_membership(ctx.user_id, current_company_id())
    {:ok, _} = Companies.update_membership(membership, %{role: "viewer"})

    for decision <- [:approve, :request_changes] do
      assert {:error, :forbidden} =
               Issues.review_issue(ctx.issue, current_company_id(), ctx.user_id, decision,
                 reason: "Fix it",
                 wake_id: ctx.wake.id
               )

      assert {:error, :not_found} =
               Issues.review_issue(ctx.issue, Ecto.UUID.generate(), ctx.user_id, decision,
                 reason: "Fix it"
               )
    end

    assert Issues.get_issue!(ctx.issue.id).status == :in_review
    assert Comments.list_comments(ctx.issue.id) == []
    assert Repo.get!(AgentWake, ctx.wake.id).status == "pending"
  end

  test "foreign and non-review wake parameters cannot be consumed", ctx do
    {:ok, other} = Issues.create_issue(scoped_attrs(%{title: "Other", status: :in_review}))

    foreign =
      Repo.insert!(
        AgentWake.changeset(%AgentWake{}, %{
          agent_id: ctx.reviewer.id,
          issue_id: other.id,
          reason: "final_review_required",
          triggered_by_type: "system"
        })
      )

    unrelated =
      Repo.insert!(
        AgentWake.changeset(%AgentWake{}, %{
          agent_id: ctx.reviewer.id,
          issue_id: ctx.issue.id,
          reason: "manual_dispatch",
          triggered_by_type: "system"
        })
      )

    for wake <- [foreign, unrelated] do
      assert {:error, :wake_not_found} =
               Issues.review_issue(ctx.issue, current_company_id(), ctx.user_id, :request_changes,
                 reason: "Fix it",
                 wake_id: wake.id
               )

      assert Repo.get!(AgentWake, wake.id).status == "pending"
    end

    assert Issues.get_issue!(ctx.issue.id).status == :in_review
    assert Comments.list_comments(ctx.issue.id) == []
  end

  test "approval preserves evidence gates and attributes a successful decision", ctx do
    assert {:error, {:review_gates_blocked, %{message: message}}} =
             Issues.review_issue(ctx.issue, current_company_id(), ctx.user_id, :approve)

    assert message =~ "Runtime verification"
    assert Repo.get!(AgentWake, ctx.wake.id).status == "pending"
    refute Map.get(Issues.get_issue!(ctx.issue.id), :last_human_reviewer_id)
    add_evidence(ctx)

    assert {:ok, closed} =
             Issues.review_issue(ctx.issue, current_company_id(), ctx.user_id, :approve,
               wake_id: ctx.wake.id
             )

    assert closed.status == :done
    assert closed.last_human_reviewer_id == ctx.user_id
    assert closed.last_reviewer_id == ctx.reviewer.id
    assert Repo.get!(AgentWake, ctx.wake.id).status == "consumed"

    assert Enum.any?(
             Comments.list_comments(ctx.issue.id),
             &(&1.author_type == "user" and &1.author_id == ctx.user_id and
                 String.contains?(&1.body, "Verdict: approved"))
           )
  end

  test "wake persistence failure rolls back issue, comment, identity and activity", ctx do
    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_human_review_wake() RETURNS trigger AS $$
    BEGIN
      IF NEW.id = '#{ctx.wake.id}'::uuid AND NEW.status = 'consumed' THEN
        RAISE EXCEPTION 'synthetic wake persistence failure';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER reject_human_review_wake BEFORE UPDATE ON agent_wakes
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_human_review_wake()
    """)

    before_activities = Activities.list_activities(ctx.issue.id)

    assert {:error, :persistence_failed} =
             Issues.review_issue(ctx.issue, current_company_id(), ctx.user_id, :request_changes,
               reason: "Fix it"
             )

    assert Issues.get_issue!(ctx.issue.id).status == :in_review
    refute Map.get(Issues.get_issue!(ctx.issue.id), :last_human_reviewer_id)
    assert Comments.list_comments(ctx.issue.id) == []
    assert Repo.get!(AgentWake, ctx.wake.id).status == "pending"
    assert Activities.list_activities(ctx.issue.id) == before_activities
    refute Process.get(:cympho_agent_actions_defer_terminal_effects, false)
  end

  test "agent, human and later agent rounds preserve distinct identities and routing", ctx do
    reason =
      "Evidence inspected: review document. Required changes: correct the acceptance gap. Verification required: run the focused test. Next action: resubmit for review."

    action = %{"type" => "request_changes", "role" => "engineer", "reason" => reason}
    assert {:ok, _} = AgentActions.execute(ctx.issue, ctx.reviewer, [action])
    first = Issues.get_issue!(ctx.issue.id)
    assert first.last_reviewer_id == ctx.reviewer.id
    assert first.last_human_reviewer_id == nil

    assert Enum.any?(
             Comments.list_comments(first.id),
             &(&1.author_type == "agent" and &1.author_id == ctx.reviewer.id)
           )

    {:ok, second} = Issues.update_issue(first, %{status: :in_review, assigned_role: "cto"})

    assert {:ok, human} =
             Issues.review_issue(second, current_company_id(), ctx.user_id, :request_changes,
               reason: "Correct the second acceptance gap."
             )

    assert human.last_human_reviewer_id == ctx.user_id
    {:ok, third} = Issues.update_issue(human, %{status: :in_review, assigned_role: "cto"})
    assert {:ok, _} = AgentActions.execute(third, ctx.reviewer, [action])
    final = Issues.get_issue!(third.id)
    assert final.status == :todo
    assert final.assigned_role == "engineer"
    assert final.last_reviewer_id == ctx.reviewer.id
    assert final.last_human_reviewer_id == ctx.user_id
    add_evidence(%{ctx | issue: final})

    approval = %{
      "type" => "approve_issue",
      "notes" =>
        "[review] Verdict: accepted. What happened: verified the corrected work. Evidence inspected: document and completed process run. Verification: all focused tests passed. Gaps: none. Follow-up issues: none. Next decision: close. Restart packet: inspect the accepted evidence before closing."
    }

    {:ok, ready} = Issues.update_issue(Issues.get_issue!(final.id), %{status: :in_review})
    assert {:ok, _} = AgentActions.execute(ready, ctx.reviewer, [approval])
    closed = Issues.get_issue!(final.id)
    assert closed.status == :done
    assert closed.last_reviewer_id == nil
    assert closed.last_human_reviewer_id == ctx.user_id
  end

  test "approval wake cancellation failure rolls back the entire decision", ctx do
    add_evidence(ctx)

    other =
      Repo.insert!(
        AgentWake.changeset(%AgentWake{}, %{
          agent_id: ctx.reviewer.id,
          issue_id: ctx.issue.id,
          reason: "manual_dispatch",
          triggered_by_type: "system"
        })
      )

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_human_review_cancel() RETURNS trigger AS $$
    BEGIN
      IF NEW.id = '#{other.id}'::uuid AND NEW.status = 'cancelled' THEN
        RAISE EXCEPTION 'synthetic wake cancellation failure';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER reject_human_review_cancel BEFORE UPDATE ON agent_wakes
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_human_review_cancel()
    """)

    before_comments = Comments.list_comments(ctx.issue.id)
    before_activities = Activities.list_activities(ctx.issue.id)

    assert {:error, :persistence_failed} =
             Issues.review_issue(ctx.issue, current_company_id(), ctx.user_id, :approve)

    assert Issues.get_issue!(ctx.issue.id).status == :in_review
    assert Comments.list_comments(ctx.issue.id) == before_comments
    assert Activities.list_activities(ctx.issue.id) == before_activities
    assert Repo.get!(AgentWake, ctx.wake.id).status == "pending"
    assert Repo.get!(AgentWake, other.id).status == "pending"
  end

  test "ordinary issue attributes cannot forge the human reviewer reference", ctx do
    {:ok, updated} = Issues.update_issue(ctx.issue, %{last_human_reviewer_id: ctx.user_id})
    assert updated.last_human_reviewer_id == nil
  end

  test "later agent review remains usable after the human reviewer leaves the company", ctx do
    {:ok, human} =
      Issues.review_issue(ctx.issue, current_company_id(), ctx.user_id, :request_changes,
        reason: "Correct the acceptance gap."
      )

    membership = Companies.get_membership(ctx.user_id, current_company_id())
    Repo.delete!(membership)

    reason =
      "Evidence inspected: review document. Required changes: correct the acceptance gap. Verification required: run the focused test. Next action: resubmit for review."

    assert {:ok, _} =
             AgentActions.execute(human, ctx.reviewer, [
               %{"type" => "request_changes", "role" => "engineer", "reason" => reason}
             ])

    assert Issues.get_issue!(human.id).last_human_reviewer_id == ctx.user_id
  end

  defp add_evidence(ctx) do
    for body <- [
          "[delivery] What happened: completed work. Files changed: document. Evidence produced: document and process run. Verification: process passed. Risks: none. Current state: ready. Next decision: review. Restart packet: inspect document and process result.",
          "[review] Verdict: accepted. What happened: inspected work. Evidence inspected: document and process run. Verification: process passed. Gaps: none. Follow-up issues: none. Next decision: close. Restart packet: inspect accepted evidence."
        ] do
      {:ok, _} =
        Comments.create_comment(%{
          issue_id: ctx.issue.id,
          author_type: "agent",
          author_id: ctx.reviewer.id,
          body: body
        })
    end

    Repo.insert!(%Run{
      agent_id: ctx.reviewer.id,
      company_id: ctx.issue.company_id,
      issue_id: ctx.issue.id,
      status: "completed",
      adapter: "process"
    })

    {:ok, _} =
      WorkProducts.create_work_product(%{
        issue_id: ctx.issue.id,
        created_by_agent_id: ctx.reviewer.id,
        kind: "document",
        title: "Evidence",
        description: "Reviewed document"
      })
  end
end
