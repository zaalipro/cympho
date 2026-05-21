defmodule Cympho.ScopedGettersTenancyTest do
  @moduledoc """
  Verifies that the new get_company_X/2 functions for Decisions, Documents,
  and Attachments treat cross-tenant ID guesses as a clean miss instead of
  surfacing the row.
  """
  use Cympho.DataCase, async: true

  alias Cympho.{Agents, Attachments, Companies, Decisions, Documents, Issues, Projects}

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company_a} =
      Companies.create_company(%{name: "ScopeA #{unique}", slug: "scope-a-#{unique}"})

    {:ok, company_b} =
      Companies.create_company(%{name: "ScopeB #{unique}", slug: "scope-b-#{unique}"})

    prefix = for _ <- 1..6, into: "", do: <<Enum.random(?A..?Z)>>

    {:ok, project_a} =
      Projects.create_project(%{
        name: "Project A #{unique}",
        prefix: prefix,
        company_id: company_a.id
      })

    {:ok, issue_a} =
      Issues.create_issue(%{
        title: "Issue A #{unique}",
        description: "A's work",
        company_id: company_a.id,
        project_id: project_a.id,
        status: :todo
      })

    {:ok, actor_a} =
      Agents.create_agent(%{
        name: "Actor #{unique}",
        role: :engineer,
        company_id: company_a.id
      })

    %{
      company_a: company_a,
      company_b: company_b,
      project_a: project_a,
      issue_a: issue_a,
      actor_a: actor_a,
      unique: unique
    }
  end

  describe "Decisions.get_company_decision/2" do
    test "returns the decision under its company; not-found from another", %{
      company_a: company_a,
      company_b: company_b,
      actor_a: actor_a
    } do
      {:ok, decision} =
        Decisions.create_decision(%{
          decision_type: "test",
          decision_key: "dec-scope-#{System.unique_integer([:positive])}",
          outcome: "approved",
          actor_type: "agent",
          actor_id: actor_a.id,
          effective_at: DateTime.utc_now() |> DateTime.truncate(:second),
          company_id: company_a.id
        })

      assert {:ok, %{id: id}} = Decisions.get_company_decision(company_a.id, decision.id)
      assert id == decision.id

      assert {:error, :not_found} =
               Decisions.get_company_decision(company_b.id, decision.id)
    end
  end

  describe "Documents.get_company_document/2" do
    test "joins through parent issue; returns not-found for foreign company", %{
      company_a: company_a,
      company_b: company_b,
      issue_a: issue_a
    } do
      {:ok, document} =
        Documents.create_document(%{
          issue_id: issue_a.id,
          key: "spec-#{System.unique_integer([:positive])}",
          title: "Spec",
          body: "..."
        })

      assert {:ok, %{id: id}} = Documents.get_company_document(company_a.id, document.id)
      assert id == document.id

      assert {:error, :not_found} =
               Documents.get_company_document(company_b.id, document.id)
    end
  end

  describe "Attachments.get_company_attachment/2" do
    test "joins through parent issue; returns not-found for foreign company", %{
      company_a: company_a,
      company_b: company_b,
      issue_a: issue_a
    } do
      {:ok, attachment} =
        Attachments.create_attachment(%{
          filename: "evidence.txt",
          content_type: "text/plain",
          file_size: 42,
          path: "fake/path-#{System.unique_integer([:positive])}.txt",
          issue_id: issue_a.id
        })

      assert {:ok, %{id: id}} = Attachments.get_company_attachment(company_a.id, attachment.id)
      assert id == attachment.id

      assert {:error, :not_found} =
               Attachments.get_company_attachment(company_b.id, attachment.id)
    end
  end
end
