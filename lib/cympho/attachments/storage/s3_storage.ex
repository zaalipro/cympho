defmodule Cympho.Attachments.Storage.S3Storage do
  @moduledoc """
  S3-compatible object storage backend for attachments.

  Supports AWS S3, MinIO, DigitalOcean Spaces, and other S3-compatible services.
  """

  @behaviour Cympho.Attachments.Storage

  require Logger

  @impl true
  def store_file(%Plug.Upload{filename: filename, path: tmp_path}, issue_id) do
    with {:ok, safe_id} <- validate_uuid(issue_id) do
      ext = Path.extname(filename)
      unique_name = "#{Ecto.UUID.generate()}#{ext}"
      key = Path.join(safe_id, unique_name)

      with {:ok, file_binary} <- File.read(tmp_path),
           {:ok, _} <- upload_to_s3(key, file_binary, filename) do
        {:ok, key}
      end
    end
  end

  @impl true
  def read_file(key) do
    case ExAws.S3.get_object(bucket(), key) |> ExAws.request() do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete_file(key) do
    case ExAws.S3.delete_object(bucket(), key) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def public_url(key) do
    bucket = bucket()
    host = s3_host()

    case s3_scheme() do
      :virtual_hosted ->
        "https://#{bucket}.#{host}/#{key}"

      :path ->
        "https://#{host}/#{bucket}/#{key}"
    end
  end

  defp upload_to_s3(key, file_binary, filename) do
    content_type = MIME.from_filename(filename) || "application/octet-stream"

    ExAws.S3.put_object(
      bucket(),
      key,
      file_binary,
      content_type: content_type
    )
    |> ExAws.request()
  end

  defp bucket do
    Application.get_env(:cympho, :s3_bucket) ||
      raise """
      S3 bucket not configured. Please set :s3_bucket in :cympho application config.

      Example:
        config :cympho, :s3_bucket, "my-attachments-bucket"
      """
  end

  defp s3_host do
    Application.get_env(:cympho, :s3_host, "s3.amazonaws.com")
  end

  defp s3_scheme do
    Application.get_env(:cympho, :s3_scheme, :virtual_hosted)
  end

  defp validate_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_issue_id}
    end
  end

  defp validate_uuid(_), do: {:error, :invalid_issue_id}
end
