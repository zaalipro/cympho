defmodule CymphoWeb.AttachmentControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Issues
  alias Cympho.Attachments

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

  describe "index/2" do
    test "lists attachments for an issue", %{conn: conn, issue: issue} do
      conn = get(conn, ~p"/api/issues/#{issue.id}/attachments")
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "create/2" do
    test "uploads a file and creates attachment", %{conn: conn, issue: issue} do
      tmp_path = System.tmp_dir!() |> Path.join("upload_test.txt")
      File.write!(tmp_path, "test content")

      upload = %Plug.Upload{
        path: tmp_path,
        filename: "test.txt",
        content_type: "text/plain"
      }

      conn = post(conn, ~p"/api/issues/#{issue.id}/attachments", file: upload)

      assert %{"data" => data} = json_response(conn, 201)
      assert data["filename"] == "test.txt"
      assert data["content_type"] == "text/plain"
      assert data["file_size"] > 0
      assert data["issue_id"] == issue.id

      if data["id"] do
        {:ok, att} = Attachments.get_attachment(data["id"])
        Attachments.delete_attachment(att)
      end

      File.rm(tmp_path)
    end

    test "returns 400 when no file provided", %{conn: conn, issue: issue} do
      conn = post(conn, ~p"/api/issues/#{issue.id}/attachments")
      assert json_response(conn, 400)
    end

    test "returns 413 for oversized file", %{conn: conn, issue: issue} do
      tmp_path = System.tmp_dir!() |> Path.join("oversized_test.txt")
      File.write!(tmp_path, String.duplicate("x", 10 * 1024 * 1024 + 1))

      upload = %Plug.Upload{
        path: tmp_path,
        filename: "big.txt",
        content_type: "text/plain"
      }

      conn = post(conn, ~p"/api/issues/#{issue.id}/attachments", file: upload)
      assert conn.status == 413

      File.rm(tmp_path)
    end
  end

  describe "show/2" do
    test "returns attachment metadata", %{conn: conn, issue: issue} do
      attrs = %{
        filename: "test.pdf",
        content_type: "application/pdf",
        file_size: 1024,
        path: "#{issue.id}/test.pdf",
        issue_id: issue.id
      }

      {:ok, attachment} = Attachments.create_attachment(attrs)

      conn = get(conn, ~p"/api/attachments/#{attachment.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["filename"] == "test.pdf"
      assert data["id"] == attachment.id
    end

    test "returns 404 for non-existent attachment", %{conn: conn} do
      conn = get(conn, ~p"/api/attachments/00000000-0000-0000-0000-000000000000")
      assert conn.status == 404
    end
  end

  describe "download/2" do
    test "downloads file content", %{conn: conn, issue: issue} do
      tmp_path = System.tmp_dir!() |> Path.join("download_test.txt")
      File.write!(tmp_path, "download me")

      upload = %Plug.Upload{filename: "download.txt", path: tmp_path, content_type: "text/plain"}
      {:ok, relative_path} = Attachments.store_file(upload, issue.id)

      attrs = %{
        filename: "download.txt",
        content_type: "text/plain",
        file_size: 11,
        path: relative_path,
        issue_id: issue.id
      }

      {:ok, attachment} = Attachments.create_attachment(attrs)

      conn = get(conn, ~p"/api/attachments/#{attachment.id}/download")
      assert conn.status == 200
      assert conn.resp_body == "download me"

      Attachments.delete_attachment(attachment)
      File.rm(tmp_path)
    end

    test "returns 404 when file missing from disk", %{conn: conn, issue: issue} do
      attrs = %{
        filename: "ghost.txt",
        content_type: "text/plain",
        file_size: 10,
        path: "#{issue.id}/nonexistent.txt",
        issue_id: issue.id
      }

      {:ok, attachment} = Attachments.create_attachment(attrs)

      conn = get(conn, ~p"/api/attachments/#{attachment.id}/download")
      assert conn.status == 404

      Attachments.delete_attachment(attachment)
    end
  end

  describe "delete/2" do
    test "deletes an attachment", %{conn: conn, issue: issue} do
      attrs = %{
        filename: "delete_me.pdf",
        content_type: "application/pdf",
        file_size: 100,
        path: "#{issue.id}/delete_me.pdf",
        issue_id: issue.id
      }

      {:ok, attachment} = Attachments.create_attachment(attrs)

      conn = delete(conn, ~p"/api/attachments/#{attachment.id}")
      assert conn.status == 204

      assert {:error, :not_found} = Attachments.get_attachment(attachment.id)
    end

    test "returns 404 for non-existent attachment", %{conn: conn} do
      conn = delete(conn, ~p"/api/attachments/00000000-0000-0000-0000-000000000000")
      assert conn.status == 404
    end
  end
end
