defmodule Cympho.DocumentsTest do
  use Cympho.DataCase, async: true

  alias Cympho.Documents
  alias Cympho.Documents.IssueDocument
  alias Cympho.Documents.IssueDocumentRevision
  alias Cympho.Issues

  setup do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Test Issue",
        description: "Test description",
        status: :backlog,
        priority: :high
      })

    %{issue: issue}
  end

  describe "list_documents/1" do
    test "returns empty list when no documents", %{issue: issue} do
      assert Documents.list_documents(issue.id) == []
    end

    test "returns documents for issue ordered by key", %{issue: issue} do
      {:ok, _doc1} =
        Documents.create_document(%{key: "plan", title: "Plan", body: "# Plan", issue_id: issue.id})

      {:ok, _doc2} =
        Documents.create_document(%{key: "spec", title: "Spec", body: "# Spec", issue_id: issue.id})

      docs = Documents.list_documents(issue.id)
      assert length(docs) == 2
      assert Enum.at(docs, 0).key == "plan"
      assert Enum.at(docs, 1).key == "spec"
    end
  end

  describe "create_document/1" do
    test "creates document with valid data", %{issue: issue} do
      attrs = %{key: "plan", title: "Plan", body: "# My Plan", format: "markdown", issue_id: issue.id}

      assert {:ok, %IssueDocument{} = doc} = Documents.create_document(attrs)
      assert doc.key == "plan"
      assert doc.title == "Plan"
      assert doc.body == "# My Plan"
      assert doc.format == "markdown"
      assert doc.issue_id == issue.id
    end

    test "returns error for missing key", %{issue: issue} do
      attrs = %{title: "No Key", body: "content", issue_id: issue.id}
      assert {:error, %Ecto.Changeset{}} = Documents.create_document(attrs)
    end

    test "returns error for missing title", %{issue: issue} do
      attrs = %{key: "plan", body: "content", issue_id: issue.id}
      assert {:error, %Ecto.Changeset{}} = Documents.create_document(attrs)
    end

    test "returns error for duplicate key on same issue", %{issue: issue} do
      attrs = %{key: "plan", title: "Plan", body: "content", issue_id: issue.id}
      {:ok, _} = Documents.create_document(attrs)
      assert {:error, %Ecto.Changeset{}} = Documents.create_document(attrs)
    end

    test "allows same key on different issues" do
      {:ok, issue1} = Issues.create_issue(%{title: "Issue 1", description: "desc1"})
      {:ok, issue2} = Issues.create_issue(%{title: "Issue 2", description: "desc2"})

      assert {:ok, _} = Documents.create_document(%{key: "plan", title: "Plan 1", body: "c1", issue_id: issue1.id})
      assert {:ok, _} = Documents.create_document(%{key: "plan", title: "Plan 2", body: "c2", issue_id: issue2.id})
    end

    test "defaults format to markdown", %{issue: issue} do
      {:ok, doc} = Documents.create_document(%{key: "plan", title: "Plan", body: "c", issue_id: issue.id})
      assert doc.format == "markdown"
    end

    test "validates format inclusion", %{issue: issue} do
      attrs = %{key: "plan", title: "Plan", body: "c", format: "html", issue_id: issue.id}
      assert {:error, %Ecto.Changeset{}} = Documents.create_document(attrs)
    end
  end

  describe "upsert_document/3" do
    test "creates document when key does not exist", %{issue: issue} do
      assert {:ok, %IssueDocument{}} =
               Documents.upsert_document(issue.id, "plan", %{"title" => "Plan", "body" => "# Plan"})
    end

    test "updates existing document when key exists", %{issue: issue} do
      {:ok, original} =
        Documents.create_document(%{key: "plan", title: "Original Plan", body: "v1", issue_id: issue.id})

      {:ok, updated} =
        Documents.upsert_document(issue.id, "plan", %{"title" => "Updated Plan", "body" => "v2"})

      assert updated.id == original.id
      assert updated.title == "Updated Plan"
      assert updated.body == "v2"
    end
  end

  describe "update_document/2" do
    setup %{issue: issue} do
      {:ok, document} =
        Documents.create_document(%{key: "plan", title: "Original", body: "original body", issue_id: issue.id})

      %{document: document}
    end

    test "updates document and creates revision", %{document: document} do
      {:ok, updated} = Documents.update_document(document, %{title: "Updated", body: "new body"})
      assert updated.title == "Updated"
      assert updated.body == "new body"

      revisions = Documents.list_revisions(document.id)
      assert length(revisions) == 1
      assert hd(revisions).title == "Original"
      assert hd(revisions).body == "original body"
    end

    test "creates multiple revisions on successive updates", %{document: document} do
      {:ok, d1} = Documents.update_document(document, %{title: "v1", body: "body1"})
      {:ok, _d2} = Documents.update_document(d1, %{title: "v2", body: "body2"})
      assert length(Documents.list_revisions(document.id)) == 2
    end
  end

  describe "delete_document/1" do
    setup %{issue: issue} do
      {:ok, document} =
        Documents.create_document(%{key: "plan", title: "To Delete", body: "content", issue_id: issue.id})

      %{document: document}
    end

    test "deletes the document", %{document: document} do
      assert {:ok, _} = Documents.delete_document(document)
      assert_raise Ecto.NoResultsError, fn -> Documents.get_document!(document.id) end
    end
  end

  describe "get_document_by_key/2" do
    test "returns document when found", %{issue: issue} do
      {:ok, _} = Documents.create_document(%{key: "spec", title: "Spec", body: "content", issue_id: issue.id})
      assert {:ok, doc} = Documents.get_document_by_key(issue.id, "spec")
      assert doc.key == "spec"
    end

    test "returns error when not found", %{issue: issue} do
      assert {:error, :not_found} = Documents.get_document_by_key(issue.id, "missing")
    end
  end

  describe "get_document!/1" do
    test "returns document with revisions preloaded", %{issue: issue} do
      {:ok, doc} = Documents.create_document(%{key: "plan", title: "Plan", body: "v0", issue_id: issue.id})
      {:ok, _} = Documents.update_document(doc, %{title: "Plan v1", body: "v1"})

      found = Documents.get_document!(doc.id)
      assert found.key == "plan"
      assert length(found.revisions) == 1
    end

    test "raises for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Documents.get_document!("00000000-0000-0000-0000-000000000000")
      end
    end
  end

  describe "list_revisions/1" do
    test "returns revisions ordered newest first", %{issue: issue} do
      {:ok, doc} = Documents.create_document(%{key: "plan", title: "v0", body: "body0", issue_id: issue.id})
      {:ok, d1} = Documents.update_document(doc, %{title: "v1", body: "body1"})
      {:ok, _d2} = Documents.update_document(d1, %{title: "v2", body: "body2"})

      revisions = Documents.list_revisions(doc.id)
      assert length(revisions) == 2
      assert hd(revisions).title == "v1"
      assert Enum.at(revisions, 1).title == "v0"
    end
  end

  describe "get_revision!/1" do
    test "returns revision by id", %{issue: issue} do
      {:ok, doc} = Documents.create_document(%{key: "plan", title: "v0", body: "body0", issue_id: issue.id})
      {:ok, _} = Documents.update_document(doc, %{title: "v1", body: "body1"})

      [revision | _] = Documents.list_revisions(doc.id)
      found = Documents.get_revision!(revision.id)
      assert found.id == revision.id
      assert found.title == "v0"
    end
  end
end
