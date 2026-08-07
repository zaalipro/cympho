defmodule Cympho.WakesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake
  alias Cympho.{Agents, Companies, Issues, Comments, Projects, Repo}

  setup do
    {:ok, company} =
      Companies.create_company(%{
        name: "Wake Test Co",
        slug: "wake-test-#{System.unique_integer([:positive])}"
      })

    {:ok, project} =
      Projects.create_project(%{
        name: "Wake Test Project",
        prefix: "WAKE",
        company_id: company.id
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Wake Test Agent",
        role: :engineer,
        status: :idle,
        company_id: company.id
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Wake Test Issue",
        project_id: project.id,
        company_id: company.id,
        assignee_id: agent.id,
        status: :in_progress
      })

    %{agent: agent, issue: issue, project: project, company: company}
  end

  describe "list_review_nudges/2" do
    test "can scope review nudges by company" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Wake Scope Co",
          slug: "wake-scope-#{System.unique_integer([:positive])}"
        })

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Wake Scope Co",
          slug: "other-wake-scope-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Scoped Wake Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, other_agent} =
        Agents.create_agent(%{
          name: "Other Wake Agent",
          role: :engineer,
          status: :idle,
          company_id: other_company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Scoped wake issue",
          status: :in_progress,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, other_issue} =
        Issues.create_issue(%{
          title: "Other wake issue",
          status: :in_progress,
          company_id: other_company.id,
          assignee_id: other_agent.id
        })

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, issue.id, "manual_dispatch", "system", "test", %{
          "source" => "review_nudge"
        })

      {:ok, _other_wake} =
        Wakes.do_wake_agent(
          other_agent.id,
          other_issue.id,
          "manual_dispatch",
          "system",
          "test",
          %{"source" => "review_nudge"}
        )

      issue_ids = [issue.id, other_issue.id]

      assert Enum.map(Wakes.list_review_nudges(issue_ids, company_id: company.id), & &1.id) == [
               wake.id
             ]

      assert [] = Wakes.list_review_nudges(issue_ids, company_id: nil)
    end
  end

  describe "stale comment wake cleanup" do
    test "only consumes stale pending comment wakes scoped to the company" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Wake Cleanup Co",
          slug: "wake-cleanup-#{System.unique_integer([:positive])}"
        })

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Wake Cleanup Co",
          slug: "other-wake-cleanup-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Cleanup Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, other_agent} =
        Agents.create_agent(%{
          name: "Other Cleanup Agent",
          role: :engineer,
          status: :idle,
          company_id: other_company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Cleanup wake issue",
          status: :in_progress,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, recent_issue} =
        Issues.create_issue(%{
          title: "Recent wake issue",
          status: :in_progress,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, manual_issue} =
        Issues.create_issue(%{
          title: "Manual wake issue",
          status: :in_progress,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, review_issue} =
        Issues.create_issue(%{
          title: "Review wake issue",
          status: :in_progress,
          company_id: company.id,
          assignee_id: agent.id
        })

      {:ok, other_issue} =
        Issues.create_issue(%{
          title: "Other wake issue",
          status: :in_progress,
          company_id: other_company.id,
          assignee_id: other_agent.id
        })

      {:ok, stale_comment} =
        Wakes.do_wake_agent(agent.id, issue.id, "issue_commented", "user", "test", %{})

      {:ok, recent_comment} =
        Wakes.do_wake_agent(agent.id, recent_issue.id, "issue_commented", "user", "test", %{})

      {:ok, manual_wake} =
        Wakes.do_wake_agent(agent.id, manual_issue.id, "manual_dispatch", "system", "test", %{})

      {:ok, review_wake} =
        Wakes.do_wake_agent(agent.id, review_issue.id, "issue_commented", "user", "test", %{
          "source" => "review_nudge"
        })

      {:ok, other_wake} =
        Wakes.do_wake_agent(
          other_agent.id,
          other_issue.id,
          "issue_commented",
          "user",
          "test",
          %{}
        )

      stale_time =
        DateTime.utc_now()
        |> DateTime.add(-3 * 60 * 60, :second)
        |> DateTime.truncate(:second)

      stale_ids = [stale_comment.id, manual_wake.id, review_wake.id, other_wake.id]

      Repo.update_all(from(w in AgentWake, where: w.id in ^stale_ids),
        set: [inserted_at: stale_time]
      )

      assert Wakes.count_stale_comment_wakes(company.id, older_than_minutes: 120) == 1
      assert [listed] = Wakes.list_stale_comment_wakes(company.id, older_than_minutes: 120)
      assert listed.id == stale_comment.id

      assert {:ok, 1} = Wakes.consume_stale_comment_wakes(company.id, older_than_minutes: 120)

      assert Repo.get!(AgentWake, stale_comment.id).status == "consumed"
      assert Repo.get!(AgentWake, recent_comment.id).status == "pending"
      assert Repo.get!(AgentWake, manual_wake.id).status == "pending"
      assert Repo.get!(AgentWake, review_wake.id).status == "pending"
      assert Repo.get!(AgentWake, other_wake.id).status == "pending"
    end
  end

  describe "notify_comment/1" do
    test "wakes agent when comment is added to an in_progress issue", %{
      agent: agent,
      issue: issue
    } do
      {:ok, comment} =
        Comments.create_comment(%{
          body: "Test comment",
          author_type: "user",
          author_id: "test-user",
          issue_id: issue.id
        })

      result = Wakes.notify_comment(comment)

      assert {:ok, agent_wake} = result
      assert agent_wake.agent_id == agent.id
      assert agent_wake.issue_id == issue.id
      assert agent_wake.reason in ["issue_commented", "issue_comment_mentioned"]
      assert agent_wake.triggered_by_type == "user"
      assert agent_wake.triggered_by_id == "test-user"
      assert agent_wake.metadata["comment_id"] == comment.id
      assert agent_wake.metadata["comment_body"] == "Test comment"
      assert agent_wake.metadata["comment_author_type"] == "user"
      assert agent_wake.metadata["comment_author_id"] == "test-user"
    end

    test "detects direct assignee mention in comment body", %{agent: agent, issue: issue} do
      mention = agent.name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

      {:ok, comment} =
        Comments.create_comment(%{
          body: "@#{mention} please review",
          author_type: "user",
          author_id: "test-user",
          issue_id: issue.id
        })

      result = Wakes.notify_comment(comment)

      assert {:ok, agent_wake} = result
      assert agent_wake.reason == "issue_comment_mentioned"
    end

    test "does not treat unrelated @ text as an assignee mention", %{agent: agent, issue: issue} do
      {:ok, comment} =
        Comments.create_comment(%{
          body: "Forwarded from support@example.com, please check the logs.",
          author_type: "user",
          author_id: "test-user",
          issue_id: issue.id
        })

      result = Wakes.notify_comment(comment)

      assert {:ok, agent_wake} = result
      assert agent_wake.agent_id == agent.id
      assert agent_wake.reason == "issue_commented"
    end

    test "wakes a mentioned agent even when another agent owns the issue" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Mention Wake Co",
          slug: "mention-wake-#{System.unique_integer([:positive])}"
        })

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Mention Wake Co",
          slug: "other-mention-wake-#{System.unique_integer([:positive])}"
        })

      {:ok, owner} =
        Agents.create_agent(%{
          name: "Issue Owner",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, designer} =
        Agents.create_agent(%{
          name: "Design Lead",
          role: :designer,
          status: :idle,
          company_id: company.id
        })

      {:ok, other_designer} =
        Agents.create_agent(%{
          name: "Design Lead",
          role: :designer,
          status: :idle,
          company_id: other_company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Mentioned agent should see the comment",
          status: :in_progress,
          company_id: company.id,
          assignee_id: owner.id
        })

      {:ok, comment} =
        Comments.create_comment(%{
          body: "@design-lead please inspect the empty state before the owner update.",
          author_type: "user",
          author_id: "test-user",
          issue_id: issue.id
        })

      wakes = Wakes.list_issue_wakes(issue.id)

      assert Enum.any?(wakes, fn wake ->
               wake.agent_id == owner.id and wake.reason == "issue_commented"
             end)

      assert Enum.any?(wakes, fn wake ->
               metadata = wake.metadata || %{}

               wake.agent_id == designer.id and wake.reason == "issue_comment_mentioned" and
                 (Map.get(metadata, "comment_id") == comment.id or
                    Map.get(metadata, :comment_id) == comment.id) and
                 (Map.get(metadata, "comment_body") == comment.body or
                    Map.get(metadata, :comment_body) == comment.body) and
                 (Map.get(metadata, "source") == "agent_mention" or
                    Map.get(metadata, :source) == "agent_mention")
             end)

      refute Enum.any?(wakes, &(&1.agent_id == other_designer.id))
    end

    test "does not wake an assigned agent from its own comment", %{agent: agent, issue: issue} do
      {:ok, comment} =
        Comments.create_comment(%{
          body: "Delivery note from the assigned agent",
          author_type: "agent",
          author_id: agent.id,
          issue_id: issue.id
        })

      assert {:error, :self_comment_ignored} = Wakes.notify_comment(comment)
      assert [] = Wakes.list_issue_wakes(issue.id)
    end

    test "returns error when issue is not active", %{issue: issue} do
      {:ok, _} = Issues.update_issue(issue, %{status: :backlog})
      issue = Issues.get_issue!(issue.id)

      {:ok, comment} =
        Comments.create_comment(%{
          body: "Test comment",
          author_type: "user",
          author_id: "test-user",
          issue_id: issue.id
        })

      assert {:error, :issue_not_active} = Wakes.notify_comment(comment)
    end

    test "returns error when issue has no assignee", %{project: project} do
      {:ok, unassigned_issue} =
        Issues.create_issue(%{
          title: "Unassigned Issue",
          project_id: project.id,
          status: :in_progress
        })

      {:ok, comment} =
        Comments.create_comment(%{
          body: "Test comment",
          author_type: "user",
          author_id: "test-user",
          issue_id: unassigned_issue.id
        })

      assert {:error, :no_assignee} = Wakes.notify_comment(comment)
    end

    test "does not auto-wake assignee for blocked issue comments", %{issue: issue} do
      {:ok, _} = Issues.update_issue(issue, %{status: :blocked})
      issue = Issues.get_issue!(issue.id)

      {:ok, comment} =
        Comments.create_comment(%{
          body: "Test comment on blocked issue",
          author_type: "user",
          author_id: "test-user",
          issue_id: issue.id
        })

      assert {:error, :issue_not_active} = Wakes.notify_comment(comment)
      assert [] = Wakes.list_issue_wakes(issue.id)
    end

    test "does not wake mentioned non-assignees on blocked or terminal issue comments" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Quiet Comment Wake Co",
          slug: "quiet-comment-wake-#{System.unique_integer([:positive])}"
        })

      {:ok, owner} =
        Agents.create_agent(%{
          name: "Quiet Owner",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, designer} =
        Agents.create_agent(%{
          name: "Quiet Designer",
          role: :designer,
          status: :idle,
          company_id: company.id
        })

      for status <- [:blocked, :done, :cancelled] do
        {:ok, quiet_issue} =
          Issues.create_issue(%{
            title: "Quiet #{status} comment wake",
            status: status,
            company_id: company.id,
            assignee_id: owner.id
          })

        {:ok, comment} =
          Comments.create_comment(%{
            body: "@quiet-designer context only; do not resume this #{status} issue.",
            author_type: "user",
            author_id: "test-user",
            issue_id: quiet_issue.id
          })

        assert {:error, :issue_not_active} = Wakes.notify_comment(comment)
        refute Enum.any?(Wakes.list_issue_wakes(quiet_issue.id), &(&1.agent_id == designer.id))
      end
    end

    test "wakes agent for in_review issue", %{agent: agent, issue: issue} do
      {:ok, _} = Issues.update_issue(issue, %{status: :in_review})
      issue = Issues.get_issue!(issue.id)

      {:ok, comment} =
        Comments.create_comment(%{
          body: "Test comment on in_review issue",
          author_type: "user",
          author_id: "test-user",
          issue_id: issue.id
        })

      result = Wakes.notify_comment(comment)

      assert {:ok, agent_wake} = result
      assert agent_wake.agent_id == agent.id
    end
  end

  describe "notify_children_completed/1" do
    test "wakes parent assignee when all children are done", %{
      agent: agent,
      project: project,
      company: company
    } do
      {:ok, parent} =
        Issues.create_issue(%{
          title: "Parent Issue",
          project_id: project.id,
          company_id: company.id,
          assignee_id: agent.id,
          status: :in_progress
        })

      {:ok, _child1} =
        Issues.create_issue(%{
          title: "Child 1",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :done
        })

      {:ok, child2} =
        Issues.create_issue(%{
          title: "Child 2",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :done
        })

      result = Wakes.notify_children_completed(child2)

      assert {:ok, agent_wake} = result
      assert agent_wake.agent_id == agent.id
      assert agent_wake.issue_id == parent.id
      assert agent_wake.reason == "issue_children_completed"
    end

    test "returns error when child has no parent", %{project: project, company: company} do
      {:ok, orphan} =
        Issues.create_issue(%{
          title: "Orphan Issue",
          project_id: project.id,
          company_id: company.id,
          status: :done
        })

      assert {:error, :no_parent} = Wakes.notify_children_completed(orphan)
    end

    test "returns error when parent has no assignee", %{project: project, company: company} do
      {:ok, parent} =
        Issues.create_issue(%{
          title: "Unassigned Parent",
          project_id: project.id,
          company_id: company.id,
          status: :in_progress
        })

      {:ok, child} =
        Issues.create_issue(%{
          title: "Child",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :done
        })

      assert {:error, :no_assignee} = Wakes.notify_children_completed(child)
    end

    test "wakes parent when single child completes", %{
      agent: agent,
      project: project,
      company: company
    } do
      {:ok, parent} =
        Issues.create_issue(%{
          title: "Parent Issue",
          project_id: project.id,
          company_id: company.id,
          assignee_id: agent.id,
          status: :in_progress
        })

      {:ok, child} =
        Issues.create_issue(%{
          title: "Only Child",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :done
        })

      result = Wakes.notify_children_completed(child)

      assert {:ok, agent_wake} = result
      assert agent_wake.agent_id == agent.id
      assert agent_wake.issue_id == parent.id
      assert agent_wake.reason == "issue_children_completed"
    end

    test "returns error when not all children are done", %{
      agent: agent,
      project: project,
      company: company
    } do
      {:ok, parent} =
        Issues.create_issue(%{
          title: "Parent Issue",
          project_id: project.id,
          company_id: company.id,
          assignee_id: agent.id,
          status: :in_progress
        })

      {:ok, _} =
        Issues.create_issue(%{
          title: "Child 1",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :todo
        })

      {:ok, child2} =
        Issues.create_issue(%{
          title: "Child 2",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :done
        })

      assert {:error, :children_not_all_done} = Wakes.notify_children_completed(child2)
    end
    test "wakes parent when children are mix of done and cancelled", %{
      agent: agent,
      project: project,
      company: company
    } do
      {:ok, parent} =
        Issues.create_issue(%{
          title: "Parent Issue",
          project_id: project.id,
          company_id: company.id,
          assignee_id: agent.id,
          status: :in_progress
        })

      {:ok, _child1} =
        Issues.create_issue(%{
          title: "Child 1 cancelled",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :cancelled
        })

      {:ok, child2} =
        Issues.create_issue(%{
          title: "Child 2 done",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :done
        })

      result = Wakes.notify_children_completed(child2)

      assert {:ok, agent_wake} = result
      assert agent_wake.reason == "issue_children_completed"
    end

    test "reopens soft-blocked parent when all children terminal", %{
      agent: agent,
      project: project,
      company: company
    } do
      {:ok, parent} =
        Issues.create_issue(%{
          title: "Soft blocked parent",
          project_id: project.id,
          company_id: company.id,
          assignee_id: nil,
          assigned_role: "engineer",
          status: :blocked,
          monitor_state: %{
            "decomposition_parked" => true,
            "decomposition_owner_id" => agent.id
          }
        })

      {:ok, child} =
        Issues.create_issue(%{
          title: "Only child",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :done
        })

      assert {:ok, _wake} = Wakes.notify_children_completed(child)

      reloaded = Issues.get_issue!(parent.id)
      assert reloaded.status == :todo
      assert reloaded.assignee_id == agent.id
      refute Map.has_key?(reloaded.monitor_state || %{}, "decomposition_parked")
    end

    test "does not reopen soft-blocked parent while a sibling is still open", %{
      agent: agent,
      project: project,
      company: company
    } do
      {:ok, parent} =
        Issues.create_issue(%{
          title: "Still open children",
          project_id: project.id,
          company_id: company.id,
          assignee_id: nil,
          assigned_role: "engineer",
          status: :blocked,
          monitor_state: %{
            "decomposition_parked" => true,
            "decomposition_owner_id" => agent.id
          }
        })

      {:ok, _} =
        Issues.create_issue(%{
          title: "Open child",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :todo
        })

      {:ok, child2} =
        Issues.create_issue(%{
          title: "Done child",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :done
        })

      assert {:error, :children_not_all_done} = Wakes.notify_children_completed(child2)
      reloaded = Issues.get_issue!(parent.id)
      assert reloaded.status == :blocked
    end

  end

  describe "notify_blockers_resolved/1" do
    test "wakes dependent assignee when blocker is resolved", %{
      agent: agent,
      project: project,
      company: company
    } do
      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Blocker Issue",
          project_id: project.id,
          company_id: company.id,
          status: :done
        })

      {:ok, blocked} =
        Issues.create_issue(%{
          title: "Blocked Issue",
          project_id: project.id,
          company_id: company.id,
          assignee_id: agent.id,
          status: :blocked
        })

      {:ok, _} = Issues.add_blocker(blocked, blocker)

      results = Wakes.notify_blockers_resolved(blocker)

      assert length(results) == 1
      {:ok, agent_wake} = List.first(results)
      assert agent_wake.agent_id == agent.id
      assert agent_wake.issue_id == blocked.id
      assert agent_wake.reason == "issue_blockers_resolved"
    end

    test "treats cancelled blockers as resolved", %{
      agent: agent,
      project: project,
      company: company
    } do
      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Cancelled Blocker Issue",
          project_id: project.id,
          company_id: company.id,
          status: :cancelled
        })

      {:ok, blocked} =
        Issues.create_issue(%{
          title: "Blocked Issue",
          project_id: project.id,
          company_id: company.id,
          assignee_id: agent.id,
          status: :blocked
        })

      {:ok, _} = Issues.add_blocker(blocked, blocker)

      assert [{:ok, agent_wake}] = Wakes.notify_blockers_resolved(blocker)
      assert agent_wake.agent_id == agent.id
      assert agent_wake.issue_id == blocked.id
      assert agent_wake.reason == "issue_blockers_resolved"
    end

    test "wakes after dependents are already :todo (post unblock_dependents)", %{
      agent: agent,
      project: project,
      company: company
    } do
      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Post-todo Blocker",
          project_id: project.id,
          company_id: company.id,
          status: :done
        })

      {:ok, dependent} =
        Issues.create_issue(%{
          title: "Post-todo Dependent",
          project_id: project.id,
          company_id: company.id,
          assignee_id: agent.id,
          status: :todo
        })

      {:ok, _} = Issues.add_blocker(dependent, blocker)

      assert [{:ok, agent_wake}] = Wakes.notify_blockers_resolved(blocker)
      assert agent_wake.agent_id == agent.id
      assert agent_wake.issue_id == dependent.id
      assert agent_wake.reason == "issue_blockers_resolved"
    end

    test "unassigned dependent queues for dispatcher poll_now", %{
      project: project,
      company: company
    } do
      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Unassigned Blocker",
          project_id: project.id,
          company_id: company.id,
          status: :done
        })

      {:ok, dependent} =
        Issues.create_issue(%{
          title: "Unassigned Dependent",
          project_id: project.id,
          company_id: company.id,
          status: :todo
        })

      {:ok, _} = Issues.add_blocker(dependent, blocker)

      assert [{:ok, :queued_for_dispatch}] = Wakes.notify_blockers_resolved(blocker)
    end

    test "returns empty list when blocker has no dependents", %{
      project: project,
      company: company
    } do
      {:ok, blocker} =
        Issues.create_issue(%{
          title: "Lone Blocker",
          project_id: project.id,
          company_id: company.id,
          status: :done
        })

      results = Wakes.notify_blockers_resolved(blocker)

      assert results == []
    end
  end

  describe "do_wake_agent/6" do
    test "logs wake attempt in agent_wakes table", %{agent: agent, issue: issue} do
      {:ok, agent_wake} =
        Wakes.do_wake_agent(
          agent.id,
          issue.id,
          "issue_commented",
          "user",
          "test-user",
          %{comment_id: "test-comment-id"}
        )

      assert agent_wake.agent_id == agent.id
      assert agent_wake.issue_id == issue.id
      assert agent_wake.reason == "issue_commented"
      assert agent_wake.triggered_by_type == "user"
      assert agent_wake.triggered_by_id == "test-user"
      assert agent_wake.metadata.comment_id == "test-comment-id"
    end

    test "final_review_required notifies OwnerAttention for the issue company", %{
      agent: agent,
      issue: issue,
      company: company
    } do
      :ok = Cympho.OwnerAttention.subscribe(company.id)

      assert {:ok, wake} =
               Wakes.do_wake_agent(
                 agent.id,
                 issue.id,
                 "final_review_required",
                 "system",
                 "test",
                 %{}
               )

      assert_receive {:owner_attention_changed, company_id}
      assert company_id == company.id
      assert wake.reason == "final_review_required"

      assert {:ok, _consumed} = Wakes.consume_wake(wake)
      assert_receive {:owner_attention_changed, ^company_id}
    end

    test "non-review wakes do not notify OwnerAttention", %{
      agent: agent,
      issue: issue,
      company: company
    } do
      :ok = Cympho.OwnerAttention.subscribe(company.id)

      assert {:ok, _wake} =
               Wakes.do_wake_agent(
                 agent.id,
                 issue.id,
                 "issue_commented",
                 "user",
                 "test",
                 %{}
               )

      refute_receive {:owner_attention_changed, _}, 50
    end

    test "works without issue_id", %{agent: agent} do
      {:ok, agent_wake} =
        Wakes.do_wake_agent(
          agent.id,
          nil,
          "issue_commented",
          "system",
          nil,
          %{}
        )

      assert agent_wake.agent_id == agent.id
      assert agent_wake.issue_id == nil
    end

    test "does not enqueue issue wakes while the company runtime is paused" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Wake Pause Co",
          slug: "wake-pause-#{System.unique_integer([:positive])}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Paused Company Agent",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Paused company wake",
          company_id: company.id,
          assignee_id: agent.id,
          status: :in_progress
        })

      {:ok, _paused} =
        Companies.execute_company_update(company, %{
          status: "paused",
          paused_at: DateTime.utc_now() |> DateTime.truncate(:second),
          paused_reason: "Operator hold"
        })

      assert {:error, :company_paused} =
               Wakes.do_wake_agent(
                 agent.id,
                 issue.id,
                 "issue_commented",
                 "system",
                 nil,
                 %{}
               )

      assert [] = Wakes.list_issue_wakes(issue.id)
    end

    test "does not enqueue wakes while the individual issue runtime is paused", %{
      agent: agent,
      issue: issue
    } do
      {:ok, paused} = Issues.pause_issue_runtime(issue, reason: "Operator hold")

      assert {:error, :issue_runtime_paused} =
               Wakes.do_wake_agent(
                 agent.id,
                 paused.id,
                 "issue_commented",
                 "system",
                 nil,
                 %{}
               )

      assert [] = Wakes.list_issue_wakes(paused.id)
    end

    test "rejects an issue wake when the agent belongs to another company" do
      unique = System.unique_integer([:positive])

      {:ok, company} =
        Companies.create_company(%{
          name: "Wake Tenant Company #{unique}",
          slug: "wake-tenant-#{unique}"
        })

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Wake Tenant Company #{unique}",
          slug: "other-wake-tenant-#{unique}"
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Wake Tenant Agent #{unique}",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Foreign wake issue #{unique}",
          status: :in_progress,
          company_id: other_company.id
        })

      assert {:error, :company_mismatch} =
               Wakes.do_wake_agent(
                 agent.id,
                 issue.id,
                 "issue_commented",
                 "system",
                 nil,
                 %{}
               )

      assert [] = Wakes.list_issue_wakes(issue.id)
    end
  end

  describe "list_agent_wakes/1" do
    test "returns wakes for a specific agent", %{agent: agent, issue: issue} do
      {:ok, w1} = Wakes.do_wake_agent(agent.id, issue.id, "issue_commented", "user", "1", %{})

      # Backdate w1 so second-precision inserted_at ordering is deterministic
      # without sleeping across a second boundary.
      earlier = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-60)
      {:ok, _} = Repo.update(Ecto.Changeset.change(w1, inserted_at: earlier))

      {:ok, _} =
        Wakes.do_wake_agent(agent.id, issue.id, "issue_blockers_resolved", "system", nil, %{})

      wakes = Wakes.list_agent_wakes(agent.id)

      assert length(wakes) == 2
      [first, second] = wakes
      assert first.reason == "issue_blockers_resolved"
      assert second.reason == "issue_commented"
    end
  end

  describe "list_issue_wakes/1" do
    test "returns wakes for a specific issue", %{agent: agent, issue: issue} do
      {:ok, _} = Wakes.do_wake_agent(agent.id, issue.id, "issue_commented", "user", "1", %{})

      {:ok, _} =
        Wakes.do_wake_agent(agent.id, issue.id, "issue_children_completed", "system", nil, %{})

      wakes = Wakes.list_issue_wakes(issue.id)

      assert length(wakes) == 2
    end
  end

  describe "get_agent_wake!/1" do
    test "returns a specific agent wake", %{agent: agent, issue: issue} do
      {:ok, agent_wake} =
        Wakes.do_wake_agent(agent.id, issue.id, "issue_commented", "user", "1", %{})

      fetched = Wakes.get_agent_wake!(agent_wake.id)

      assert fetched.id == agent_wake.id
      assert fetched.reason == "issue_commented"
    end
  end
end
