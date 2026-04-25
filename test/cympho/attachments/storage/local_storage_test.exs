defmodule Cympho.Attachments.Storage.LocalStorageTest do
  use Cympho.DataCase, async: true

  alias Cympho.Attachments.Storage.LocalStorage

  @upload_dir "test_uploads"

  setup do
    Application.put_env(:cympho, :uploads_dir, @upload_dir)

    on_exit(fn ->
      File.rm_rf!(@upload_dir)
    end)

    :ok
  end

  describe "store_file/2" do
    test "stores a file and returns the relative path" do
      issue_id = Ecto.UUID.generate()

      tmp_path =
        System.tmp_dir!()
        |> Path.join("test_upload_#{:erlang.unique_integer([:positive])}.txt")

      File.write!(tmp_path, "test content")

      upload = %Plug.Upload{
        filename: "test.txt",
        path: tmp_path,
        content_type: "text/plain"
      }

      assert {:ok, relative_path} = LocalStorage.store_file(upload, issue_id)
      assert relative_path =~ issue_id
      assert relative_path =~ ".txt"

      full_path = Path.join([@upload_dir, relative_path])
      assert File.exists?(full_path)

      assert {:ok, content} = File.read(full_path)
      assert content == "test content"

      File.rm!(tmp_path)
    end

    test "creates nested directory structure" do
      issue_id = Ecto.UUID.generate()

      tmp_path =
        System.tmp_dir!()
        |> Path.join("test_upload_#{:erlang.unique_integer([:positive])}.jpg")

      File.write!(tmp_path, <<0xFF, 0xD8>>)

      upload = %Plug.Upload{
        filename: "image.jpg",
        path: tmp_path,
        content_type: "image/jpeg"
      }

      assert {:ok, relative_path} = LocalStorage.store_file(upload, issue_id)

      full_path = Path.join([@upload_dir, relative_path])
      assert File.exists?(full_path)

      File.rm!(tmp_path)
    end

    test "returns error for invalid issue_id" do
      tmp_path =
        System.tmp_dir!()
        |> Path.join("test_upload_#{:erlang.unique_integer([:positive])}.txt")

      File.write!(tmp_path, "test")

      upload = %Plug.Upload{
        filename: "test.txt",
        path: tmp_path,
        content_type: "text/plain"
      }

      assert {:error, :invalid_issue_id} =
               LocalStorage.store_file(upload, "not-a-uuid")

      File.rm!(tmp_path)
    end
  end

  describe "read_file/1" do
    test "reads a stored file" do
      issue_id = Ecto.UUID.generate()

      tmp_path =
        System.tmp_dir!()
        |> Path.join("test_upload_#{:erlang.unique_integer([:positive])}.txt")

      File.write!(tmp_path, "test content")

      upload = %Plug.Upload{
        filename: "test.txt",
        path: tmp_path,
        content_type: "text/plain"
      }

      {:ok, relative_path} = LocalStorage.store_file(upload, issue_id)

      assert {:ok, content} = LocalStorage.read_file(relative_path)
      assert content == "test content"

      File.rm!(tmp_path)
    end

    test "returns error for non-existent file" do
      assert {:error, :enoent} =
               LocalStorage.read_file("non-existent/file.txt")
    end
  end

  describe "delete_file/1" do
    test "deletes a stored file" do
      issue_id = Ecto.UUID.generate()

      tmp_path =
        System.tmp_dir!()
        |> Path.join("test_upload_#{:erlang.unique_integer([:positive])}.txt")

      File.write!(tmp_path, "test content")

      upload = %Plug.Upload{
        filename: "test.txt",
        path: tmp_path,
        content_type: "text/plain"
      }

      {:ok, relative_path} = LocalStorage.store_file(upload, issue_id)

      full_path = Path.join([@upload_dir, relative_path])
      assert File.exists?(full_path)

      assert :ok = LocalStorage.delete_file(relative_path)
      refute File.exists?(full_path)

      File.rm!(tmp_path)
    end

    test "returns :ok for non-existent file" do
      assert :ok = LocalStorage.delete_file("non-existent/file.txt")
    end
  end

  describe "public_url/1" do
    test "returns the public URL for a file" do
      relative_path = "issue-id-123/file.txt"

      assert LocalStorage.public_url(relative_path) ==
               "/uploads/#{relative_path}"
    end
  end
end
