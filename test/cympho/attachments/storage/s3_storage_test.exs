defmodule Cympho.Attachments.Storage.S3StorageTest do
  use Cympho.DataCase, async: true

  alias Cympho.Attachments.Storage.S3Storage

  @bucket "test-bucket"
  @host "s3.amazonaws.com"

  setup do
    Application.put_env(:cympho, :s3_bucket, @bucket)
    Application.put_env(:cympho, :s3_host, @host)
    Application.put_env(:cympho, :s3_scheme, :virtual_hosted)

    :ok
  end

  describe "store_file/2" do
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
               S3Storage.store_file(upload, "not-a-uuid")

      File.rm!(tmp_path)
    end
  end

  describe "public_url/1" do
    test "returns virtual-hosted-style URL for S3" do
      key = "issue-id-123/test.txt"

      assert S3Storage.public_url(key) ==
               "https://#{@bucket}.#{@host}/#{key}"
    end

    test "returns path-style URL for S3 when configured" do
      Application.put_env(:cympho, :s3_scheme, :path)

      key = "issue-id-123/test.txt"

      assert S3Storage.public_url(key) == "https://#{@host}/#{@bucket}/#{key}"

      Application.put_env(:cympho, :s3_scheme, :virtual_hosted)
    end

    test "returns correct URL for custom host" do
      custom_host = "minio.example.com"
      Application.put_env(:cympho, :s3_host, custom_host)

      key = "issue-id-123/test.txt"

      assert S3Storage.public_url(key) ==
               "https://#{@bucket}.#{custom_host}/#{key}"

      Application.put_env(:cympho, :s3_host, @host)
    end
  end
end
