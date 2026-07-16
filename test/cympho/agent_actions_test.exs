defmodule Cympho.AgentActionsTest do
  use Cympho.DataCase, async: false

  alias Cympho.{
    AgentActions,
    Agents,
    Comments,
    Companies,
    Issues,
    PrincipalPermissions,
    Repo,
    Secrets,
    WorkProducts
  }

  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.SwarmEvents

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

    test "recovers from common cympho-actions fence typo" do
      body = """
      Delivered.

      ```cympo-actions
      {"actions":[{"type":"comment","body":"Recovered"}]}
      ```
      """

      assert {:ok, [%{"type" => "comment", "body" => "Recovered"}]} =
               AgentActions.parse(body)
    end

    test "recovers when an action marker precedes a json fence" do
      body = """
      summary: completed

      cympo-actions
      ```json
      {"actions":[{"type":"comment","body":"Recovered from json fence"}]}
      ```
      """

      assert {:ok, [%{"type" => "comment", "body" => "Recovered from json fence"}]} =
               AgentActions.parse(body)
    end

    test "rejects unsupported actions" do
      body = """
      ```cympho-actions
      {"actions":[{"type":"ship_money"}]}
      ```
      """

      assert {:error, {:unsupported_action, "ship_money"}} = AgentActions.parse(body)
    end

    test "normalizes attach_work_product name and content aliases" do
      body = """
      ```cympho-actions
      {"actions":[{"type":"attach_work_product","kind":"strategy_doc","name":"CEO execution plan","content":"Plan summary for the owner.","payload":"long plan text"}]}
      ```
      """

      assert {:ok,
              [
                %{
                  "type" => "attach_work_product",
                  "kind" => "document",
                  "title" => "CEO execution plan",
                  "description" => "Plan summary for the owner.",
                  "payload" => %{"text" => "long plan text"}
                }
              ]} = AgentActions.parse(body)
    end

    test "rejects malformed structured create_issue brief fields" do
      body = """
      ```cympho-actions
      {"actions":[{"type":"create_issue","title":"Build thing","role":"engineer","acceptance_criteria":{"too":"nested"}}]}
      ```
      """

      assert {:error, {:invalid_string_or_list, "acceptance_criteria"}} =
               AgentActions.parse(body)
    end

    test "rejects short delegate target ids" do
      body = """
      ```cympho-actions
      {"actions":[{"type":"delegate","to_agent_id":"68db524a","reason":"Use the named engineer."}]}
      ```
      """

      assert {:error, {:invalid_uuid, "to_agent_id"}} = AgentActions.parse(body)
    end

    test "recovers a plain ```json fence carrying an actions payload" do
      body = """
      Summary of my work.

      ```json
      {"actions":[{"type":"comment","body":"Recovered from plain json fence"}]}
      ```
      """

      assert {:ok, [%{"type" => "comment", "body" => "Recovered from plain json fence"}]} =
               AgentActions.parse(body)
    end

    test "recovers an unfenced actions object embedded in prose" do
      body = """
      Here is the outcome. {"actions": [{"type": "comment", "body": "bare object"}]} Done.
      """

      assert {:ok, [%{"type" => "comment", "body" => "bare object"}]} = AgentActions.parse(body)
    end

    test "recovers fence label variants (caps, underscore)" do
      caps = """
      ```CYMPHO-ACTIONS
      {"actions":[{"type":"comment","body":"caps"}]}
      ```
      """

      underscore = """
      ```cympho_actions
      {"actions":[{"type":"comment","body":"underscore"}]}
      ```
      """

      assert {:ok, [%{"body" => "caps"}]} = AgentActions.parse(caps)
      assert {:ok, [%{"body" => "underscore"}]} = AgentActions.parse(underscore)
    end

    test "repairs a trailing comma in the actions array" do
      body = """
      ```cympho-actions
      {"actions":[{"type":"comment","body":"trailing comma"},]}
      ```
      """

      assert {:ok, [%{"type" => "comment", "body" => "trailing comma"}]} =
               AgentActions.parse(body)
    end

    test "repairs raw newlines inside a JSON string" do
      body = """
      ```cympho-actions
      {"actions":[{"type":"comment","body":"line one
      line two"}]}
      ```
      """

      assert {:ok, [%{"type" => "comment", "body" => comment}]} = AgentActions.parse(body)
      assert comment =~ "line one"
      assert comment =~ "line two"
    end

    test "recovers a truncated block cut mid-output" do
      body = """
      ```cympho-actions
      {"actions":[{"type":"comment","body":"partial resul
      """

      assert {:ok, [%{"type" => "comment", "body" => comment}]} = AgentActions.parse(body)
      assert comment =~ "partial resul"
    end

    test "accepts a bare list payload and a single action object payload" do
      list_body = """
      ```cympho-actions
      [{"type":"comment","body":"bare list"}]
      ```
      """

      single_body = """
      ```cympho-actions
      {"type":"comment","body":"single object"}
      ```
      """

      assert {:ok, [%{"body" => "bare list"}]} = AgentActions.parse(list_body)
      assert {:ok, [%{"body" => "single object"}]} = AgentActions.parse(single_body)
    end

    test "collapses byte-identical duplicate blocks but rejects distinct ones" do
      duplicated = """
      ```cympho-actions
      {"actions":[{"type":"comment","body":"dup"}]}
      ```

      To restate:

      ```cympho-actions
      {"actions":[{"type":"comment","body":"dup"}]}
      ```
      """

      distinct = """
      ```cympho-actions
      {"actions":[{"type":"comment","body":"first"}]}
      ```
      ```cympho-actions
      {"actions":[{"type":"comment","body":"second"}]}
      ```
      """

      assert {:ok, [%{"body" => "dup"}]} = AgentActions.parse(duplicated)
      assert {:error, :multiple_action_blocks} = AgentActions.parse(distinct)
    end

    test "converts an unknown action type into a skip marker when valid actions exist" do
      body = """
      ```cympho-actions
      {"actions":[{"type":"ship_money"},{"type":"comment","body":"still executes"}]}
      ```
      """

      assert {:ok,
              [
                %{"type" => "skip_unsupported", "original_type" => "ship_money"},
                %{"type" => "comment", "body" => "still executes"}
              ]} = AgentActions.parse(body)
    end

    test "a batch of only unknown actions still fails hard" do
      body = """
      ```cympho-actions
      {"actions":[{"type":"ship_money"}]}
      ```
      """

      assert {:error, {:unsupported_action, "ship_money"}} = AgentActions.parse(body)
    end

    test "unparseable JSON still reports a precise decode error" do
      body = """
      ```cympho-actions
      this is not json at all
      ```
      """

      assert {:error, {:invalid_json, _message}} = AgentActions.parse(body)
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
      engineer: engineer,
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
          "acceptance_criteria" => [
            "Executor runs validated agent actions in order.",
            "Failures leave a visible rejection comment."
          ],
          "evidence_required" => "Code diff and focused AgentActions tests.",
          "verification_required" => "mix test test/cympho/agent_actions_test.exs",
          "definition_of_done" => "PR linked, tests pass, and delivery note names risks.",
          "risks" => ["Do not bypass company scoping."],
          "priority" => "high"
        }
      ]

      assert {:ok,
              %{
                results: [%{type: "create_issue", issue_id: created_id, assignee_id: assignee_id}]
              }} =
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
      assert created.assignee_id == engineer.id
      assert assignee_id == engineer.id
      assert created.priority == :high
      assert created.status == :todo

      assert created.description =~ "Implement executor tests."
      assert created.description =~ "## Execution brief"
      assert created.description =~ "Parent issue: #{issue.identifier}"
      assert created.description =~ "Target role: engineer"
      assert created.description =~ "- Executor runs validated agent actions in order."
      assert created.description =~ "- Failures leave a visible rejection comment."
      assert created.description =~ "- Code diff and focused AgentActions tests."
      assert created.description =~ "- mix test test/cympho/agent_actions_test.exs"
      assert created.description =~ "- PR linked, tests pass, and delivery note names risks."
      assert created.description =~ "- Do not bypass company scoping."
    end

    test "create_issue rejects thin delivery briefs before spawning wasted runtime", %{
      issue: issue,
      cto: cto
    } do
      actions = [
        %{
          "type" => "create_issue",
          "title" => "Build vague thing",
          "description" => "Please do the implementation.",
          "role" => "engineer"
        }
      ]

      assert {:error,
              {:delivery_brief_too_thin, :engineer, next_prompt, missing_signals, repair_scaffold}} =
               AgentActions.execute(issue, cto, actions)

      assert next_prompt =~ "Acceptance criteria"
      assert "Acceptance criteria" in missing_signals
      assert repair_scaffold =~ "Acceptance criteria:"
      assert repair_scaffold =~ "Definition of done:"

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "create_issue rejected") and
                 String.contains?(comment.body, "delivery brief is too thin") and
                 String.contains?(comment.body, "Repair scaffold")
             end)

      refute Enum.any?(Issues.list_child_issues(issue.id), &(&1.title == "Build vague thing"))
    end

    test "create_issue allows non-delivery planning briefs without repo execution fields", %{
      issue: issue,
      cto: cto
    } do
      actions = [
        %{
          "type" => "create_issue",
          "title" => "Review architecture strategy",
          "description" => "Decide the approach before implementation.",
          "role" => "cto"
        }
      ]

      assert {:ok, %{results: [%{type: "create_issue", issue_id: created_id}]}} =
               AgentActions.execute(issue, cto, actions)

      assert Issues.get_issue!(created_id).assigned_role == "cto"
    end

    test "create_issue rejects non-governance agents without task assignment grants", %{
      issue: issue,
      engineer: engineer
    } do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          assignee_id: engineer.id,
          assigned_role: "engineer",
          status: :in_progress
        })

      actions = [
        delivery_issue_action(%{
          "title" => "Split engineering task without grant"
        })
      ]

      assert {:error, {:task_assignment_permission_required, :engineer}} =
               AgentActions.execute(issue, engineer, actions)

      refute Enum.any?(
               Issues.list_child_issues(issue.id),
               &(&1.title == "Split engineering task without grant")
             )

      assert Enum.any?(Comments.list_comments(issue.id), fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "create_issue rejected") and
                 String.contains?(comment.body, "task.assign") and
                 String.contains?(comment.body, "scoped principal permission grant")
             end)
    end

    test "scoped task assignment grant lets product create engineering child work", %{
      issue: issue,
      company: company,
      project: project,
      engineer: engineer
    } do
      [product | _] = Agents.list_agents_by_role(:product_manager, company.id)

      {:ok, _grant} =
        PrincipalPermissions.create_permission_grant(%{
          principal_id: product.id,
          principal_type: "agent",
          permission: "tasks:assign",
          scope_type: "project",
          scope_id: project.id
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          assignee_id: product.id,
          assigned_role: "product_manager",
          status: :in_progress
        })

      actions = [
        delivery_issue_action(%{
          "title" => "Implement product-scoped grant task"
        })
      ]

      assert {:ok,
              %{
                results: [%{type: "create_issue", issue_id: created_id, assignee_id: assignee_id}]
              }} =
               AgentActions.execute(issue, product, actions)

      created = Issues.get_issue!(created_id)
      assert created.created_by_agent_id == product.id
      assert created.parent_id == issue.id
      assert created.assigned_role == "engineer"
      assert created.assignee_id == engineer.id
      assert assignee_id == engineer.id
    end

    test "agent permission map can authorize task assignment from admin toggle", %{
      issue: issue,
      company: company,
      engineer: engineer
    } do
      [product | _] = Agents.list_agents_by_role(:product_manager, company.id)

      {:ok, product} =
        Agents.update_agent_permissions(product, %{"can_assign_tasks" => ["false", "true"]})

      {:ok, issue} =
        Issues.update_issue(issue, %{
          assignee_id: product.id,
          assigned_role: "product_manager",
          status: :in_progress
        })

      actions = [
        delivery_issue_action(%{
          "title" => "Implement permission-map task"
        })
      ]

      assert {:ok, %{results: [%{type: "create_issue", issue_id: created_id}]}} =
               AgentActions.execute(issue, product, actions)

      created = Issues.get_issue!(created_id)
      assert created.created_by_agent_id == product.id
      assert created.assignee_id == engineer.id
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
        delivery_issue_action(%{
          "title" => "Local child still allowed",
          "description" => "Company scoped child count should ignore malformed foreign rows."
        })
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

    test "submit_review is rejected when the same batch declares blocked work", %{
      issue: issue,
      engineer: engineer
    } do
      {:ok, issue} = Issues.update_issue(issue, %{assignee_id: engineer.id, status: :in_progress})

      actions = [
        %{
          "type" => "comment",
          "body" =>
            "[blocked] Cause: missing repository access. Needs: owner grants access. Current state: no delivery is possible. Next decision: unblock credentials. Restart packet: retry after access is granted."
        },
        %{
          "type" => "submit_review",
          "role" => "cto",
          "notes" => "Ready for review even though I cannot proceed."
        }
      ]

      assert {:error, {:contradictory_success_signal, "submit_review"}} =
               AgentActions.execute(issue, engineer, actions)

      unchanged = Issues.get_issue!(issue.id)
      assert unchanged.status == :in_progress
      assert unchanged.assignee_id == engineer.id

      comments = Comments.list_comments(issue.id)

      refute Enum.any?(comments, fn c ->
               c.author_type == "agent" and String.contains?(c.body, "[blocked]")
             end)

      assert Enum.any?(comments, fn c ->
               c.author_type == "system" and
                 String.contains?(c.body, "submit_review rejected") and
                 String.contains?(c.body, "block_issue") and
                 String.contains?(c.body, "remove blocked/cannot-proceed language")
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
            "[delivery] What happened: implementation is ready for CTO review. Files changed: implementation notes. Evidence produced: delivery notes work product and completed run. Verification: completed run passed. Risks: none known. Current state: ready for review. Next decision: CTO review. Restart packet: CTO should inspect the delivery notes and completed run before deciding."
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

    test "submit_review passes the runtime gate while the agent's own run is still active", %{
      issue: issue,
      engineer: engineer
    } do
      {:ok, issue} = Issues.update_issue(issue, %{assignee_id: engineer.id, status: :in_progress})
      insert_completed_run(engineer, issue)

      # The submitting agent's own run is still "running" at action time —
      # the orchestrator executes actions before the run record completes.
      # The gate must not count it as a runtime-verification blocker.
      Repo.insert!(%Run{
        agent_id: engineer.id,
        issue_id: issue.id,
        status: "running",
        adapter: "process"
      })

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
            "[delivery] What happened: implementation is ready for CTO review. Files changed: implementation notes. Evidence produced: delivery notes work product and completed run. Verification: completed run passed. Risks: none known. Current state: ready for review. Next decision: CTO review. Restart packet: CTO should inspect the delivery notes and completed run before deciding."
        }
      ]

      assert {:ok, _} = AgentActions.execute(issue, engineer, actions)
      assert Issues.get_issue!(issue.id).status == :in_review
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
            "[delivery] What happened: evidence is ready for CTO review. Files changed: fallback routing evidence. Evidence produced: fallback routing evidence work product and completed run. Verification: completed run passed. Risks: none known. Current state: ready for review. Next decision: CTO review. Restart packet: CTO should inspect the fallback routing evidence and completed run before deciding."
        }
      ]

      assert {:ok, _} = AgentActions.execute(issue, engineer, actions)

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :in_review
      assert updated.assignee_id == nil, "mismatched parent should fall back to dispatcher"
      assert updated.assigned_role == "cto"
    end

    test "submit_review stamps last_reviewer_id and reuses it on resubmit", %{
      issue: issue,
      cto: cto,
      engineer: engineer,
      company: company
    } do
      # Build a second CTO in the same company so we can prove round-2 sticks
      # with the same reviewer even after the parent relationship changes.
      {:ok, cto_two} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "CTO Two",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })

      {:ok, issue} = Issues.update_issue(issue, %{assignee_id: engineer.id, status: :in_progress})
      insert_completed_run(engineer, issue)

      round_one = [
        %{"type" => "attach_work_product", "kind" => "document", "title" => "round one"},
        %{
          "type" => "submit_review",
          "role" => "cto",
          "head_sha" => "sha-round-one",
          "notes" =>
            "[delivery] What happened: round one ready. Files changed: lib/foo.ex. Evidence produced: round one work product and sha-round-one. Verification: tests pass. Risks: none. Current state: ready. Next decision: CTO review. Restart packet: CTO should inspect lib/foo.ex, sha-round-one, and test notes before deciding."
        }
      ]

      assert {:ok, _} = AgentActions.execute(issue, engineer, round_one)

      after_round_one = Issues.get_issue!(issue.id)
      assert after_round_one.assignee_id == cto.id
      assert after_round_one.last_reviewer_id == cto.id

      # CTO asks for changes.
      assert {:ok, _} =
               AgentActions.execute(after_round_one, cto, [
                 %{
                   "type" => "request_changes",
                   "role" => "engineer",
                   "reason" => request_changes_reason()
                 }
               ])

      mid_loop = Issues.get_issue!(issue.id)
      assert mid_loop.status == :todo
      assert mid_loop.last_reviewer_id == cto.id

      # Re-parent the engineer to cto_two so parent-walk WOULD prefer cto_two.
      # last_reviewer_id should still win and keep this loop with cto.
      {:ok, engineer} = Agents.update_agent(engineer, %{parent_id: cto_two.id})

      # Engineer pushes a new commit and resubmits.
      {:ok, mid_loop} = Issues.update_issue(mid_loop, %{status: :in_progress})
      insert_completed_run(engineer, mid_loop)

      round_two = [
        %{"type" => "attach_work_product", "kind" => "document", "title" => "round two"},
        %{
          "type" => "submit_review",
          "role" => "cto",
          "head_sha" => "sha-round-two",
          "notes" =>
            "[delivery] What happened: round two addresses the gap. Action taken: resubmitted CTO review after adding coverage. Files changed: lib/foo.ex. Evidence produced: round two work product and sha-round-two. Evidence/artifact: round two work product and sha-round-two. Verification: tests pass including new coverage. Remaining risk: none. Current state: ready. Next decision: CTO re-review. Restart packet: CTO should inspect lib/foo.ex, sha-round-two, and new coverage before deciding."
        }
      ]

      assert {:ok, _} = AgentActions.execute(mid_loop, engineer, round_two)

      after_round_two = Issues.get_issue!(issue.id)

      assert after_round_two.assignee_id == cto.id,
             "round two should stick with the original reviewer"

      assert after_round_two.last_reviewer_id == cto.id
    end

    test "approve_issue clears last_reviewer_id", %{
      issue: issue,
      cto: cto,
      engineer: engineer,
      ceo: ceo
    } do
      insert_completed_run(ceo, issue)
      insert_work_product(issue, ceo)

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered the owner-approved work. Files changed: delivery artifact. Evidence produced: delivery artifact work product and completed run. Verification: completed run passed. Risks: none known. Current state: ready for approval. Next decision: CEO owner update. Restart packet: CEO should inspect the delivery artifact and completed run before closing.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      # Simulate a prior review round having stamped last_reviewer_id.
      {:ok, issue} = Issues.update_issue(issue, %{last_reviewer_id: cto.id})

      assert {:ok, _} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "approve_issue",
                   "notes" =>
                     "[owner_update] What happened: approved. Business status: shipped. Evidence inspected: delivery artifact and completed run. Verification: review gates are clear. Remaining risk: none known. Current state: closed. Next decision: none. Owner decision needed: none. Restart packet: issue is closed; no next runtime turn is needed unless reopened."
                 }
               ])

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :done
      assert reloaded.last_reviewer_id == nil

      _ = engineer
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
            "[delivery] What happened: delivered the owner-approved work. Files changed: delivery artifact. Evidence produced: delivery artifact work product and completed run. Verification: completed run passed. Risks: none known. Current state: ready for approval. Next decision: CEO owner update. Restart packet: CEO should inspect the delivery artifact and completed run before closing.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      actions = [
        %{
          "type" => "approve_issue",
          "notes" =>
            "[owner_update] What happened: approved this issue. Business status: shipped. Evidence inspected: delivery artifact and completed run. Verification: review gates are clear. Remaining risk: none known. Current state: closed. Next decision: none. Owner decision needed: none. Restart packet: issue is closed; no next runtime turn is needed unless reopened."
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

    test "approve_issue uses the paired review comment as notes when notes are omitted", %{
      issue: issue,
      cto: cto,
      engineer: engineer
    } do
      insert_completed_run(engineer, issue)
      insert_work_product(issue, engineer)

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered the requested work. Files changed: implementation files. Evidence produced: work product and completed verification run. Verification: completed run passed. Risks: none known. Current state: ready for approval. Next decision: CTO approval. Restart packet: CTO should inspect the work product and completed run.",
          author_type: "agent",
          author_id: engineer.id,
          issue_id: issue.id
        })

      actions = [
        %{
          "type" => "comment",
          "body" =>
            "[review] Verdict: accepted. What happened: reviewed the implementation and evidence. Evidence inspected: work product and completed verification run. Verification: completed run passed. Gaps: none. Follow-up issues: none. Next decision: close this issue. Restart packet: issue can be reopened if owner requests changes."
        },
        %{"type" => "approve_issue"}
      ]

      assert {:ok, _} = AgentActions.execute(issue, cto, actions)

      assert Issues.get_issue!(issue.id).status == :done
    end

    test "approve_issue rejects thin approval notes even when evidence gates pass", %{
      issue: issue,
      ceo: ceo
    } do
      insert_completed_run(ceo, issue)
      insert_work_product(issue, ceo)

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: delivered the requested owner work. Files changed: delivery artifact. Evidence produced: delivery artifact work product and completed run. Verification: completed run passed. Risks: none known. Current state: ready for approval. Next decision: CEO owner update. Restart packet: CEO should inspect the delivery artifact and completed run before closing.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      assert {:error, {:approval_note_too_thin, :ceo, missing, scaffold}} =
               AgentActions.execute(issue, ceo, [%{"type" => "approve_issue"}])

      assert "Business status" in missing
      assert "Owner decision needed" in missing
      assert scaffold =~ "Required shape: [owner_update] What happened:"

      reloaded = Issues.get_issue!(issue.id)
      refute reloaded.status == :done

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "approve_issue rejected") and
                 String.contains?(comment.body, "approval note is too thin") and
                 String.contains?(comment.body, "Repair scaffold")
             end)
    end

    test "approve_issue is rejected for code work without a reviewable reference", %{
      issue: issue,
      ceo: ceo,
      engineer: engineer,
      project: project
    } do
      # The PR requirement only applies when the project has a linked repo;
      # without one, workspace delivery counts as the code reference.
      {:ok, _project} =
        Cympho.Projects.update_project(project, %{repo_url: "https://github.com/example/repo"})

      insert_completed_run(engineer, issue)

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

    test "approve_issue passes the code-reference gate when no repo is linked", %{
      issue: issue,
      ceo: ceo,
      engineer: engineer
    } do
      insert_completed_run(engineer, issue)

      # URL-less code delivery: with no project repo configured, workspace
      # delivery is the reference — the gate must not demand set_pr_url.
      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: engineer.id,
          kind: "code_change",
          title: "Implementation patch"
        })

      # The code-reference gate must no longer fire; any later gate (e.g. the
      # approval-note shape) is out of scope for this test.
      case AgentActions.execute(issue, ceo, [%{"type" => "approve_issue"}]) do
        {:error, {:quality_gate_failed, "approve_issue", gaps}} ->
          refute :code_reference in gaps

        {:error, _other_gate} ->
          :ok

        {:ok, _} ->
          :ok
      end
    end

    test "approve_issue is rejected when runtime verification is missing", %{
      issue: issue,
      ceo: ceo,
      engineer: engineer
    } do
      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: engineer.id,
          kind: "code_change",
          title: "Implementation patch",
          url: "https://github.com/example/repo/pull/1"
        })

      assert {:error, {:quality_gate_failed, "approve_issue", gaps}} =
               AgentActions.execute(issue, ceo, [%{"type" => "approve_issue"}])

      assert :runtime_verification in gaps

      unchanged = Issues.get_issue!(issue.id)
      refute unchanged.status == :done
    end

    test "approve_issue accepts a latest successful run after earlier runtime failures", %{
      issue: issue,
      ceo: ceo,
      engineer: engineer
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%Run{
        agent_id: engineer.id,
        issue_id: issue.id,
        status: "failed",
        adapter: "process",
        error_reason: "transient sandbox failure",
        inserted_at: DateTime.add(now, -5, :minute),
        completed_at: DateTime.add(now, -5, :minute)
      })

      insert_completed_run(engineer, issue)

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: engineer.id,
          kind: "code_change",
          title: "Implementation patch",
          url: "file:///tmp/cympho/worktrees/ltv-8"
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: recovered after an earlier runtime failure. Files changed: implementation patch. Evidence produced: code reference and completed verification run. Verification: latest run passed. Risks: none known. Current state: ready for approval. Next decision: CEO owner update. Restart packet: CEO should inspect the latest completed run and code reference.",
          author_type: "agent",
          author_id: engineer.id,
          issue_id: issue.id
        })

      assert {:ok, _} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "approve_issue",
                   "notes" =>
                     "[owner_update] What happened: approved recovered runtime work. Business status: shipped. Evidence inspected: code reference and latest completed verification run. Verification: approval gates are clear after the later success. Remaining risk: none known. Current state: closed. Next decision: none. Owner decision needed: none. Restart packet: issue is closed; reopen only if follow-up changes are requested."
                 }
               ])

      assert Issues.get_issue!(issue.id).status == :done
    end

    test "approve_issue accepts manual verification after runtime failures", %{
      issue: issue,
      ceo: ceo,
      engineer: engineer
    } do
      Repo.insert!(%Run{
        agent_id: engineer.id,
        issue_id: issue.id,
        status: "failed",
        adapter: "process",
        error_reason: "sandbox could not reach Postgres"
      })

      Repo.insert!(%Run{
        agent_id: ceo.id,
        issue_id: issue.id,
        status: "running",
        adapter: "openai_chat",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      {:ok, _work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          created_by_agent_id: engineer.id,
          kind: "code_change",
          title: "Implementation patch",
          url: "file:///tmp/cympho/worktrees/ltv-8"
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[delivery] What happened: recovered after a sandbox runtime failure. Files changed: implementation patch. Evidence produced: code reference and host verification output. Verification: focused controller test passed with 0 failures. Risks: none known. Current state: ready for approval. Next decision: CEO owner update. Restart packet: CEO should inspect the code reference and host verification comment before closing.",
          author_type: "agent",
          author_id: engineer.id,
          issue_id: issue.id
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[review] Host verification update: `mix test test/cympho_web/controllers/launch_item_controller_test.exs` passed against the real test Postgres database: 6 tests, 0 failures. Restart packet: reviewer should inspect the code reference before approval.",
          author_type: "system",
          author_id: "00000000-0000-0000-0000-000000000000",
          issue_id: issue.id
        })

      assert {:ok, _} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "approve_issue",
                   "notes" =>
                     "[owner_update] What happened: approved manually verified work. Business status: shipped. Evidence inspected: code reference and host verification comment. Verification: focused controller test passed with 0 failures. Remaining risk: none known. Current state: closed. Next decision: none. Owner decision needed: none. Restart packet: issue is closed; reopen only if follow-up changes are requested."
                 }
               ])

      assert Issues.get_issue!(issue.id).status == :done
    end

    test "approve_issue is rejected when its note says work cannot proceed", %{
      issue: issue,
      ceo: ceo
    } do
      actions = [
        %{
          "type" => "approve_issue",
          "notes" =>
            "[owner_update] What happened: I cannot proceed because permission settings blocked verification. Business status: blocked. Owner decision needed: grant access. Evidence inspected: none."
        }
      ]

      assert {:error, {:contradictory_success_signal, "approve_issue"}} =
               AgentActions.execute(issue, ceo, actions)

      unchanged = Issues.get_issue!(issue.id)
      refute unchanged.status == :done

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn c ->
               c.author_type == "system" and
                 String.contains?(c.body, "approve_issue rejected") and
                 String.contains?(c.body, "blocked or incomplete work")
             end)
    end

    test "request_changes reopens issue for target role", %{issue: issue, cto: cto} do
      reason = request_changes_reason()

      actions = [%{"type" => "request_changes", "role" => "engineer", "reason" => reason}]

      assert {:ok, _} = AgentActions.execute(issue, cto, actions)

      updated = Issues.get_issue!(issue.id)
      comments = Comments.list_comments(issue.id)

      assert updated.status == :todo
      assert updated.assignee_id == nil
      assert updated.assigned_role == "engineer"

      assert Enum.any?(
               comments,
               &(&1.author_type == "agent" and &1.body == "[review] #{reason}")
             )
    end

    test "request_changes to repo delivery role rejects thin feedback", %{issue: issue, cto: cto} do
      reason = "Needs tests covering the null-guard in lib/foo.ex"

      actions = [%{"type" => "request_changes", "role" => "engineer", "reason" => reason}]

      assert {:error, {:request_changes_feedback_too_thin, :engineer, missing, scaffold}} =
               AgentActions.execute(issue, cto, actions)

      assert "Evidence inspected" in missing
      assert "Next action" in missing
      assert scaffold =~ "Required changes:"
      assert scaffold =~ "Current feedback: #{reason}"

      unchanged = Issues.get_issue!(issue.id)
      refute unchanged.status == :todo and unchanged.assignee_id == nil

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "request_changes rejected") and
                 String.contains?(comment.body, "review feedback is too thin") and
                 String.contains?(comment.body, "Repair scaffold")
             end)
    end

    test "block_issue blocks and comments with reason", %{issue: issue, ceo: ceo} do
      reason = block_issue_reason()
      actions = [%{"type" => "block_issue", "reason" => reason}]

      assert {:ok, _} = AgentActions.execute(issue, ceo, actions)

      updated = Issues.get_issue!(issue.id)
      comments = Comments.list_comments(issue.id)

      assert updated.status == :blocked
      assert updated.assignee_id == nil

      assert Enum.any?(
               comments,
               &(&1.author_type == "agent" and &1.body == "[blocked] #{reason}")
             )
    end

    test "block_issue rejects thin blocker reason", %{issue: issue, ceo: ceo} do
      actions = [%{"type" => "block_issue", "reason" => "Missing API key"}]

      assert {:error, {:block_issue_reason_too_thin, missing, scaffold}} =
               AgentActions.execute(issue, ceo, actions)

      assert "Cause" in missing
      assert "Attempted fix" in missing
      assert "Needs" in missing
      assert "Current state" in missing
      assert "Next decision" in missing
      assert scaffold =~ "Current blocker: Missing API key"
      assert scaffold =~ "Restart packet:"

      unchanged = Issues.get_issue!(issue.id)
      refute unchanged.status == :blocked

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "block_issue rejected") and
                 String.contains?(comment.body, "blocker reason is too thin") and
                 String.contains?(comment.body, "Repair scaffold")
             end)
    end

    test "block_issue rejects broad prose without exact blocker packet labels", %{
      issue: issue,
      ceo: ceo
    } do
      reason =
        "Because the API key is missing, owner must add it. Current state is waiting. " <>
          "Next decision is resume after credentials, with restart packet in the issue."

      actions = [%{"type" => "block_issue", "reason" => reason}]

      assert {:error, {:block_issue_reason_too_thin, missing, scaffold}} =
               AgentActions.execute(issue, ceo, actions)

      assert "Cause" in missing
      assert "Attempted fix" in missing
      assert "Needs" in missing
      assert "Restart packet" in missing
      assert scaffold =~ "[blocked] Cause:"

      unchanged = Issues.get_issue!(issue.id)
      refute unchanged.status == :blocked
    end

    test "request_changes is rejected when reason is empty", %{issue: issue, cto: cto} do
      actions = [%{"type" => "request_changes", "role" => "engineer", "reason" => ""}]

      assert {:error, {:governance_reason_missing, "request_changes"}} =
               AgentActions.execute(issue, cto, actions)

      unchanged = Issues.get_issue!(issue.id)
      refute unchanged.status == :todo and unchanged.assignee_id == nil
    end

    test "request_changes is rejected when reason is too short", %{issue: issue, cto: cto} do
      actions = [%{"type" => "request_changes", "role" => "engineer", "reason" => "bad code"}]

      assert {:error, {:governance_reason_too_short, "request_changes", 20}} =
               AgentActions.execute(issue, cto, actions)
    end

    test "request_changes records a Decision with reasoning on success", %{
      issue: issue,
      cto: cto,
      company: company
    } do
      reason = request_changes_reason()

      assert {:ok, _} =
               AgentActions.execute(issue, cto, [
                 %{"type" => "request_changes", "role" => "engineer", "reason" => reason}
               ])

      decisions =
        Cympho.Decisions.list_decisions(%{
          company_id: company.id,
          resource_type: "issue",
          resource_id: issue.id,
          decision_type: "review_rejection"
        })

      assert [decision] = decisions
      assert decision.outcome == "denied"
      assert decision.reasoning == reason
      assert decision.actor_type == "agent"
      assert decision.actor_id == cto.id
      assert decision.context["role_redirect"] == "engineer"
    end

    test "block_issue is rejected with empty reason", %{issue: issue, ceo: ceo} do
      actions = [%{"type" => "block_issue", "reason" => ""}]

      assert {:error, {:governance_reason_missing, "block_issue"}} =
               AgentActions.execute(issue, ceo, actions)
    end

    test "block_issue rejects unknown blocker_kind", %{issue: issue, ceo: ceo} do
      actions = [
        %{
          "type" => "block_issue",
          "reason" => block_issue_reason(),
          "blocker_kind" => "made_up_kind"
        }
      ]

      assert {:error, {:invalid_blocker_kind, "made_up_kind", _}} =
               AgentActions.execute(issue, ceo, actions)
    end

    test "block_issue records a Decision and stamps blocker_kind on monitor_state", %{
      issue: issue,
      ceo: ceo,
      company: company
    } do
      actions = [
        %{
          "type" => "block_issue",
          "reason" => block_issue_reason(),
          "blocker_kind" => "external_dep"
        }
      ]

      assert {:ok, _} = AgentActions.execute(issue, ceo, actions)

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :blocked
      assert reloaded.monitor_state["block_reason_kind"] == "external_dep"
      assert reloaded.monitor_state["blocker_packet"]["schema"] == "cympho.blocker_packet.v1"
      assert reloaded.monitor_state["blocker_packet"]["kind"] == "external_dep"
      assert reloaded.monitor_state["blocker_packet"]["blocked_by_agent_id"] == ceo.id

      assert reloaded.monitor_state["blocker_packet"]["cause"] ==
               "missing API key blocks runtime verification."

      assert reloaded.monitor_state["blocker_packet"]["attempted_fix"] ==
               "checked company secrets and runtime preflight."

      assert reloaded.monitor_state["blocker_packet"]["needs"] ==
               "owner or operator adds the missing API key."

      assert reloaded.monitor_state["blocker_packet"]["current_state"] ==
               "work is paused until credentials are available."

      assert reloaded.monitor_state["blocker_packet"]["next_decision"] ==
               "resume once the secret is configured."

      assert reloaded.monitor_state["blocker_packet"]["restart_packet"] ==
               "rerun runtime preflight, then continue the current issue."

      decisions =
        Cympho.Decisions.list_decisions(%{
          company_id: company.id,
          resource_type: "issue",
          resource_id: issue.id,
          decision_type: "block"
        })

      assert [decision] = decisions
      assert decision.outcome == "deferred"
      assert decision.context["blocker_kind"] == "external_dep"

      assert decision.context["blocker_packet"]["needs"] ==
               "owner or operator adds the missing API key."
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

    test "a retried attach_work_product does not double-create the artifact", %{
      issue: issue,
      engineer: engineer
    } do
      actions = [
        %{
          "type" => "attach_work_product",
          "kind" => "document",
          "title" => "Retry-safe notes"
        }
      ]

      assert {:ok, %{results: [%{work_product_id: id}]}} =
               AgentActions.execute(issue, engineer, actions)

      assert {:ok, %{results: [%{work_product_id: ^id, duplicate: true}]}} =
               AgentActions.execute(issue, engineer, actions)

      assert [%{id: ^id}] = WorkProducts.list_work_products(issue.id)
    end

    test "a retried comment does not double-post", %{issue: issue, engineer: engineer} do
      actions = [%{"type" => "comment", "body" => "Retry-safe status update."}]

      assert {:ok, %{results: [%{type: "comment", comment_id: id}]}} =
               AgentActions.execute(issue, engineer, actions)

      assert {:ok, %{results: [%{type: "comment", comment_id: ^id, duplicate: true}]}} =
               AgentActions.execute(issue, engineer, actions)

      matching =
        issue.id
        |> Comments.list_comments()
        |> Enum.filter(&(&1.body == "Retry-safe status update."))

      assert length(matching) == 1
    end

    test "an executor crash degrades to {:error, {:action_crashed, reason}} instead of raising",
         %{issue: issue, engineer: engineer} do
      # A map body has no String.Chars implementation — historically this
      # raised out of execute/3 and killed the orchestrator run.
      actions = [%{"type" => "comment", "body" => %{"oops" => true}}]

      assert {:error, {:action_crashed, reason}} = AgentActions.execute(issue, engineer, actions)
      assert is_binary(reason)
    end

    test "an unknown action in a batch is skipped with a system comment while the rest execute",
         %{issue: issue, engineer: engineer} do
      body = """
      ```cympho-actions
      {"actions":[{"type":"launch_rocket"},{"type":"comment","body":"Known action ran."}]}
      ```
      """

      assert {:ok, actions} = AgentActions.parse(body)

      assert {:ok, %{results: results}} = AgentActions.execute(issue, engineer, actions)

      assert [%{type: "skip_unsupported", skipped: true}, %{type: "comment"}] = results

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn c ->
               c.author_type == "system" and
                 String.contains?(c.body, ~s(Skipped unsupported action "launch_rocket"))
             end)

      assert Enum.any?(comments, &(&1.body == "Known action ran."))
    end

    test "text-only chat adapter can attach documents but not code-change claims", %{
      issue: issue,
      engineer: engineer
    } do
      {:ok, engineer} = Agents.update_agent(engineer, %{adapter: :openai_chat})

      assert {:ok, %{results: [%{type: "attach_work_product", work_product_id: id}]}} =
               AgentActions.execute(issue, engineer, [
                 %{
                   "type" => "attach_work_product",
                   "kind" => "document",
                   "title" => "Implementation plan",
                   "description" => "Text-only planning output."
                 }
               ])

      assert [%{id: ^id, kind: "document"}] = WorkProducts.list_work_products(issue.id)

      assert {:error, {:runtime_capability_blocked, "attach_work_product", "OpenAI Chat"}} =
               AgentActions.execute(issue, engineer, [
                 %{
                   "type" => "attach_work_product",
                   "kind" => "code_change",
                   "title" => "Implementation patch",
                   "description" => "Claims files were changed."
                 }
               ])

      assert [%{id: ^id}] = WorkProducts.list_work_products(issue.id)

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "attach_work_product rejected") and
                 String.contains?(comment.body, "text/action adapter") and
                 String.contains?(comment.body, "repo-capable runtime")
             end)
    end

    test "attach_work_product executes normalized name and content aliases", %{
      issue: issue,
      engineer: engineer
    } do
      body = """
      ```cympho-actions
      {"actions":[{"type":"attach_work_product","kind":"strategy_doc","name":"CEO execution plan","content":"Plan summary for the owner.","payload":"long plan text"}]}
      ```
      """

      assert {:ok, actions} = AgentActions.parse(body)

      assert {:ok, %{results: [%{type: "attach_work_product", work_product_id: id}]}} =
               AgentActions.execute(issue, engineer, actions)

      [work_product] = WorkProducts.list_work_products(issue.id)
      assert work_product.id == id
      assert work_product.title == "CEO execution plan"
      assert work_product.description == "Plan summary for the owner."
      assert work_product.kind == "document"
      assert work_product.payload == %{"text" => "long plan text"}
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

    test "text-only chat adapter cannot stamp a PR URL", %{
      issue: issue,
      engineer: engineer
    } do
      {:ok, engineer} = Agents.update_agent(engineer, %{adapter: :openai_chat})
      url = "https://github.com/example/repo/pull/42"

      assert {:error, {:runtime_capability_blocked, "set_pr_url", "OpenAI Chat"}} =
               AgentActions.execute(issue, engineer, [%{"type" => "set_pr_url", "url" => url}])

      updated = Issues.get_issue!(issue.id)
      refute updated.github_pr_url == url

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "set_pr_url rejected") and
                 String.contains?(comment.body, "cannot create or verify repo artifacts")
             end)
    end

    test "no-op custom process cannot stamp a PR URL", %{
      issue: issue,
      engineer: engineer
    } do
      {:ok, engineer} =
        Agents.update_agent(engineer, %{
          adapter: :process,
          config: %{"command" => "echo", "model" => "custom"}
        })

      url = "https://github.com/example/repo/pull/42"

      assert {:error, {:runtime_capability_blocked, "set_pr_url", "Process"}} =
               AgentActions.execute(issue, engineer, [%{"type" => "set_pr_url", "url" => url}])

      updated = Issues.get_issue!(issue.id)
      refute updated.github_pr_url == url

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "set_pr_url rejected") and
                 String.contains?(comment.body, "non-coding runtime") and
                 String.contains?(comment.body, "repo-capable runtime")
             end)
    end

    test "Agrenting output mode cannot stamp a PR URL", %{
      issue: issue,
      engineer: engineer
    } do
      {:ok, engineer} =
        Agents.update_agent(engineer, %{
          adapter: :agrenting,
          config: %{
            "agent_did" => "did:example:output-engineer",
            "capability" => "implementation",
            "max_price" => "1.00"
          }
        })

      url = "https://github.com/example/repo/pull/42"

      assert {:error, {:runtime_capability_blocked, "set_pr_url", "Agrenting"}} =
               AgentActions.execute(issue, engineer, [%{"type" => "set_pr_url", "url" => url}])

      updated = Issues.get_issue!(issue.id)
      refute updated.github_pr_url == url
    end

    test "Agrenting push mode with repo-token secret can stamp a PR URL", %{
      issue: issue,
      engineer: engineer,
      company: company
    } do
      {:ok, engineer} =
        Agents.update_agent(engineer, %{
          adapter: :agrenting,
          config: %{
            "agent_did" => "did:example:push-engineer",
            "capability" => "implementation",
            "delivery_mode" => "push",
            "max_price" => "1.00"
          }
        })

      {:ok, _secret} =
        Secrets.create_secret(%{
          company_id: company.id,
          scope: "company",
          key: "AGRENTING_REPO_ACCESS_TOKEN",
          value: "repo-token",
          description: "Agrenting repo access token"
        })

      url = "https://github.com/example/repo/pull/42"

      assert {:ok, _} =
               AgentActions.execute(issue, engineer, [%{"type" => "set_pr_url", "url" => url}])

      updated = Issues.get_issue!(issue.id)
      assert updated.github_pr_url == url
    end

    test "handoff releases issue to a target role and names an eligible owner", %{
      issue: issue,
      ceo: ceo,
      cto: cto
    } do
      actions = [%{"type" => "handoff", "role" => "cto", "reason" => "Needs technical plan"}]

      assert {:ok, %{results: [%{type: "handoff", role: "cto", assignee_id: cto_id}]}} =
               AgentActions.execute(issue, ceo, actions)

      assert cto_id == cto.id

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :todo
      assert updated.assignee_id == cto.id
      assert updated.assigned_role == "cto"
    end

    test "handoff rejects thin repo-delivery briefs before releasing the issue", %{
      issue: issue,
      ceo: ceo
    } do
      {:ok, issue} = Issues.update_issue(issue, %{description: "Build the thing."})

      actions = [%{"type" => "handoff", "role" => "engineer", "reason" => "Please take it."}]

      assert {:error,
              {:handoff_delivery_brief_too_thin, :engineer, next_prompt, missing, scaffold}} =
               AgentActions.execute(issue, ceo, actions)

      assert next_prompt =~ "Acceptance criteria"
      assert "Acceptance criteria" in missing
      assert scaffold =~ "Delivery goal:"

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :in_progress
      assert updated.assignee_id == ceo.id
      assert updated.assigned_role == "ceo"

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "handoff rejected") and
                 String.contains?(comment.body, "directive is too thin") and
                 String.contains?(comment.body, "Repair scaffold")
             end)
    end

    test "handoff allows ready repo-delivery briefs and names an eligible owner", %{
      issue: issue,
      ceo: ceo,
      engineer: engineer
    } do
      actions = [
        %{
          "type" => "handoff",
          "role" => "engineer",
          "reason" =>
            "Acceptance criteria: implement the scoped repository change without expanding the issue. Evidence required: code diff or work product plus delivery note. Verification required: focused module test or named blocker. Definition of done: ready for CTO review with evidence and risk named."
        }
      ]

      assert {:ok, %{results: [%{type: "handoff", role: "engineer", assignee_id: engineer_id}]}} =
               AgentActions.execute(issue, ceo, actions)

      assert engineer_id == engineer.id

      updated = Issues.get_issue!(issue.id)
      assert updated.status == :todo
      assert updated.assignee_id == engineer.id
      assert updated.assigned_role == "engineer"
    end

    test "handoff keeps role routing when no eligible owner is available", %{
      issue: issue,
      ceo: ceo,
      cto: cto
    } do
      {:ok, cto} = Agents.update_agent(cto, %{max_concurrent_jobs: 1})

      {:ok, _active} =
        Issues.create_issue(%{
          title: "Saturate CTO review lane",
          description: "Consumes CTO capacity for the handoff fallback test.",
          status: :in_progress,
          priority: :medium,
          company_id: cto.company_id,
          assignee_id: cto.id,
          assigned_role: "cto"
        })

      actions = [%{"type" => "handoff", "role" => "cto", "reason" => "Needs technical plan"}]

      assert {:ok, %{results: [%{type: "handoff", role: "cto", assignee_id: nil}]}} =
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
        delivery_issue_action(%{
          "title" => "Dedup target issue",
          "priority" => "medium"
        })
      ]

      assert {:ok, %{results: [%{type: "create_issue", issue_id: first_id}]}} =
               AgentActions.execute(issue, cto, actions)

      assert {:ok, %{results: [%{type: "create_issue", issue_id: ^first_id, duplicate: true}]}} =
               AgentActions.execute(issue, cto, actions)

      assert Issues.get_issue!(first_id).parent_id == issue.id

      comments = Comments.list_comments(first_id)

      assert Enum.any?(comments, fn c ->
               c.author_type == "system" && String.contains?(c.body, "Duplicate creation attempt")
             end)
    end

    test "same-title decomposition under a different parent creates that parent's own child",
         %{
           company: company,
           project: project,
           goal: goal,
           issue: issue,
           cto: cto
         } do
      actions = [
        delivery_issue_action(%{
          "title" => "Existing delegated task",
          "priority" => "medium"
        })
      ]

      assert {:ok, %{results: [%{type: "create_issue", issue_id: existing_id}]}} =
               AgentActions.execute(issue, cto, actions)

      {:ok, parent} =
        Issues.create_issue(%{
          title: "Request existing delegated task again",
          description: "A separate CTO parent that should reuse the existing delegated work.",
          status: :todo,
          priority: :medium,
          company_id: company.id,
          project_id: project.id,
          goal_id: goal.id,
          assigned_role: "cto"
        })

      {:ok, parent} = Issues.checkout_issue(parent, cto, :cto)

      assert {:ok,
              %{
                issue: %{status: :blocked, assignee_id: nil},
                results: [
                  %{
                    type: "create_issue",
                    issue_id: new_child_id,
                    identifier: new_child_ref
                  }
                ]
              }} = AgentActions.execute(parent, cto, actions)

      assert new_child_id != existing_id

      new_child = Issues.get_issue!(new_child_id)
      assert new_child.parent_id == parent.id
      assert new_child.title == "Existing delegated task"

      comments = Comments.list_comments(parent.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "agent" and
                 String.contains?(comment.body, "Waiting for delegated work") and
                 String.contains?(comment.body, new_child_ref)
             end)
    end

    test "create_issue allows different titles", %{issue: issue, cto: cto} do
      actions_a = [
        delivery_issue_action(%{"title" => "Task A"})
      ]

      actions_b = [
        delivery_issue_action(%{"title" => "Task B"})
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
        delivery_issue_action(%{"title" => "Open child task"})
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
            "[delivery] What happened: scoped evidence is complete. Files changed: approval evidence. Evidence produced: approval evidence work product and completed run. Verification: passed. Risks: none known. Current state: ready for close. Next decision: CEO owner update. Restart packet: CEO should inspect the approval evidence and completed run before closing.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      assert {:ok, _} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "approve_issue",
                   "notes" =>
                     "[owner_update] What happened: scoped evidence is complete. Business status: ready. Evidence inspected: approval evidence and completed run. Verification: review gates are clear. Remaining risk: none known. Current state: closed. Next decision: none. Owner decision needed: none. Restart packet: issue is closed; no next runtime turn is needed unless reopened."
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
            "[delivery] What happened: all delegated child work is complete. Files changed: delegated child artifacts. Evidence produced: delegated child artifacts and closed child issue. Verification: child issue is closed. Risks: none known. Current state: ready for approval. Next decision: CEO owner update. Restart packet: CEO should inspect delegated child artifacts and closed child issue before closing.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      assert {:ok, %{results: [%{issue_id: child_id}]}} =
               AgentActions.execute(issue, cto, [
                 delivery_issue_action(%{"title" => "Closable child"})
               ])

      {:ok, _} = Issues.update_issue(Issues.get_issue!(child_id), %{status: :done})
      insert_completed_run(ceo, issue)
      insert_work_product(issue, ceo)

      {:ok, _comment} =
        Comments.create_comment(%{
          body:
            "[handoff] What happened: all delegated child work is complete. Action taken: inspected and closed the delegated child issue before CEO approval. Evidence/artifact: delegated child artifacts and closed child issue. Verification: child issue is done and parent review gates are clear. Remaining risk: none known. Current state: ready for CEO owner update. Next decision: CEO approval. Restart packet: CEO should inspect the delegated child artifacts, closed child issue, completed run, and review evidence before closing.",
          author_type: "agent",
          author_id: ceo.id,
          issue_id: issue.id
        })

      assert {:ok, _} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "approve_issue",
                   "notes" =>
                     "[owner_update] What happened: all delegated child work is complete. Business status: shipped. Evidence inspected: delegated child artifacts and closed child issue. Verification: review gates are clear. Remaining risk: none known. Current state: closed. Next decision: none. Owner decision needed: none. Restart packet: issue is closed; no next runtime turn is needed unless reopened."
                 }
               ])

      assert Issues.get_issue!(issue.id).status == :done
    end

    test "approve_issue accepts delegated parent owner update without duplicate delivery artifact",
         %{
           issue: issue,
           ceo: ceo,
           cto: cto
         } do
      assert {:ok, %{results: [%{issue_id: child_id}]}} =
               AgentActions.execute(issue, cto, [
                 delivery_issue_action(%{"title" => "Closed delegated child"})
               ])

      {:ok, _} = Issues.update_issue(Issues.get_issue!(child_id), %{status: :done})
      insert_completed_run(ceo, issue)

      assert {:ok, _} =
               AgentActions.execute(issue, ceo, [
                 %{
                   "type" => "approve_issue",
                   "notes" =>
                     "[owner_update] What happened: all delegated child work is complete. Business status: shipped. Evidence inspected: closed child issue and CTO/CEO review state. Verification: child issue is done and review gates are clear. Remaining risk: none known. Current state: closed. Next decision: none. Owner decision needed: none. Restart packet: issue is closed; reopen only for owner-requested follow-up."
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

    test "hidden one-time swarm worker can complete only its own packet", %{
      company: company,
      project: project,
      issue: parent,
      ceo: ceo
    } do
      {:ok, temp_agent} =
        Agents.create_agent(%{
          name: "Swarm Product Worker",
          role: :product_manager,
          status: :idle,
          company_id: company.id,
          project_id: project.id,
          parent_id: ceo.id,
          adapter: :openai_chat,
          config: %{"hidden" => true, "one_time" => true, "temporary" => true},
          runtime_config: %{
            "swarm" => %{
              "temporary" => true,
              "one_time" => true,
              "parent_issue_id" => parent.id
            }
          }
        })

      {:ok, worker_issue} =
        Issues.create_issue(%{
          title: "Swarm worker packet",
          description: "Prepare a packet for CTO synthesis.",
          status: :todo,
          company_id: company.id,
          project_id: project.id,
          parent_id: parent.id,
          assigned_role: "product_manager",
          origin_type: "swarm_worker",
          monitor_state: %{"swarm" => %{"agent_id" => temp_agent.id}}
        })

      {:ok, worker_issue} = Issues.checkout_issue(worker_issue, temp_agent, :product_manager)

      assert {:ok, %{results: [%{type: "swarm_worker_complete"}]}} =
               AgentActions.execute(worker_issue, temp_agent, [
                 %{
                   "type" => "swarm_worker_complete",
                   "summary" => "Recommended the smallest reversible launch decision."
                 }
               ])

      completed = Issues.get_issue!(worker_issue.id)
      assert completed.status == :done
      assert is_nil(completed.assignee_id)

      assert Enum.any?(Comments.list_comments(worker_issue.id), fn comment ->
               comment.author_id == temp_agent.id and
                 String.contains?(comment.body, "[delivery]") and
                 String.contains?(comment.body, "smallest reversible launch decision")
             end)

      [event] =
        parent
        |> SwarmEvents.list_for_issue()
        |> Enum.filter(&(&1.event_type == "worker_completed"))

      assert event.issue_id == worker_issue.id
      assert event.agent_id == temp_agent.id
      assert event.metadata["summary"] == "Recommended the smallest reversible launch decision."
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

  defp delivery_issue_action(attrs) do
    Map.merge(
      %{
        "type" => "create_issue",
        "role" => "engineer",
        "acceptance_criteria" => "Requested behavior is implemented within the scoped issue.",
        "evidence_required" => "Code diff or work product and a final delivery note.",
        "verification_required" => "Run the smallest meaningful focused test or manual check.",
        "definition_of_done" => "Ready for CTO review with evidence and remaining risk named."
      },
      attrs
    )
  end

  defp request_changes_reason do
    """
    Evidence inspected: PR diff and test output for lib/foo.ex.
    Action taken: requested changes back to the engineer with a focused null-guard test gap.
    Required changes:
    - Add tests covering the null-guard in lib/foo.ex.
    Verification required: run mix test test/foo_test.exs.
    Remaining risk: the null-guard can regress until the focused test is added.
    Next decision: engineer fixes the listed gap, attaches evidence, and resubmits for review.
    Restart packet: reopen the issue for engineer delivery, inspect lib/foo.ex and test/foo_test.exs, then resubmit with evidence.
    """
    |> String.trim()
  end

  defp block_issue_reason do
    """
    Cause: missing API key blocks runtime verification.
    Attempted fix: checked company secrets and runtime preflight.
    Needs: owner or operator adds the missing API key.
    Current state: work is paused until credentials are available.
    Next decision: resume once the secret is configured.
    Restart packet: rerun runtime preflight, then continue the current issue.
    """
    |> String.trim()
  end
end
