defmodule Cympho.WorkModeTest do
  use Cympho.DataCase, async: false

  alias Cympho.{
    AgentActions,
    AgentPrompt,
    Agents,
    Comments,
    Companies,
    Documents,
    IssueThreadInteractions,
    Issues,
    Users,
    WorkProducts
  }

  alias Cympho.Issues.{Issue, IssueThreadInteraction}
  alias Cympho.Wakes.AgentWake

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Work mode #{unique}",
        slug: "work-mode-#{unique}"
      })

    {:ok, user} =
      Users.create_user(%{
        email: "work-mode-#{unique}@example.test",
        name: "Work mode owner",
        password: "password1234"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Planning CTO #{unique}",
        role: :cto,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "Choose the safe implementation path #{unique}",
        description: "Prepare only the work the selected mode allows.",
        status: :todo,
        assignee_id: agent.id,
        assigned_role: "cto"
      })

    {:ok, issue} = Issues.checkout_issue(issue, agent, :cto)

    %{agent: agent, company: company, issue: issue, user: user}
  end

  test "issues default to standard mode and reject unsupported values", %{company: company} do
    assert {:ok, issue} =
             Issues.create_issue(%{
               company_id: company.id,
               title: "Legacy issue without an explicit work mode"
             })

    assert issue.work_mode == :standard

    changeset = Issue.changeset(%Issue{}, %{title: "Invalid mode", work_mode: "ship_it"})
    refute changeset.valid?
    assert %{work_mode: ["is invalid"]} = errors_on(changeset)

    assert {:error, invalid_changeset} =
             Issues.create_issue(%{
               company_id: company.id,
               title: "Invalid persisted mode",
               work_mode: "ship_it"
             })

    assert %{work_mode: ["is invalid"]} = errors_on(invalid_changeset)
  end

  test "the prompt puts the planning contract directly after the current task", %{
    agent: agent,
    issue: issue
  } do
    {:ok, issue} = Issues.set_work_mode(issue, :planning)
    prompt = AgentPrompt.build(issue, agent)

    current_task_at = text_position(prompt, "## Current task - do this now")
    work_mode_at = text_position(prompt, "## HIGH PRIORITY WORK MODE — PLAN FIRST")
    role_contract_at = text_position(prompt, "## Role completion contract")

    assert current_task_at < work_mode_at
    assert work_mode_at < role_contract_at
    assert prompt =~ "MUST NOT implement, edit product code, delegate, create child issues"
    assert prompt =~ "End this turn with a structured `request_confirmation`"
    assert prompt =~ "automatically pins the confirmation to that revision"
  end

  test "structured question and confirmation actions parse strictly" do
    question_block =
      action_block([
        %{
          "type" => "ask_user_questions",
          "message" => "I need two choices before continuing.",
          "questions" => [
            %{"question" => "Which customer group matters first?", "ignored" => true},
            %{"question" => "What deadline should the plan respect?"}
          ]
        }
      ])

    assert {:ok,
            [
              %{
                "type" => "ask_user_questions",
                "questions" => [
                  %{"question" => "Which customer group matters first?"},
                  %{"question" => "What deadline should the plan respect?"}
                ]
              }
            ]} = AgentActions.parse(question_block)

    target_document_id = Ecto.UUID.generate()

    assert {:ok,
            [
              %{
                "type" => "request_confirmation",
                "message" => "Approve the reviewed plan?",
                "target_document_id" => ^target_document_id
              }
            ]} =
             AgentActions.parse(
               action_block([
                 %{
                   "type" => "request_confirmation",
                   "message" => "Approve the reviewed plan?",
                   "details" => "Acceptance unlocks implementation.",
                   "target_document_id" => target_document_id
                 }
               ])
             )

    assert {:error, :invalid_user_questions} =
             AgentActions.parse(
               action_block([%{"type" => "ask_user_questions", "questions" => []}])
             )

    assert {:error, {:required, "question"}} =
             AgentActions.parse(
               action_block([
                 %{"type" => "ask_user_questions", "questions" => [%{"label" => "Missing"}]}
               ])
             )

    assert {:error, {:required, "message"}} =
             AgentActions.parse(action_block([%{"type" => "request_confirmation"}]))

    assert {:error, {:invalid_uuid, "target_document_id"}} =
             AgentActions.parse(
               action_block([
                 %{
                   "type" => "request_confirmation",
                   "message" => "Approve?",
                   "target_document_id" => "not-a-document-id"
                 }
               ])
             )
  end

  test "planning mode rejects implementation and delegation without side effects", %{
    agent: agent,
    issue: issue
  } do
    {:ok, issue} = Issues.set_work_mode(issue, :planning)

    assert {:error, {:work_mode_action_forbidden, :planning, "attach_work_product"}} =
             AgentActions.execute(issue, agent, [
               %{
                 "type" => "attach_work_product",
                 "kind" => "code_change",
                 "title" => "Implementation patch"
               }
             ])

    assert {:error, {:work_mode_action_forbidden, :planning, "delegate"}} =
             AgentActions.execute(issue, agent, [
               %{"type" => "delegate", "to_role" => "engineer", "reason" => "Build it now."}
             ])

    assert WorkProducts.list_work_products(issue.id) == []
    assert IssueThreadInteractions.list_interactions(issue.id) == []

    unchanged = Issues.get_issue!(issue.id)
    assert unchanged.status == :in_progress
    assert unchanged.assignee_id == agent.id

    rejection_comments =
      issue.id
      |> Comments.list_comments()
      |> Enum.filter(&(&1.author_type == "system" and &1.body =~ "Plan first mode"))

    assert length(rejection_comments) == 2
  end

  test "ask mode creates one blocking interaction and the response resumes the creating agent", %{
    agent: agent,
    issue: issue,
    user: user
  } do
    {:ok, issue} = Issues.set_work_mode(issue, :ask)

    assert {:ok, %{results: [%{type: "ask_user_questions", interaction_id: interaction_id}]}} =
             AgentActions.execute(issue, agent, [
               %{
                 "type" => "ask_user_questions",
                 "message" => "Choose the audience before I continue.",
                 "questions" => [%{"question" => "Who is the first audience?"}]
               }
             ])

    interaction = Repo.get!(IssueThreadInteraction, interaction_id)
    assert interaction.status == :pending
    assert interaction.created_by_agent_id == agent.id
    assert interaction.payload["questions"] == [%{"question" => "Who is the first audience?"}]

    waiting = Issues.get_issue!(issue.id)
    assert waiting.status == :blocked
    assert waiting.work_mode == :ask
    assert waiting.assignee_id == agent.id
    assert is_nil(waiting.checkout_run_id)
    assert is_nil(waiting.checked_out_at)
    assert waiting.monitor_state["work_mode_wait"]["interaction_id"] == interaction.id

    assert {:ok, resolved} =
             IssueThreadInteractions.resolve_interaction(interaction, %{
               "status" => :responded,
               "resolved_by_user_id" => user.id,
               "response" => "Independent shop owners are first."
             })

    assert resolved.status == :responded

    resumed = Issues.get_issue!(issue.id)
    assert resumed.status == :todo
    assert resumed.work_mode == :standard
    refute Map.has_key?(resumed.monitor_state, "work_mode_wait")

    assert [%{body: "Independent shop owners are first."}] =
             Enum.filter(Comments.list_comments(issue.id), &(&1.author_type == "user"))

    assert wake_count(agent.id, issue.id, "interaction_ask_user_questions_responded") == 1
  end

  test "planning confirmation stays planning after rejection and unlocks only after acceptance",
       %{
         agent: agent,
         issue: issue,
         user: user
       } do
    {:ok, issue} = Issues.set_work_mode(issue, :planning)

    assert {:ok,
            %{
              results: [
                %{planning_document_id: planning_document_id},
                %{interaction_id: rejected_id}
              ]
            }} =
             AgentActions.execute(issue, agent, [
               %{
                 "type" => "attach_work_product",
                 "kind" => "document",
                 "title" => "Safe implementation plan",
                 "description" =>
                   "# Plan\n\n1. Verify the boundary.\n2. Implement the smallest change."
               },
               %{
                 "type" => "request_confirmation",
                 "message" => "Approve the first plan?",
                 "details" => "No implementation has started."
               }
             ])

    rejected = Repo.get!(IssueThreadInteraction, rejected_id)
    planning_document = Documents.get_document!(planning_document_id)
    assert planning_document.key == "work-mode-plan"
    assert planning_document.body =~ "Implement the smallest change"
    assert rejected.payload["target_document_id"] == planning_document.id
    assert rejected.payload["target_revision_number"] == 1
    assert byte_size(rejected.payload["target_revision_sha256"]) == 64

    assert {:ok, %{status: :rejected}} =
             IssueThreadInteractions.resolve_interaction(rejected, %{
               status: :rejected,
               resolved_by_user_id: user.id
             })

    after_rejection = Issues.get_issue!(issue.id)
    assert after_rejection.status == :todo
    assert after_rejection.work_mode == :planning

    assert {:ok, %{results: [%{interaction_id: accepted_id}]}} =
             AgentActions.execute(after_rejection, agent, [
               %{
                 "type" => "request_confirmation",
                 "message" => "Approve the revised plan?"
               }
             ])

    accepted = Repo.get!(IssueThreadInteraction, accepted_id)
    assert is_binary(accepted.payload["target_document_id"])
    assert is_integer(accepted.payload["target_revision_number"])
    assert byte_size(accepted.payload["target_revision_sha256"]) == 64

    assert {:ok, %{status: :accepted}} =
             IssueThreadInteractions.resolve_interaction(accepted, %{
               status: :accepted,
               resolved_by_user_id: user.id
             })

    after_acceptance = Issues.get_issue!(issue.id)
    assert after_acceptance.status == :todo
    assert after_acceptance.work_mode == :standard
    assert wake_count(agent.id, issue.id, "interaction_request_confirmation_rejected") == 1
    assert wake_count(agent.id, issue.id, "interaction_request_confirmation_accepted") == 1
  end

  test "a planning document is auto-pinned and stale acceptance stays locked",
       %{agent: agent, issue: issue, user: user} do
    {:ok, issue} = Issues.set_work_mode(issue, :planning)

    assert {:ok,
            %{results: [%{planning_document_id: document_id}, %{interaction_id: interaction_id}]}} =
             AgentActions.execute(issue, agent, [
               %{
                 "type" => "attach_work_product",
                 "kind" => "document",
                 "title" => "Reversible rollout",
                 "payload" => %{"text" => "Version one keeps the rollout reversible."}
               },
               %{
                 "type" => "request_confirmation",
                 "message" => "Approve the server-pinned plan?"
               }
             ])

    interaction = Repo.get!(IssueThreadInteraction, interaction_id)
    assert interaction.payload["target_document_id"] == document_id
    assert interaction.payload["target_revision_number"] == 1

    document = Documents.get_document!(document_id)

    assert {:ok, _updated_document} =
             Documents.update_document(
               document,
               %{body: "Version two changes the rollout order."},
               user.id,
               "user"
             )

    assert {:error, :stale_target_revision} =
             IssueThreadInteractions.resolve_interaction(interaction, %{
               status: :accepted,
               resolved_by_user_id: user.id
             })

    still_pending = Repo.get!(IssueThreadInteraction, interaction.id)
    assert still_pending.status == :pending

    still_locked = Issues.get_issue!(issue.id)
    assert still_locked.status == :blocked
    assert still_locked.work_mode == :planning
    assert wake_count(agent.id, issue.id, "interaction_request_confirmation_accepted") == 0
  end

  test "planning confirmation without a reviewable plan fails closed", %{
    agent: agent,
    issue: issue
  } do
    {:ok, issue} = Issues.set_work_mode(issue, :planning)

    assert {:error, :planning_document_required} =
             AgentActions.execute(issue, agent, [
               %{
                 "type" => "request_confirmation",
                 "message" => "Approve an unversioned plan?"
               }
             ])

    assert Documents.list_documents(issue.id) == []
    assert IssueThreadInteractions.list_interactions(issue.id) == []
    assert Issues.get_issue!(issue.id).status == :in_progress

    assert Enum.any?(Comments.list_comments(issue.id), fn comment ->
             comment.author_type == "system" and
               comment.body =~ "needs a reviewable planning document"
           end)
  end

  test "planning confirmation rejects an explicit non-canonical document", %{
    agent: agent,
    issue: issue
  } do
    {:ok, issue} = Issues.set_work_mode(issue, :planning)

    {:ok, canonical} =
      Documents.create_document(%{
        issue_id: issue.id,
        key: "work-mode-plan",
        title: "Canonical plan",
        body: "The canonical reviewed plan."
      })

    {:ok, arbitrary} =
      Documents.create_document(%{
        issue_id: issue.id,
        key: "meeting-notes",
        title: "Meeting notes",
        body: "Not the planning approval target."
      })

    assert {:error, :invalid_planning_document} =
             AgentActions.execute(issue, agent, [
               %{
                 "type" => "request_confirmation",
                 "message" => "Approve these notes instead?",
                 "target_document_id" => arbitrary.id
               }
             ])

    assert IssueThreadInteractions.list_interactions(issue.id) == []
    assert Issues.get_issue!(issue.id).status == :in_progress
    assert canonical.key == "work-mode-plan"
  end

  test "an unrelated pending question is not reused and the issue is blocked on a fresh one", %{
    agent: agent,
    issue: issue
  } do
    {:ok, issue} = Issues.set_work_mode(issue, :ask)

    {:ok, unrelated} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: issue.id,
        kind: :ask_user_questions,
        created_by_agent_id: agent.id,
        payload: %{"questions" => [%{"question" => "An older unrelated question?"}]}
      })

    assert {:ok, %{results: [%{interaction_id: fresh_id}]}} =
             AgentActions.execute(issue, agent, [
               %{
                 "type" => "ask_user_questions",
                 "questions" => [%{"question" => "Which audience should we use now?"}]
               }
             ])

    refute fresh_id == unrelated.id
    assert Repo.get!(IssueThreadInteraction, unrelated.id).status == :pending

    waiting = Issues.get_issue!(issue.id)
    assert waiting.status == :blocked
    assert waiting.assignee_id == agent.id
    assert waiting.monitor_state["work_mode_wait"]["interaction_id"] == fresh_id
  end

  test "a stale pinned confirmation is replaced and the new revision owns the wait", %{
    agent: agent,
    issue: issue,
    user: user
  } do
    {:ok, issue} = Issues.set_work_mode(issue, :planning)

    {:ok, document} =
      Documents.create_document(%{
        issue_id: issue.id,
        key: "work-mode-plan",
        title: "Revisioned plan",
        body: "Version one"
      })

    {:ok, stale} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: issue.id,
        kind: :request_confirmation,
        created_by_agent_id: agent.id,
        payload: %{
          "message" => "Approve version one?",
          "target_document_id" => document.id
        }
      })

    {:ok, waiting} =
      Issues.update_issue(issue, %{
        status: :blocked,
        monitor_state: %{
          "work_mode_wait" => %{
            "interaction_id" => stale.id,
            "kind" => "request_confirmation"
          }
        }
      })

    {:ok, _updated_document} =
      Documents.update_document(document, %{body: "Version two"}, user.id, "user")

    assert {:ok, %{results: [%{interaction_id: fresh_id}]}} =
             AgentActions.execute(waiting, agent, [
               %{
                 "type" => "request_confirmation",
                 "message" => "Approve the current revision?",
                 "target_document_id" => document.id
               }
             ])

    refute fresh_id == stale.id
    fresh = Repo.get!(IssueThreadInteraction, fresh_id)
    assert fresh.payload["target_document_id"] == document.id
    assert fresh.payload["target_revision_number"] == 2

    reblocked = Issues.get_issue!(issue.id)
    assert reblocked.status == :blocked
    assert reblocked.monitor_state["work_mode_wait"]["interaction_id"] == fresh.id
    assert reblocked.monitor_state["work_mode_wait"]["target_revision_number"] == 2
  end

  test "a planning question response keeps implementation locked", %{
    agent: agent,
    issue: issue,
    user: user
  } do
    {:ok, issue} = Issues.set_work_mode(issue, :planning)

    assert {:ok, %{results: [%{interaction_id: interaction_id}]}} =
             AgentActions.execute(issue, agent, [
               %{
                 "type" => "ask_user_questions",
                 "questions" => [%{"question" => "Should the plan optimize speed or cost?"}]
               }
             ])

    interaction = Repo.get!(IssueThreadInteraction, interaction_id)

    assert {:ok, _resolved} =
             IssueThreadInteractions.resolve_interaction(interaction, %{
               status: :responded,
               resolved_by_user_id: user.id,
               response: "Optimize cost."
             })

    resumed = Issues.get_issue!(issue.id)
    assert resumed.status == :todo
    assert resumed.work_mode == :planning
  end

  test "resolving an unrelated interaction never clears a blocker", %{
    agent: agent,
    issue: issue,
    user: user
  } do
    {:ok, issue} =
      Issues.update_issue(issue, %{
        status: :blocked,
        monitor_state: %{"blocker_packet" => %{"cause" => "Waiting for credentials"}}
      })

    {:ok, interaction} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: issue.id,
        kind: :ask_user_questions,
        created_by_agent_id: agent.id,
        payload: %{"questions" => [%{"question" => "Can credentials be added?"}]}
      })

    assert {:ok, _resolved} =
             IssueThreadInteractions.resolve_interaction(interaction, %{
               status: :responded,
               resolved_by_user_id: user.id,
               response: "Not yet."
             })

    still_blocked = Issues.get_issue!(issue.id)
    assert still_blocked.status == :blocked
    assert still_blocked.monitor_state["blocker_packet"]["cause"] == "Waiting for credentials"
  end

  defp action_block(actions) do
    """
    ```cympho-actions
    #{Jason.encode!(%{"actions" => actions})}
    ```
    """
  end

  defp text_position(text, needle) do
    {position, _length} = :binary.match(text, needle)
    position
  end

  defp wake_count(agent_id, issue_id, reason) do
    Repo.aggregate(
      from(w in AgentWake,
        where: w.agent_id == ^agent_id and w.issue_id == ^issue_id and w.reason == ^reason
      ),
      :count,
      :id
    )
  end
end
