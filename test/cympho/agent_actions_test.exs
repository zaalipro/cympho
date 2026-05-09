defmodule Cympho.AgentActionsTest do
  use Cympho.DataCase, async: false

  alias Cympho.{AgentActions, Agents, Comments, Companies, Issues, Repo, WorkProducts}
  alias Cympho.HeartbeatEngine.Run

  describe "parse/1" do
    test "parses a valid cympho-actions block" do
      body = """
      Delegated.

      ```cympho-actions
      {"actions":[{"type":"comment","body":"Done"}]}
      ```
      """

      assert {:ok, [%{"type" => "comment", "body" => "Done"}]} = AgentActions.parse(body)
    end

    test "rejects missing action block" do
      assert {:error, :missing_action_block} = AgentActions.parse("Done")
    end

    test "rejects unsupported actions" do
      body = """
      ```cympho-actions
      {"actions":[{"type":"ship_money"}]}
      ```
      """

      assert {:error, {:unsupported_action, "ship_money"}} = AgentActions.parse(body)
    end
  end

  describe "execute/3" do
    setup do
      {:ok,
       %{
         company: company,
         project: project,
         goal: goal,
         agents: [ceo, cto, engineer | _],
         seed_issues: seed_issues
       }} =
        Companies.create_autonomous_company(%{
          name: "Action Test Company #{System.unique_integer([:positive])}",
          issue_prefix: "ACT",
          engineer_count: 1
        })

      issue = List.first(seed_issues)
      {:ok, issue} = Issues.checkout_issue(issue, ceo, :ceo)

      %{
        company: company,
        project: project,
        goal: goal,
        ceo: ceo,
        cto: cto,
        engineer: engineer,
        issue: issue
      }
    end

    test "create_issue inherits company context and audit fields", %{
      issue: issue,
      cto: cto,
      company: company,
      project: project,
      goal: goal
    } do
      actions = [
        %{
          "type" => "create_issue",
          "title" => "Build action executor",
          "description" => "Implement executor tests.",
          "role" => "engineer",
          "priority" => "high"
        }
      ]

      assert {:ok, %{results: [%{type: "create_issue", issue_id: created_id}]}} =
               AgentActions.execute(issue, cto, actions)

      created = Issues.get_issue!(created_id)
      assert created.company_id == company.id
      assert created.project_id == project.id
      assert created.goal_id == goal.id
      assert created.parent_id == issue.id
      assert created.created_by_agent_id == cto.id
      assert created.origin_type == "agent_action"
      assert created.origin_id == issue.id
      assert created.request_depth == issue.request_depth + 1
      assert created.assigned_role == "engineer"
      assert created.priority == :high
      assert created.status == :todo
    end

    test "create_issue is rejected when request_depth would exceed the cap", %{
      cto: cto,
      project: project,
      company: company
    } do
      # Build an issue already at the depth cap (5 by default).
      max_depth =
        Application.get_env(:cympho, :agent_actions, []) |> Keyword.get(:max_request_depth, 5)

      {:ok, deep_issue} =
        Issues.create_issue(%{
          title: "Deep Issue",
          description: "at the depth cap",
          status: :in_progress,
          priority: :medium,
          company_id: company.id,
          project_id: project.id,
          assignee_id: cto.id,
          request_depth: max_depth
        })

      actions = [
        %{
          "type" => "create_issue",
          "title" => "Should be rejected",
          "description" => "depth would overflow",
          "role" => "engineer"
        }
      ]

      assert {:error, {:request_depth_exceeded, ^max_depth, ^max_depth}} =
               AgentActions.execute(deep_issue, cto, actions)

      # The rejection comment is emitted on the originating issue so the
      # LLM sees it on its next turn.
      comments = Comments.list_comments(deep_issue.id)

      assert Enum.any?(comments, fn c ->
               c.author_type == "system" and
                 String.contains?(c.body, "create_issue rejected") and
                 String.contains?(c.body, "request depth")
             end)
    end

    test "create_issue is rejected when parent has too many active children", %{
      issue: issue,
      cto: cto
    } do
      max_children = AgentActions.limits().max_active_child_issues_per_parent

      for index <- 1..max_children do
        {:ok, _child} =
          Issues.create_issue(%{
            title: "Active child #{index}",
            description: "Existing open child",
            status: :todo,
            priority: :medium,
            company_id: issue.company_id,
            project_id: issue.project_id,
            goal_id: issue.goal_id,
            parent_id: issue.id
          })
      end

      actions = [
        %{
          "type" => "create_issue",
          "title" => "One child too many",
          "description" => "Should not be created",
          "role" => "engineer"
        }
      ]

      assert {:error, {:child_issue_limit_exceeded, ^max_children, ^max_children}} =
               AgentActions.execute(issue, cto, actions)

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn c ->
               c.author_type == "system" and
                 String.contains?(c.body, "create_issue rejected") and
                 String.contains?(c.body, "active sub-issue")
             end)

      refute Enum.any?(Issues.list_child_issues(issue.id), &(&1.title == "One child too many"))
    end

    test "create_issue child limit ignores malformed children from another company", %{
      issue: issue,
      cto: cto
    } do
      max_children = AgentActions.limits().max_active_child_issues_per_parent

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Child Limit Co",
          slug: "other-child-limit-#{System.unique_integer([:positive])}"
        })

      for index <- 1..max_children do
        {:ok, _child} =
          Issues.create_issue(%{
            title: "Other-company active child #{index}",
            description: "Should not count against this company",
            status: :todo,
            priority: :medium,
            company_id: other_company.id,
            parent_id: issue.id
          })
      end

      actions = [
        %{
          "type" => "create_issue",
          "title" => "Local child still allowed",
          "description" => "Company scoped child count should ignore malformed foreign rows.",
          "role" => "engineer"
        }
      ]

      assert {:ok, %{results: [%{type: "create_issue", issue_id: created_id}]}} =
               AgentActions.execute(issue, cto, actions)

      created = Issues.get_issue!(created_id)
      assert created.company_id == issue.company_id
      assert created.parent_id == issue.id
    end

    test "execute is rejected when the agent exceeds per-minute action quota", %{
      issue: issue,
      cto: cto
    } do
      original = Application.get_env(:cympho, :agent_actions, [])
      Application.put_env(:cympho, :agent_actions, max_per_minute: 2)
      Cympho.RateLimiting.AgentActionLimiter.reset()

      on_exit(fn ->
        Application.put_env(:cympho, :agent_actions, original)
        Cympho.RateLimiting.AgentActionLimiter.reset()
      end)

      actions = [%{"type" => "comment", "body" => "still here"}]

      assert {:ok, _} = AgentActions.execute(issue, cto, actions)
      assert {:ok, _} = AgentActions.execute(issue, cto, actions)
      assert {:error, :rate_limited} = AgentActions.execute(issue, cto, actions)

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn c ->
               c.author_type == "system" and
                 String.contains?(c.body, "exceeded the per-minute action limit")
             end)
    end

    test "submit_review from a CEO with no parent is rejected (would ping-pong)", %{
      issue: issue,
      ceo: ceo
    } do
      actions = [%{"type" => "submit_review", "role" => "cto", "notes" => "Ready"}]

      assert {:error, :no_supervisor_to_review} = AgentActions.execute(issue, ceo, actions)

      # Issue is unchanged — still :in_progress, still owned by the CEO
      unchanged = Issues.get_issue!(issue.id)
      assert unchanged.status == :in_progress
      assert unchanged.assignee_id == ceo.id

      # A system comment surfaces the rejection so the LLM self-corrects
      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn c ->
               c.author_type == "system" and
                 String.contains?(c.body, "submit_review rejected") and
                 String.contains?(c.body, "approve_issue")
             end)
    end

    test "submit_review is rejected until delivery evidence exists", %{
      issue: issue,
      engineer: engineer
    } do
      {:ok, issue} = Issues.update_issue(issue, %{assignee_id: engineer.id, status: :in_progress})

      assert {:error, {:quality_gate_failed, "submit_review", gaps}} =
               AgentActions.execute(issue, engineer, [
                 %{"type" => "submit_review", "role" => "cto"}
               ])

      assert :agent_note in gaps
      assert :work_product in gaps

      unchanged = Issues.get_issue!(issue.id)
      assert unchanged.status == :in_progress
      assert unchanged.assignee_id == engineer.id

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn c ->
               c.author_type == "system" and
                 String.contains?(c.body, "submit_review rejected") and
                 String.contains?(c.body, "agent completion note") and
                 String.contains?(c.body, "work product")
             end)
    end

    test "submit_review routes the issue to the agent's reports_to (parent) when set", %{
      issue: issue,
      ceo: ceo,
      cto: cto,
      engineer: engineer
    } do
      {:ok, issue} = Issues.update_issue(issue, %{assignee_id: engineer.id, status: :in_progress})
      insert_completed_run(engineer, issue)

      actions = [
        %{
          "type" => "attach_work_product",
          "kind" => "document",
          "title" => "Delivery notes"
        },
        %{
          "type" => "submit_review",
          "role" => "cto",
          "notes" =>
            "[delivery] What happened: implementation is ready for CTO review. Files changed: implementation notes. Verification: completed run passed. Risks: none known. Current state: ready for review. Next decision: CTO review."
        }
      ]

      assert {:ok, _} = AgentActions.execute(issue, engineer, actions)

      updated = Issues.get_issue!(issue.id)
      comments = Comments.list_comments(issue.id)

      assert updated.status == :in_review
      assert updated.assignee_id == cto.id, "engineer.parent_id (cto) should own the review"
      assert updated.assigned_role == "cto"

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "agent" and
                 String.starts_with?(comment.body, "[delivery]") and
                 String.contains?(String.downcase(comment.body), "cto review")
             end)

      _ = ceo
    end

    test "submit_review falls back to dispatcher routing when parent role doesn't match",
         %{issue: issue, engineer: engineer, company: company} do
      # Re-parent the engineer to another engineer (a peer, not a CTO). The
      # submit_review then asks for "cto" but the parent isn't one — we
      # should drop the direct assignment and let the dispatcher route by
      # `assigned_role` instead.
      {:ok, peer_engineer} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "Peer Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, engineer} = Agents.update_agent(engineer, %{parent_id: peer_engineer.id})
      {:ok, issue} = Issues.update_issue(issue, %{assignee_id: engineer.id, status: :in_progress})
      insert_completed_run(engineer, issue)

      actions = [
        %{
          "type" => "attach_work_product",
          "kind" => "document",
          "title" => "Fallback routing evidence"
        },
        %{
          "type" => "submit_review",
          "role" => "cto",
          "notes" =>
            "[delivery] What happened: evidence is ready for CTO review. Files changed: fallback routing evidence. Verification: completed run passed. Risks: none known. Current state: ready for review. Next decision: CTO review."
        }
      ]

      assert {:ok, _} = AgentActions.execute(issue, engineer, actions)

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :in_review
      assert updated.assignee_id == nil, "mismatched parent should fall back to dispatcher"
      assert updated.assigned_role == "cto"
    end

    test "approve_issue marks issue done, clears checkout, and comments", %{
      issue: issue,
      ceo: ceo
    } do
      insert_completed_run(ceo, issue)
      insert_work_product(issue, ceo)

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered the owner-approved work. Files changed: delivery artifact. Verification: completed run passed. Risks: none known. Current state: ready for approval. Next decision: CEO owner update.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      actions = [
        %{
          "type" => "approve_issue",
          "notes" =>
            "[owner_update] What happened: approved this issue. Business status: shipped. Current state: closed. Next decision: none. Owner decision needed: none."
        }
      ]

      assert {:ok, _} = AgentActions.execute(issue, ceo, actions)

      updated = Issues.get_issue!(issue.id)
      comments = Comments.list_comments(issue.id)

      assert updated.status == :done
      assert updated.assignee_id == nil
      assert updated.assigned_role == nil
      assert updated.checked_out_at == nil

      assert Enum.any?(
               comments,
               &(&1.author_type == "agent" and
                   String.starts_with?(&1.body, "[owner_update]") and
                   String.contains?(&1.body, "approved this issue"))
             )
    end

    test "approve_issue is rejected for code work without a reviewable reference", %{
      issue: issue,
      ceo: ceo,
      engineer: engineer
    } do
      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: engineer.id,
          kind: "code_change",
          title: "Implementation patch"
        })

      assert {:error, {:quality_gate_failed, "approve_issue", [:code_reference]}} =
               AgentActions.execute(issue, ceo, [%{"type" => "approve_issue"}])

      unchanged = Issues.get_issue!(issue.id)
      refute unchanged.status == :done

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn c ->
               c.author_type == "system" and
                 String.contains?(c.body, "approve_issue rejected") and
                 String.contains?(c.body, "code reference")
             end)
    end

    test "request_changes reopens issue for target role", %{issue: issue, cto: cto} do
      actions = [%{"type" => "request_changes", "role" => "engineer", "reason" => "Needs tests"}]

      assert {:ok, _} = AgentActions.execute(issue, cto, actions)

      updated = Issues.get_issue!(issue.id)
      comments = Comments.list_comments(issue.id)

      assert updated.status == :todo
      assert updated.assignee_id == nil
      assert updated.assigned_role == "engineer"

      assert Enum.any?(
               comments,
               &(&1.author_type == "agent" and &1.body == "[review] Needs tests")
             )
    end

    test "block_issue blocks and comments with reason", %{issue: issue, ceo: ceo} do
      actions = [%{"type" => "block_issue", "reason" => "Missing API key"}]

      assert {:ok, _} = AgentActions.execute(issue, ceo, actions)

      updated = Issues.get_issue!(issue.id)
      comments = Comments.list_comments(issue.id)

      assert updated.status == :blocked
      assert updated.assignee_id == nil

      assert Enum.any?(
               comments,
               &(&1.author_type == "agent" and &1.body == "[blocked] Missing API key")
             )
    end

    test "attach_work_product records agent output", %{issue: issue, engineer: engineer} do
      actions = [
        %{
          "type" => "attach_work_product",
          "kind" => "document",
          "title" => "Implementation notes",
          "description" => "Summary of the completed work.",
          "payload" => %{"files" => ["README.md"]},
          "metadata" => %{"source" => "agent"}
        }
      ]

      assert {:ok, %{results: [%{type: "attach_work_product", work_product_id: id}]}} =
               AgentActions.execute(issue, engineer, actions)

      [work_product] = WorkProducts.list_work_products(issue.id)
      assert work_product.id == id
      assert work_product.created_by_agent_id == engineer.id
      assert work_product.title == "Implementation notes"
      assert work_product.kind == "document"
      assert work_product.payload["files"] == ["README.md"]
    end

    test "set_pr_url updates the issue PR URL and records a review note", %{
      issue: issue,
      engineer: engineer
    } do
      url = "https://github.com/example/repo/pull/42"
      actions = [%{"type" => "set_pr_url", "url" => url}]

      assert {:ok, _} = AgentActions.execute(issue, engineer, actions)

      updated = Issues.get_issue!(issue.id)
      comments = Comments.list_comments(issue.id)

      assert updated.github_pr_url == url
      assert updated.monitor_state["pr_quality"]["status"] == "unchecked"
      assert updated.monitor_state["pr_quality"]["expected_branch"] =~ updated.identifier
      assert Enum.any?(comments, &(&1.author_type == "agent" and String.contains?(&1.body, url)))
    end

    test "handoff releases issue to a target role", %{issue: issue, ceo: ceo} do
      actions = [%{"type" => "handoff", "role" => "cto", "reason" => "Needs technical plan"}]

      assert {:ok, %{results: [%{type: "handoff", role: "cto"}]}} =
               AgentActions.execute(issue, ceo, actions)

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :todo
      assert updated.assignee_id == nil
      assert updated.assigned_role == "cto"
    end

    test "handoff generates structured context comment", %{issue: issue, ceo: ceo} do
      actions = [
        %{
          "type" => "handoff",
          "role" => "cto",
          "reason" => "Architecture review needed",
          "summary" => "Implemented dedup check",
          "remaining" => "Write integration tests",
          "decisions" => "Used 24h window",
          "file_paths" => ["lib/cympho/agent_actions.ex", "test/cympho/agent_actions_test.exs"]
        }
      ]

      assert {:ok, _} = AgentActions.execute(issue, ceo, actions)

      comments = Comments.list_comments(issue.id)

      context_comment =
        Enum.find(comments, fn c ->
          c.author_type == "system" && String.contains?(c.body, "Handoff Context")
        end)

      assert context_comment != nil
      assert String.contains?(context_comment.body, "Architecture review needed")
      assert String.contains?(context_comment.body, "Implemented dedup check")
      assert String.contains?(context_comment.body, "Write integration tests")
      assert String.contains?(context_comment.body, "Used 24h window")
      assert String.contains?(context_comment.body, "lib/cympho/agent_actions.ex")
    end

    test "create_issue deduplicates within 24h by title and goal", %{
      issue: issue,
      cto: cto
    } do
      actions = [
        %{
          "type" => "create_issue",
          "title" => "Dedup target issue",
          "role" => "engineer",
          "priority" => "medium"
        }
      ]

      assert {:ok, %{results: [%{type: "create_issue", issue_id: first_id}]}} =
               AgentActions.execute(issue, cto, actions)

      assert {:ok, %{results: [%{type: "create_issue", issue_id: ^first_id, duplicate: true}]}} =
               AgentActions.execute(issue, cto, actions)

      comments = Comments.list_comments(first_id)

      assert Enum.any?(comments, fn c ->
               c.author_type == "system" && String.contains?(c.body, "Duplicate creation attempt")
             end)
    end

    test "create_issue allows different titles", %{issue: issue, cto: cto} do
      actions_a = [
        %{"type" => "create_issue", "title" => "Task A", "role" => "engineer"}
      ]

      actions_b = [
        %{"type" => "create_issue", "title" => "Task B", "role" => "engineer"}
      ]

      assert {:ok, %{results: [%{issue_id: id_a}]}} = AgentActions.execute(issue, cto, actions_a)
      assert {:ok, %{results: [%{issue_id: id_b}]}} = AgentActions.execute(issue, cto, actions_b)
      assert id_a != id_b

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "agent" and
                 String.contains?(comment.body, "Created sub-issue") and
                 String.contains?(comment.body, "Task A")
             end)
    end

    test "approve_issue is rejected when sub-issues are still open", %{
      issue: issue,
      ceo: ceo,
      cto: cto
    } do
      # CTO creates a sub-issue under the CEO's parent issue. The child stays
      # in :todo (unfinished). The CEO then tries to approve the parent.
      child_action = [
        %{"type" => "create_issue", "title" => "Open child task", "role" => "engineer"}
      ]

      assert {:ok, %{results: [%{issue_id: child_id}]}} =
               AgentActions.execute(issue, cto, child_action)

      child = Issues.get_issue!(child_id)
      assert child.status == :todo
      refute child.status in [:done, :cancelled]

      assert {:error, {:children_not_done, [^child_id]}} =
               AgentActions.execute(issue, ceo, [%{"type" => "approve_issue"}])

      # Parent did NOT transition to :done
      unchanged = Issues.get_issue!(issue.id)
      refute unchanged.status == :done

      # System comment surfaces the rejection with the child identifier
      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn c ->
               c.author_type == "system" and
                 String.contains?(c.body, "approve_issue rejected") and
                 String.contains?(c.body, child.identifier)
             end)
    end

    test "approve_issue ignores malformed open children from another company", %{
      issue: issue,
      ceo: ceo
    } do
      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Approval Co",
          slug: "other-approval-#{System.unique_integer([:positive])}"
        })

      {:ok, _foreign_child} =
        Issues.create_issue(%{
          title: "Foreign open child",
          description: "Should not block approval in the parent company.",
          status: :todo,
          priority: :medium,
          company_id: other_company.id,
          parent_id: issue.id
        })

      insert_completed_run(ceo, issue)
      insert_work_product(issue, ceo)

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: scoped evidence is complete. Files changed: approval evidence. Verification: passed. Risks: none known. Current state: ready for close. Next decision: CEO owner update.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      assert {:ok, _} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "approve_issue",
                   "notes" =>
                     "[owner_update] What happened: scoped evidence is complete. Business status: ready. Current state: closed. Next decision: none. Owner decision needed: none."
                 }
               ])

      assert Issues.get_issue!(issue.id).status == :done
    end

    test "approve_issue succeeds once all sub-issues are :done", %{
      issue: issue,
      ceo: ceo,
      cto: cto
    } do
      insert_completed_run(ceo, issue)
      insert_work_product(issue, ceo)

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: all delegated child work is complete. Files changed: delegated child artifacts. Verification: child issue is closed. Risks: none known. Current state: ready for approval. Next decision: CEO owner update.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      assert {:ok, %{results: [%{issue_id: child_id}]}} =
               AgentActions.execute(issue, cto, [
                 %{"type" => "create_issue", "title" => "Closable child", "role" => "engineer"}
               ])

      {:ok, _} = Issues.update_issue(Issues.get_issue!(child_id), %{status: :done})
      insert_completed_run(ceo, issue)
      insert_work_product(issue, ceo)

      assert {:ok, _} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "approve_issue",
                   "notes" =>
                     "[owner_update] What happened: all delegated child work is complete. Business status: shipped. Current state: closed. Next decision: none. Owner decision needed: none."
                 }
               ])

      assert Issues.get_issue!(issue.id).status == :done
    end

    test "engineer attempting approve_issue is rejected with a system comment", %{
      issue: issue,
      engineer: engineer
    } do
      # Engineers are non-governance — they cannot approve, request_changes,
      # or block. The server rejects with :unauthorized_action and surfaces a
      # system comment so the LLM gets actionable feedback on its next turn.
      assert {:error, :unauthorized_action} =
               AgentActions.execute(issue, engineer, [
                 %{"type" => "approve_issue", "notes" => "trying my luck"}
               ])

      # Issue unchanged
      unchanged = Issues.get_issue!(issue.id)
      refute unchanged.status == :done

      # System comment surfaces the rejection
      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn c ->
               c.author_type == "system" and
                 String.contains?(c.body, "Action rejected") and
                 String.contains?(c.body, "CEO/CTO")
             end)
    end
  end

  defp insert_completed_run(agent, issue) do
    Repo.insert!(%Run{
      agent_id: agent.id,
      issue_id: issue.id,
      status: "completed",
      adapter: "process",
      continuation_summary: "Verification passed."
    })
  end

  defp insert_work_product(issue, agent) do
    WorkProducts.create_work_product(%{
      issue_id: issue.id,
      created_by_agent_id: agent.id,
      kind: "document",
      title: "Review evidence",
      description: "Evidence for review gates."
    })
  end
end
