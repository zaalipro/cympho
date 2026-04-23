defmodule Cympho.AttachmentsTest do
  use Cympho.DataCase, async: true

  alias Cympho.Attachments
  alias Cympho.Attachments.Attachment
  alias Cympho.Issues

  setup do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Test Issue",
        description: "Test description",
        status: :backlog,
        priority: :medium
      })

    %{issue: issue}
  end

  describe "create_attachment/1" do
    test "creates an attachment with valid attrs", %{issue: issue} do
      attrs = %{
        filename: "test.pdf",
        content_type: "application/pdf",
        file_size: 1024,
        path: "#{issue.id}/abc.pdf",
        issue_id: issue.id
      }

      assert {:ok, %Attachment{} = attachment} = Attachments.create_attachment(attrs)
      assert attachment.filename == "test.pdf"
      assert attachment.content_type == "application/pdf"
      assert attachment.file_size == 1024
      assert attachment.issue_id == issue.id
    end

    test "returns error with missing required fields", %{issue: issue} do
      attrs = %{issue_id: issue.id}
      assert {:error, changeset} = Attachments.create_attachment(attrs)
      errors = errors_on(changeset)
      assert errors[:filename]
      assert errors[:content_type]
      assert errors[:file_size]
      assert errors[:path]
    end

    test "returns error when file_size exceeds 10MB", %{issue: issue} do
      attrs = %{
        filename: "big.zip",
        content_type: "application/zip",
        file_size: 11 * 1024 * 1024,
        path: "#{issue.id}/big.zip",
        issue_id: issue.id
      }

      assert {:error, changeset} = Attachments.create_attachment(attrs)
      assert errors_on(changeset)[:file_size]
    end

    test "returns error with non-existent issue_id" do
      attrs = %{
        filename: "test.pdf",
        content_type: "application/pdf",
        file_size: 100,
        path: "test/test.pdf",
        issue_id: "00000000-0000-0000-0000-000000000000"
      }

      assert {:error, changeset} = Attachments.create_attachment(attrs)
      assert errors_on(changeset)[:issue_id]
    end
  end

  describe "list_attachments/1" do
    test "returns attachments for an issue", %{issue: issue} do
      attrs = %{
        filename: "test.pdf",
        content_type: "application/pdf",
        file_size: 1024,
        path: "#{issue.id}/test.pdf",
        issue_id: issue.id
      }

      {:ok, _} = Attachments.create_attachment(attrs)
      attachments = Attachments.list_attachments(issue.id)
      assert length(attachments) == 1
      assert hd(attachments).filename == "test.pdf"
    end

    test "returns empty list for issue with no attachments" do
      attachments = Attachments.list_attachments("00000000-0000-0000-0000-000000000000")
      assert attachments == []
    end
  end

  describe "get_attachment!/1 and get_attachment/1" do
    test "get_attachment! returns attachment by id", %{issue: issue} do
      attrs = %{
        filename: "test.pdf",
        content_type: "application/pdf",
        file_size: 1024,
        path: "#{issue.id}/test.pdf",
        issue_id: issue.id
      }

      {:ok, attachment} = Attachments.create_attachment(attrs)
      found = Attachments.get_attachment!(attachment.id)
      assert found.id == attachment.id
    end

    test "get_attachment! raises for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Attachments.get_attachment!("00000000-0000-0000-0000-000000000000")
      end
    end

    test "get_attachment returns {:ok, attachment}", %{issue: issue} do
      attrs = %{
        filename: "test.pdf",
        content_type: "application/pdf",
        file_size: 1024,
        path: "#{issue.id}/test.pdf",
        issue_id: issue.id
      }

      {:ok, attachment} = Attachments.create_attachment(attrs)
      assert {:ok, found} = Attachments.get_attachment(attachment.id)
      assert found.id == attachment.id
    end

    test "get_attachment returns {:error, :not_found} for missing id" do
      assert {:error, :not_found} = Attachments.get_attachment("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "delete_attachment/1" do
    test "deletes an attachment", %{issue: issue} do
      attrs = %{
        filename: "test.pdf",
        content_type: "application/pdf",
        file_size: 1024,
        path: "#{issue.id}/test.pdf",
        issue_id: issue.id
      }

      {:ok, attachment} = Attachments.create_attachment(attrs)
      assert {:ok, _} = Attachments.delete_attachment(attachment)
      assert {:error, :not_found} = Attachments.get_attachment(attachment.id)
    end
  end
end
