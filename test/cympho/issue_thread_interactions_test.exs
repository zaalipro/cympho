defmodule Cympho.IssueThreadInteractionsTest do
  use Cympho.DataCase, async: true

  import Ecto.Query

  alias Cympho.{Agents, Companies, Documents, IssueThreadInteractions, Issues, Users}
  alias Cympho.Issues.IssueThreadInteraction
  alias Cympho.Repo
  alias Cympho.Wakes.AgentWake

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Pinned Plan #{unique}",
        slug: "pinned-plan-#{unique}"
      })

    {:ok, user} =
      Users.create_user(%{
        email: "pinned-plan-#{unique}@example.test",
        name: "Plan Reviewer",
        password: "password1234"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Planning Agent #{unique}",
        role: :cto
      })

    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "Review the implementation plan",
        status: :in_review,
        assignee_id: agent.id
      })

    {:ok, document} =
      Documents.create_document(%{
        issue_id: issue.id,
        key: "implementation-plan",
        title: "Implementation plan",
        format: "markdown",
        body: "# Plan\n\nVersion one"
      })

    %{agent: agent, company: company, document: document, issue: issue, user: user}
  end

  test "a confirmation is server-pinned and the current revision can be accepted", context do
    assert {:ok, interaction} = create_confirmation(context, "caller-supplied-value")
    pinned_payload = interaction.payload

    assert interaction.payload["target_document_id"] == context.document.id
    assert interaction.payload["target_document_key"] == context.document.key
    assert interaction.payload["target_document_title"] == context.document.title
    assert interaction.payload["target_revision_number"] == 1
    assert byte_size(interaction.payload["target_revision_sha256"]) == 64
    refute interaction.payload["target_revision_sha256"] == "caller-supplied-value"

    assert {:ok, accepted} =
             IssueThreadInteractions.resolve_interaction(interaction, %{
               status: :accepted,
               resolved_by_user_id: context.user.id,
               payload: %{
                 "target_document_id" => Ecto.UUID.generate(),
                 "target_revision_number" => 99,
                 "target_revision_sha256" => "forged-on-resolution"
               }
             })

    assert accepted.status == :accepted
    assert accepted.payload == pinned_payload
    assert accepted.resolved_at
    assert accepted.resolved_by_user_id == context.user.id
    assert accepted_wake_count(context) == 1
  end

  test "an edited plan rejects stale approval without mutation or wake, then a fresh request succeeds",
       context do
    assert {:ok, stale_confirmation} = create_confirmation(context)

    assert {:ok, updated_document} =
             Documents.update_document(
               context.document,
               %{body: "# Plan\n\nVersion two"},
               context.user.id,
               "user"
             )

    fresh_context = %{context | document: updated_document}
    assert {:ok, fresh_confirmation} = create_confirmation(fresh_context)
    assert fresh_confirmation.payload["target_revision_number"] == 2

    assert {:error, :stale_target_revision} =
             IssueThreadInteractions.resolve_interaction(stale_confirmation, %{
               status: :accepted,
               resolved_by_user_id: context.user.id,
               payload: fresh_confirmation.payload
             })

    persisted = Repo.get!(IssueThreadInteraction, stale_confirmation.id)
    assert persisted.status == :pending
    assert is_nil(persisted.resolved_at)
    assert is_nil(persisted.resolved_by_user_id)
    assert persisted.payload["target_revision_number"] == 1
    assert accepted_wake_count(context) == 0

    assert {:ok, accepted} =
             IssueThreadInteractions.resolve_interaction(fresh_confirmation, %{
               status: :accepted,
               resolved_by_user_id: context.user.id
             })

    assert accepted.status == :accepted
    assert accepted_wake_count(context) == 1
  end

  test "rejects a creating agent from another company", context do
    unique = System.unique_integer([:positive])

    {:ok, other_company} =
      Companies.create_company(%{
        name: "Foreign interaction #{unique}",
        slug: "foreign-interaction-#{unique}"
      })

    {:ok, other_agent} =
      Agents.create_agent(%{
        company_id: other_company.id,
        name: "Foreign creator #{unique}",
        role: :cto
      })

    assert {:error, :invalid_created_by_agent} =
             IssueThreadInteractions.create_interaction(%{
               issue_id: context.issue.id,
               kind: :ask_user_questions,
               created_by_agent_id: other_agent.id,
               payload: %{"questions" => [%{"question" => "Cross company?"}]}
             })

    assert Repo.aggregate(IssueThreadInteraction, :count, :id) == 0
  end

  test "does not wake a forged cross-company creator on resolution", context do
    unique = System.unique_integer([:positive])

    {:ok, other_company} =
      Companies.create_company(%{
        name: "Forged wake #{unique}",
        slug: "forged-wake-#{unique}"
      })

    {:ok, other_agent} =
      Agents.create_agent(%{
        company_id: other_company.id,
        name: "Forged wake agent #{unique}",
        role: :cto
      })

    forged =
      %IssueThreadInteraction{}
      |> IssueThreadInteraction.changeset(%{
        issue_id: context.issue.id,
        kind: :request_confirmation,
        created_by_agent_id: other_agent.id,
        payload: %{"message" => "Forged creator"}
      })
      |> Repo.insert!()

    assert {:ok, resolved} =
             IssueThreadInteractions.resolve_interaction(forged, %{
               status: :rejected,
               resolved_by_user_id: context.user.id
             })

    assert resolved.status == :rejected

    assert Repo.aggregate(
             from(w in AgentWake,
               where: w.agent_id == ^other_agent.id and w.issue_id == ^context.issue.id
             ),
             :count,
             :id
           ) == 0
  end

  test "a confirmation cannot target a document from another issue", context do
    {:ok, other_issue} =
      Issues.create_issue(%{
        company_id: context.company.id,
        title: "Unrelated plan",
        status: :todo
      })

    {:ok, other_document} =
      Documents.create_document(%{
        issue_id: other_issue.id,
        key: "other-plan",
        title: "Other plan",
        body: "Not this issue's plan"
      })

    assert {:error, :invalid_target_document} =
             IssueThreadInteractions.create_interaction(%{
               issue_id: context.issue.id,
               kind: :request_confirmation,
               created_by_agent_id: context.agent.id,
               payload: %{
                 "message" => "Approve this plan?",
                 "target_document_id" => other_document.id
               }
             })

    assert Repo.aggregate(IssueThreadInteraction, :count, :id) == 0
    assert accepted_wake_count(context) == 0
  end

  defp create_confirmation(context, spoofed_revision \\ nil) do
    payload = %{
      "message" => "Approve this implementation plan?",
      "target_document_id" => context.document.id
    }

    payload =
      if spoofed_revision,
        do: Map.put(payload, "target_revision_sha256", spoofed_revision),
        else: payload

    IssueThreadInteractions.create_interaction(%{
      issue_id: context.issue.id,
      kind: :request_confirmation,
      created_by_agent_id: context.agent.id,
      payload: payload
    })
  end

  defp accepted_wake_count(context) do
    Repo.aggregate(
      from(w in AgentWake,
        where:
          w.agent_id == ^context.agent.id and w.issue_id == ^context.issue.id and
            w.reason == "interaction_request_confirmation_accepted"
      ),
      :count,
      :id
    )
  end
end
